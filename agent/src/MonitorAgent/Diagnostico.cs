using System.Security.Principal;
using System.Text.Json;
using Microsoft.Extensions.DependencyInjection;
using MonitorAgent.Collectors;
using MonitorAgent.Config;
using MonitorAgent.Logging;
using MonitorAgent.Spool;
using MonitorAgent.Transport;

namespace MonitorAgent;

/// <summary>
/// Modos de diagnóstico. Existem porque "o agente está mudo" é o chamado mais
/// comum deste sistema, e sem ferramenta o técnico fica lendo log no escuro.
/// </summary>
public static class Diagnostico
{
    public static async Task<int> CheckAsync(
        IServiceProvider sp,
        AgentConfig cfg,
        string versao,
        RollingFileLoggerProvider logProvider)
    {
        Console.WriteLine();
        Console.WriteLine($"MonitorAgent {versao} — verificação");
        Console.WriteLine(new string('=', 64));

        var problemas = 0;

        Console.WriteLine();
        Console.WriteLine("CONFIGURAÇÃO");
        Console.WriteLine($"  arquivo   : {ConfigLoader.CaminhoConfig}");
        Console.WriteLine($"  logs      : {logProvider.CaminhoAtual}");
        Console.WriteLine($"  loja      : {cfg.SiteCode}");
        Console.WriteLine($"  máquina   : {cfg.MachineLabel} ({cfg.Role})");
        Console.WriteLine($"  GUID      : {cfg.MachineId}");
        Console.WriteLine($"  URL       : {cfg.IngestUrl}");
        Console.WriteLine($"  token     : {cfg.TokenPrefix}... ({cfg.Token.Length} caracteres)");
        Console.WriteLine($"  segredo   : {(string.IsNullOrEmpty(cfg.SharedSecret) ? "AUSENTE" : "definido")}");
        Console.WriteLine($"  intervalo : {cfg.IntervalSeconds}s, lotes de {cfg.BatchSize}");
        Console.WriteLine($"  serviços  : {(cfg.CriticalServices.Count == 0 ? "(nenhum)" : string.Join(", ", cfg.CriticalServices))}");

        // Elevação decide se temperatura e SMART vão funcionar. Dizer isso aqui
        // evita o diagnóstico errado "essa máquina não tem sensor".
        var elevado = EstaElevado();
        Console.WriteLine();
        Console.WriteLine("PRIVILÉGIO");
        Console.WriteLine($"  elevado   : {(elevado ? "sim" : "NÃO")}");
        if (!elevado)
        {
            Console.WriteLine("  AVISO: sem elevação, temperatura e SMART retornam 'acesso negado'.");
            Console.WriteLine("         Como serviço (LocalSystem) funcionam. Não é ausência de sensor.");
        }

        Console.WriteLine();
        Console.WriteLine("COLETA");
        var runner = sp.GetRequiredService<CollectorRunner>();
        var amostra = await runner.CollectAsync(CancellationToken.None);

        Console.WriteLine($"  CPU       : {Fmt(amostra.CpuPercent)}%");
        Console.WriteLine($"  memória   : {Fmt(amostra.MemUsedMb)} / {Fmt(amostra.MemTotalMb)} MB");
        Console.WriteLine($"  uptime    : {FormatarUptime(amostra.UptimeSeconds)}");
        Console.WriteLine($"  processos : {Fmt(amostra.ProcessCount)}");
        Console.WriteLine($"  temp      : {Fmt(amostra.CpuTempC)} °C");
        Console.WriteLine($"  latência  : gateway {Fmt(amostra.GatewayLatencyMs)}ms, central {Fmt(amostra.CentralLatencyMs)}ms");

        foreach (var d in amostra.Disks)
        {
            Console.WriteLine($"  disco {d.Drive,-4}: {Fmt(d.FreeGb)} / {Fmt(d.TotalGb)} GB livres" +
                              $"  smart={Fmt(d.SmartOk)} ({d.SmartSource}) tipo={d.MediaType ?? "-"}");
        }

        foreach (var s in amostra.Services)
        {
            Console.WriteLine($"  serviço   : {s.Name,-24} rodando={s.IsRunning,-5} state_raw={s.StateRaw ?? "-"}");
            if (s.StateRaw == "NotInstalled")
            {
                Console.WriteLine($"              AVISO: '{s.Name}' não existe nesta máquina e conta como PARADO.");
                problemas++;
            }
        }

        if (amostra.Flags.Count > 0)
        {
            Console.WriteLine($"  flags     : {string.Join(", ", amostra.Flags)}");
        }

        if (amostra.CpuPercent is null)
        {
            Console.WriteLine("  ERRO: CPU não pôde ser coletada.");
            problemas++;
        }

        Console.WriteLine();
        Console.WriteLine("SPOOL");
        var spool = sp.GetRequiredService<SpoolStore>();
        try
        {
            await spool.InitializeAsync(CancellationToken.None);
            var st = await spool.GetStatsAsync(CancellationToken.None);
            Console.WriteLine($"  arquivo   : {spool.DatabasePath}");
            Console.WriteLine($"  pendentes : {st.Count} amostra(s), {st.SizeBytes / 1024} KB");
            if (st.Count > 0)
            {
                Console.WriteLine($"  período   : {st.Oldest} .. {st.Newest}");
                Console.WriteLine($"  tentativas: máximo {st.MaxAttempts} numa mesma amostra");
                if (st.MaxAttempts > 10)
                {
                    Console.WriteLine("  AVISO: muitas tentativas na mesma amostra indica credencial ou URL errada.");
                    problemas++;
                }
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"  ERRO: {ex.Message}");
            problemas++;
        }

        Console.WriteLine();
        Console.WriteLine("CONECTIVIDADE");
        var cliente = sp.GetRequiredService<IngestClient>();
        var (ok, detalhe) = await cliente.CheckHealthAsync(CancellationToken.None);
        Console.WriteLine($"  healthz   : {(ok ? "OK" : "FALHOU")}");
        Console.WriteLine($"  resposta  : {Truncar(detalhe, 400)}");

        if (!ok)
        {
            problemas++;
            Console.WriteLine();
            Console.WriteLine("  Causas comuns:");
            Console.WriteLine("   - função não publicada, ou publicada sem --no-verify-jwt");
            Console.WriteLine("   - ingestUrl errada (falta /functions/v1/ingest)");
            Console.WriteLine("   - link da loja fora do ar");
            Console.WriteLine("   - proxy/firewall bloqueando saída HTTPS");
        }

        Console.WriteLine();
        Console.WriteLine(new string('=', 64));
        if (problemas == 0)
        {
            Console.WriteLine("VERIFICAÇÃO OK — o agente está apto a rodar.");
            return 0;
        }

        Console.WriteLine($"{problemas} PROBLEMA(S) ENCONTRADO(S) — veja os avisos acima.");
        return 1;
    }

