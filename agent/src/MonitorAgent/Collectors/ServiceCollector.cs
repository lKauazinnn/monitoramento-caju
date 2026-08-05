using Microsoft.Extensions.Logging;

namespace MonitorAgent.Collectors;

/// <summary>
/// Estado dos serviços críticos.
///
/// MEDIDO em Windows 11 pt-BR (Spooler):
///   Name        = "Spooler"                 <- invariante, é o que usamos
///   DisplayName = "Spooler de Impressão"    <- TRADUZIDO, nunca usar
///   State       = "Running"                 <- invariante (vem do MOF)
///   Started     = True                      <- booleano, é o que decide alerta
///   StartMode   = "Auto"                    <- invariante
///
/// A decisão de alerta usa <c>Started</c>. Não por causa de tradução (State é
/// invariante), mas porque um booleano não depende de a Microsoft manter a
/// tabela de enum estável nem de o agente acertar a string.
/// </summary>
public sealed class ServiceCollector
{
    private readonly CimQuery _cim;
    private readonly ILogger<ServiceCollector> _log;
    private readonly HashSet<string> _jaAvisadoAusente = new(StringComparer.OrdinalIgnoreCase);

    public ServiceCollector(CimQuery cim, ILogger<ServiceCollector> log)
    {
        _cim = cim;
        _log = log;
    }

    public void Collect(MetricSample amostra, IReadOnlyList<string> nomesCriticos)
    {
        if (nomesCriticos.Count == 0) return;

        // Uma consulta só, com WHERE por nome. Consultar Win32_Service inteiro
        // e filtrar em memória custa centenas de instâncias COM por ciclo.
        var filtro = string.Join(" OR ", nomesCriticos.Select(n => $"Name = '{EscaparWql(n)}'"));

        var (linhas, falha) = _cim.TryQuery(
            CimQuery.NamespaceCimV2,
            $"SELECT Name, State, Started, StartMode, ProcessId FROM Win32_Service WHERE {filtro}");

        if (linhas.Count == 0 && falha is not null)
        {
            amostra.Flags.Add(CollectFlags.ServicesUnavailable);
            _log.LogDebug("consulta de serviços falhou: {Motivo}", falha.Message);
            return;
        }

        var encontrados = new Dictionary<string, CimRow>(StringComparer.OrdinalIgnoreCase);
        foreach (var linha in linhas)
        {
            var nome = linha.GetString("Name");
            if (!string.IsNullOrWhiteSpace(nome)) encontrados[nome] = linha;
        }

        foreach (var nome in nomesCriticos)
        {
            if (encontrados.TryGetValue(nome, out var linha))
            {
                var pid = linha.GetInt32("ProcessId");

                amostra.Services.Add(new ServiceSample
                {
                    Name = nome,
                    IsRunning = linha.GetBool("Started") ?? false,
                    StartMode = NormalizarStartMode(linha.GetString("StartMode")),
                    StateRaw = linha.GetString("State"),
                    // PID 0 significa "não está rodando", não processo 0.
                    Pid = pid is > 0 ? pid : null,
                });

                _jaAvisadoAusente.Remove(nome);
            }
            else
            {
                // Serviço configurado como crítico que não existe na máquina é
                // reportado como PARADO, não omitido. Omitir faria o alerta de
                // serviço parado nunca disparar num PDV onde alguém desinstalou
                // o software — que é exatamente o caso que interessa.
                amostra.Services.Add(new ServiceSample
                {
                    Name = nome,
                    IsRunning = false,
                    StateRaw = "NotInstalled",
                });

                // Avisa uma vez por execução: um serviço mal configurado no
                // config.json não pode encher o log a cada minuto (regra 24).
                if (_jaAvisadoAusente.Add(nome))
                {
                    _log.LogWarning(
                        "serviço crítico '{Servico}' não existe nesta máquina — será reportado como PARADO. " +
                        "Confira se o nome está correto (nome CURTO, não o exibido) em criticalServices.",
                        nome);
                }
            }
        }
    }

    /// <summary>
    /// O servidor só aceita a lista fechada do CHECK; qualquer outra coisa vira
    /// null lá. Normalizar aqui evita descartar dado bom por diferença de caixa.
    /// </summary>
    private static string? NormalizarStartMode(string? valor) => valor?.Trim().ToLowerInvariant() switch
    {
        "boot" => "Boot",
        "system" => "System",
        "auto" => "Auto",
        "manual" => "Manual",
        "disabled" => "Disabled",
        null or "" => null,
        _ => "Unknown",
    };

    /// <summary>
    /// Escapa para WQL. Nome de serviço vem do config.json, que é arquivo local
    /// controlado pela TI — mas montar consulta com concatenação sem escapar é
    /// como injeção nasce, e um nome com apóstrofo quebraria a consulta inteira
    /// (e com ela a coleta de TODOS os serviços da máquina).
    /// </summary>
    private static string EscaparWql(string valor) =>
        valor.Replace("\\", "\\\\", StringComparison.Ordinal)
             .Replace("'", "\\'", StringComparison.Ordinal);
}
