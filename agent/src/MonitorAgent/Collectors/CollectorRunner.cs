using System.Diagnostics;
using Microsoft.Extensions.Logging;
using MonitorAgent.Config;

namespace MonitorAgent.Collectors;

/// <summary>
/// Orquestra os coletores com isolamento de falha.
///
/// REGRA 19, e é a razão de esta classe existir separada do Worker: falha de UM
/// sensor não pode derrubar o ciclo. Um PDV com controlador de disco travado
/// fazia o `Win32_LogicalDisk` pendurar; sem isolamento, a amostra inteira
/// (CPU, memória, serviços) seria perdida junto — e a máquina apareceria offline
/// por causa de um disco.
///
/// Cada coletor roda dentro de try/catch E com timeout próprio. O timeout é tão
/// importante quanto o catch: WMI travado não lança exceção, ele simplesmente
/// não volta.
/// </summary>
public sealed class CollectorRunner
{
    private readonly AgentConfig _cfg;
    private readonly CimQuery _cim;
    private readonly SystemCollector _sistema;
    private readonly DiskCollector _disco;
    private readonly ServiceCollector _servicos;
    private readonly TemperatureCollector _temperatura;
    private readonly NetworkCollector _rede;
    private readonly ILogger<CollectorRunner> _log;

    private readonly HashSet<string> _desligados;
    private readonly Dictionary<string, int> _falhasPorColetor = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Teto por coletor. WMI pendurado é comum o suficiente para merecer um
    /// timeout agressivo: o ciclo é de 60s e cinco coletores travados a 30s cada
    /// atrasariam a amostra em minutos.
    /// </summary>
    private static readonly TimeSpan TimeoutPorColetor = TimeSpan.FromSeconds(15);

    /// <summary>
    /// Depois disto, o coletor é reiniciado junto com a sessão CIM. Sessão MI
    /// morta devolve erro para sempre e só recriar resolve.
    /// </summary>
    private const int FalhasAntesDeResetarSessao = 5;

    public CollectorRunner(
        AgentConfig cfg,
        CimQuery cim,
        SystemCollector sistema,
        DiskCollector disco,
        ServiceCollector servicos,
        TemperatureCollector temperatura,
        NetworkCollector rede,
        ILogger<CollectorRunner> log)
    {
        _cfg = cfg;
        _cim = cim;
        _sistema = sistema;
        _disco = disco;
        _servicos = servicos;
        _temperatura = temperatura;
        _rede = rede;
        _log = log;
        _desligados = new HashSet<string>(cfg.DisabledCollectors, StringComparer.OrdinalIgnoreCase);

        if (_desligados.Count > 0)
        {
            _log.LogWarning("coletores desligados por configuração: {Lista}", string.Join(", ", _desligados));
        }
    }

    public async Task<MetricSample> CollectAsync(CancellationToken ct)
    {
        // O timestamp é capturado ANTES de qualquer coleta e é o do AGENTE, em
        // UTC (regra 12). Capturar depois faria a amostra carregar o horário do
        // fim da coleta, e um coletor lento deslocaria a série.
        var amostra = new MetricSample
        {
            Timestamp = DateTime.UtcNow.ToString("O"),
        };

        var cronometro = Stopwatch.StartNew();

        Executar("system", () => _sistema.Collect(amostra), amostra, ct);
        Executar("disk", () => _disco.Collect(amostra), amostra, ct);
        Executar("services", () => _servicos.Collect(amostra, _cfg.CriticalServices), amostra, ct);
        Executar("temperature", () => _temperatura.Collect(amostra), amostra, ct);

        await ExecutarAsync("network",
            c => _rede.CollectAsync(amostra, _cfg.GatewayIp, ExtrairHostCentral(), c),
            amostra, ct).ConfigureAwait(false);

        cronometro.Stop();

        if (cronometro.Elapsed > TimeSpan.FromSeconds(20))
        {
            _log.LogWarning("coleta levou {Ms}ms — acima do esperado", cronometro.ElapsedMilliseconds);
        }

        _log.LogDebug(
            "amostra {T}: cpu={Cpu}% mem={Mem}MB/{Total}MB discos={Discos} serviços={Servicos} temp={Temp} flags=[{Flags}] em {Ms}ms",
            amostra.Timestamp, amostra.CpuPercent, amostra.MemUsedMb, amostra.MemTotalMb,
            amostra.Disks.Count, amostra.Services.Count, amostra.CpuTempC,
            string.Join(",", amostra.Flags), cronometro.ElapsedMilliseconds);

        return amostra;
    }

    public MachineInfo CollectMachineInfo()
    {
        try
        {
            return _sistema.CollectMachineInfo();
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "coleta de metadados da máquina falhou; será tentada de novo depois");
            return new MachineInfo { Hostname = Environment.MachineName };
        }
    }

    /// <summary>
    /// Coletor síncrono, com timeout e captura total.
    ///
    /// O trabalho vai para um Task.Run porque a API CIM é síncrona e bloqueante:
    /// sem isso o `WaitAsync` não teria efeito nenhum — ele só desiste de ESPERAR,
    /// e a thread bloqueada continuaria presa. A thread do pool fica ocupada até
    /// o WMI voltar, mas o ciclo segue e a amostra sai no horário.
    /// </summary>
    private void Executar(string nome, Action trabalho, MetricSample amostra, CancellationToken ct)
    {
        if (_desligados.Contains(nome)) return;

        try
        {
            var tarefa = Task.Run(trabalho, ct);

            if (!tarefa.Wait(TimeoutPorColetor, ct))
            {
                RegistrarFalha(nome, $"timeout de {TimeoutPorColetor.TotalSeconds}s");
                _log.LogWarning(
                    "coletor '{Coletor}' não respondeu em {Segundos}s — amostra segue sem ele. " +
                    "WMI travado nesta máquina é a causa provável.",
                    nome, TimeoutPorColetor.TotalSeconds);
                return;
            }

            _falhasPorColetor.Remove(nome);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            var real = ex is AggregateException ag ? ag.InnerException ?? ag : ex;
            RegistrarFalha(nome, real.Message);
            _log.LogWarning(real, "coletor '{Coletor}' falhou; amostra segue sem ele", nome);
        }
    }

    private async Task ExecutarAsync(
        string nome,
        Func<CancellationToken, Task> trabalho,
        MetricSample amostra,
        CancellationToken ct)
    {
        if (_desligados.Contains(nome)) return;

        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(TimeoutPorColetor);

            await trabalho(cts.Token).ConfigureAwait(false);
            _falhasPorColetor.Remove(nome);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            RegistrarFalha(nome, ex.Message);
            _log.LogWarning(ex, "coletor '{Coletor}' falhou; amostra segue sem ele", nome);
        }
    }

    private void RegistrarFalha(string nome, string motivo)
    {
        _falhasPorColetor.TryGetValue(nome, out var n);
        n++;
        _falhasPorColetor[nome] = n;

        if (n == FalhasAntesDeResetarSessao)
        {
            _log.LogWarning(
                "coletor '{Coletor}' falhou {N} vezes seguidas ({Motivo}); recriando a sessão CIM",
                nome, n, motivo);
            _cim.ResetSession();
        }
    }

    /// <summary>Host da URL de ingestão, para o ping da central.</summary>
    private string? ExtrairHostCentral()
    {
        if (!Uri.TryCreate(_cfg.IngestUrl, UriKind.Absolute, out var uri)) return null;
        return uri.Host;
    }
}