    /// <summary>
    /// Imprime exatamente o JSON que iria para o servidor. É o que permite
    /// reproduzir um problema de ingestão com curl, sem envolver o agente.
    /// </summary>
    public static async Task<int> CollectOnceAsync(IServiceProvider sp, string versao)
    {
        var runner = sp.GetRequiredService<CollectorRunner>();

        var envelope = new IngestEnvelope
        {
            AgentVersion = versao,
            SentAt = DateTime.UtcNow.ToString("O"),
            Machine = runner.CollectMachineInfo(),
            Samples = { await runner.CollectAsync(CancellationToken.None) },
        };

        Console.WriteLine(JsonSerializer.Serialize(envelope, new JsonSerializerOptions
        {
            WriteIndented = true,
            DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
        }));

        return 0;
    }

    public static async Task<int> SpoolStatusAsync(IServiceProvider sp)
    {
        var spool = sp.GetRequiredService<SpoolStore>();
        await spool.InitializeAsync(CancellationToken.None);
        var st = await spool.GetStatsAsync(CancellationToken.None);

        Console.WriteLine();
        Console.WriteLine($"arquivo    : {spool.DatabasePath}");
        Console.WriteLine($"pendentes  : {st.Count}");
        Console.WriteLine($"tamanho    : {st.SizeBytes / 1024} KB");
        Console.WriteLine($"mais antiga: {st.Oldest ?? "-"}");
        Console.WriteLine($"mais nova  : {st.Newest ?? "-"}");
        Console.WriteLine($"tentativas : {st.MaxAttempts}");
        Console.WriteLine();

        return 0;
    }

    private static bool EstaElevado()
    {
        try
        {
            using var identidade = WindowsIdentity.GetCurrent();
            return new WindowsPrincipal(identidade).IsInRole(WindowsBuiltInRole.Administrator);
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static string Fmt(object? v) => v?.ToString() ?? "-";

    private static string FormatarUptime(long? segundos)
    {
        if (segundos is null or <= 0) return "-";
        var t = TimeSpan.FromSeconds(segundos.Value);
        return $"{(int)t.TotalDays}d {t.Hours}h {t.Minutes}m";
    }

    private static string Truncar(string s, int max) =>
        s.Length <= max ? s : s[..max] + "...";
}
