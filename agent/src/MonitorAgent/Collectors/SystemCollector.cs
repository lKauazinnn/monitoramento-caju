using System.Globalization;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using Microsoft.Extensions.Logging;

namespace MonitorAgent.Collectors;

/// <summary>
/// CPU, memória, uptime e contagem de processos/threads.
///
/// Onde cada métrica REALMENTE vive (medido em Windows 11 pt-BR):
///   CPU %              Win32_PerfFormattedData_PerfOS_Processor, Name='_Total'
///   Fila de processador Win32_PerfFormattedData_PerfOS_System   <- NÃO está na _Processor
///   Processos/threads  Win32_PerfFormattedData_PerfOS_System
///   Uptime             Win32_PerfFormattedData_PerfOS_System.SystemUpTime (segundos)
///   Memória            Win32_OperatingSystem (em KB)
///   Page file          Win32_PageFileUsage.CurrentUsage (em MB)
/// </summary>
public sealed class SystemCollector
{
    private readonly CimQuery _cim;
    private readonly ILogger<SystemCollector> _log;

    // Estado para o fallback de CPU por delta de contador bruto.
    private long? _rawAnterior;
    private long? _rawTimestampAnterior;

    public SystemCollector(CimQuery cim, ILogger<SystemCollector> log)
    {
        _cim = cim;
        _log = log;
    }

    public void Collect(MetricSample amostra)
    {
        CollectCpu(amostra);
        CollectSystemCounters(amostra);
        CollectMemory(amostra);
    }

    // -------------------------------------------------------------------------
    private void CollectCpu(MetricSample amostra)
    {
        var (linhas, falha) = _cim.TryQuery(
            CimQuery.NamespaceCimV2,
            "SELECT Name, PercentProcessorTime FROM Win32_PerfFormattedData_PerfOS_Processor WHERE Name = '_Total'");

        double? formatado = linhas.Count > 0 ? linhas[0].GetDouble("PercentProcessorTime") : null;

        // O bruto é lido SEMPRE, não só no fallback: é o delta entre ciclos que
        // o alimenta, e ele precisa da amostra anterior para existir.
        var bruto = LerCpuBruto();

        if (formatado is null)
        {
            if (bruto is not null)
            {
                amostra.CpuPercent = Clamp(bruto.Value);
                amostra.Flags.Add(CollectFlags.CpuRawFallback);
                _log.LogDebug("CPU formatada indisponível ({Motivo}), usando delta bruto: {Valor:F1}%",
                    falha?.Message ?? "sem linha _Total", bruto.Value);
            }
            else
            {
                amostra.Flags.Add(CollectFlags.CpuUnavailable);
            }
            return;
        }

        // Cache de contadores de desempenho corrompido (comum após upgrade
        // in-place do Windows) devolve 0 de forma persistente. Se o bruto
        // discorda de forma significativa, o formatado é que está mentindo.
        if (formatado.Value <= 0.0001 && bruto is > 2.0)
        {
            amostra.CpuPercent = Clamp(bruto.Value);
            amostra.Flags.Add(CollectFlags.CpuRawFallback);
            _log.LogWarning(
                "CPU formatada devolveu 0 mas o contador bruto indica {Bruto:F1}% — " +
                "cache de contadores provavelmente corrompido. Considere 'lodctr /R' nesta máquina.",
                bruto.Value);
            return;
        }

        amostra.CpuPercent = Clamp(formatado.Value);
    }

    /// <summary>
    /// CPU a partir de Win32_PerfRawData_PerfOS_Processor.
    ///
    /// PercentProcessorTime bruto é um contador do tipo PERF_100NSEC_TIMER_INV:
    /// ele acumula tempo OCIOSO, não ocupado. A fórmula é
    ///   ocupado% = 100 * (1 - Δcontador / Δtimestamp)
    /// com ambos em unidades de 100 ns.
    ///
    /// Devolve null no primeiro ciclo — não há delta sem amostra anterior.
    /// </summary>
    private double? LerCpuBruto()
    {
        var (linhas, _) = _cim.TryQuery(
            CimQuery.NamespaceCimV2,
            "SELECT Name, PercentProcessorTime, Timestamp_Sys100NS " +
            "FROM Win32_PerfRawData_PerfOS_Processor WHERE Name = '_Total'");

        if (linhas.Count == 0) return null;

        var contador = linhas[0].GetInt64("PercentProcessorTime");
        var timestamp = linhas[0].GetInt64("Timestamp_Sys100NS");

        if (contador is null || timestamp is null) return null;

        var anteriorContador = _rawAnterior;
        var anteriorTimestamp = _rawTimestampAnterior;

        _rawAnterior = contador;
        _rawTimestampAnterior = timestamp;

        if (anteriorContador is null || anteriorTimestamp is null) return null;

        var deltaContador = contador.Value - anteriorContador.Value;
        var deltaTempo = timestamp.Value - anteriorTimestamp.Value;

        // Contador reiniciado (reboot) ou relógio andando para trás.
        if (deltaTempo <= 0 || deltaContador < 0) return null;

        var ocupado = 100.0 * (1.0 - ((double)deltaContador / deltaTempo));
        return Clamp(ocupado);
    }

    // -------------------------------------------------------------------------
    private void CollectSystemCounters(MetricSample amostra)
    {
        var (linhas, _) = _cim.TryQuery(
            CimQuery.NamespaceCimV2,
            "SELECT ProcessorQueueLength, Processes, Threads, SystemUpTime " +
            "FROM Win32_PerfFormattedData_PerfOS_System");

        if (linhas.Count > 0)
        {
            var r = linhas[0];
            amostra.CpuQueueLength = r.GetDouble("ProcessorQueueLength");
            amostra.ProcessCount = r.GetInt32("Processes");
            amostra.ThreadCount = r.GetInt32("Threads");
            amostra.UptimeSeconds = r.GetInt64("SystemUpTime");
        }

        // Fallback do uptime por LastBootUpTime: SystemUpTime some quando o
        // provedor de contadores está com problema, mas o boot não.
        if (amostra.UptimeSeconds is null or <= 0)
        {
            var (os, _) = _cim.TryQuery(
                CimQuery.NamespaceCimV2,
                "SELECT LastBootUpTime FROM Win32_OperatingSystem");

            var boot = os.Count > 0 ? os[0].GetDateTime("LastBootUpTime") : null;
            if (boot is not null)
            {
                var segundos = (long)(DateTime.Now - boot.Value).TotalSeconds;
                amostra.UptimeSeconds = segundos > 0 ? segundos : null;
            }
        }
    }

    // -------------------------------------------------------------------------
    private void CollectMemory(MetricSample amostra)
    {
        var (linhas, falha) = _cim.TryQuery(
            CimQuery.NamespaceCimV2,
            "SELECT TotalVisibleMemorySize, FreePhysicalMemory FROM Win32_OperatingSystem");

        if (linhas.Count == 0)
        {
            amostra.Flags.Add(CollectFlags.MemoryUnavailable);
            _log.LogDebug("memória indisponível: {Motivo}", falha?.Message ?? "sem linha");
            return;
        }

        // Win32_OperatingSystem reporta em KILOBYTES.
        var totalKb = linhas[0].GetInt64("TotalVisibleMemorySize");
        var livreKb = linhas[0].GetInt64("FreePhysicalMemory");

        if (totalKb is > 0)
        {
            amostra.MemTotalMb = (int)(totalKb.Value / 1024);

            if (livreKb is >= 0 && livreKb <= totalKb)
            {
                amostra.MemUsedMb = (int)((totalKb.Value - livreKb.Value) / 1024);
            }
        }
        else
        {
            amostra.Flags.Add(CollectFlags.MemoryUnavailable);
        }

        // Page file em MB. Ausência não é erro: máquina pode estar sem page file.
        var (pf, _) = _cim.TryQuery(
            CimQuery.NamespaceCimV2,
            "SELECT CurrentUsage FROM Win32_PageFileUsage");

        if (pf.Count > 0)
        {
            var soma = 0;
            foreach (var linha in pf)
            {
                soma += linha.GetInt32("CurrentUsage") ?? 0;
            }
            amostra.SwapUsedMb = soma;
        }
    }

    // -------------------------------------------------------------------------
    /// <summary>
    /// Metadados da máquina. Coletado com menos frequência que as métricas —
    /// modelo de CPU não muda a cada minuto.
    /// </summary>
    public MachineInfo CollectMachineInfo()
    {
        var info = new MachineInfo
        {
            // Regra 11: hostname é ATRIBUTO. A identidade é o GUID do
            // provisionamento, então renomear a máquina não cria série nova.
            Hostname = Environment.MachineName,
            IpLan = DescobrirIpLan(),
        };

        var (os, _) = _cim.TryQuery(
            CimQuery.NamespaceCimV2,
            "SELECT Caption, Version, OSArchitecture, TotalVisibleMemorySize FROM Win32_OperatingSystem");

        if (os.Count > 0)
        {
            info.OsCaption = os[0].GetString("Caption");
            info.OsVersion = os[0].GetString("Version");
            // Traduzido em pt-BR ("64 bits"). Guardado como atributo, nunca
            // usado em comparação.
            info.OsArch = os[0].GetString("OSArchitecture");

            var totalKb = os[0].GetInt64("TotalVisibleMemorySize");
            if (totalKb is > 0) info.MemTotalMb = (int)(totalKb.Value / 1024);
        }

        var (cpu, _) = _cim.TryQuery(
            CimQuery.NamespaceCimV2,
            "SELECT Name, NumberOfCores FROM Win32_Processor");

        if (cpu.Count > 0)
        {
            info.CpuModel = cpu[0].GetString("Name");

            var nucleos = 0;
            foreach (var linha in cpu)
            {
                nucleos += linha.GetInt32("NumberOfCores") ?? 0;
            }
            if (nucleos > 0) info.CpuCores = nucleos;
        }

        return info;
    }

    /// <summary>
    /// IP da LAN. Percorre as interfaces em vez de resolver o hostname: em
    /// máquina com Hyper-V, VirtualBox ou VPN, resolver o nome devolve o
    /// adaptador virtual e o dado fica inútil para localizar a máquina na loja.
    /// </summary>
    private string? DescobrirIpLan()
    {
        try
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up) continue;
                if (nic.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel)
                    continue;

                foreach (var end in nic.GetIPProperties().UnicastAddresses)
                {
                    if (end.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                    if (System.Net.IPAddress.IsLoopback(end.Address)) continue;

                    var s = end.Address.ToString();
                    // 169.254/16 é link-local: significa DHCP falhou, não é
                    // endereço útil para achar a máquina.
                    if (s.StartsWith("169.254.", StringComparison.Ordinal)) continue;

                    return s;
                }
            }
        }
        catch (Exception ex)
        {
            _log.LogDebug(ex, "não foi possível descobrir o IP da LAN");
        }

        return null;
    }

    private static double Clamp(double v) => Math.Round(Math.Clamp(v, 0, 100), 2);

    public static string FormatInvariant(double v) =>
        v.ToString("F2", CultureInfo.InvariantCulture);
}
