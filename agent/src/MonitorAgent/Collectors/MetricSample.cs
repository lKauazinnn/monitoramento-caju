using System.Text.Json.Serialization;

namespace MonitorAgent.Collectors;

/// <summary>
/// Vocabulário fechado de sinalizadores de coleta degradada.
/// Vai para metrics.collect_flags e é o que distingue "não tem sensor" de
/// "não consegui ler o sensor" — os dois viram null na métrica, e sem o flag
/// o diagnóstico é impossível.
/// </summary>
public static class CollectFlags
{
    /// <summary>Sensor existe mas o acesso foi negado (falta elevação).</summary>
    public const string TempDenied = "temp_denied";

    /// <summary>A máquina não expõe zona térmica via ACPI.</summary>
    public const string TempUnavailable = "temp_unavailable";

    public const string SmartDenied = "smart_denied";
    public const string SmartUnavailable = "smart_unavailable";

    /// <summary>CPU vinda do delta de PerfRawData porque o formatado veio zerado.</summary>
    public const string CpuRawFallback = "cpu_raw_fallback";

    public const string CpuUnavailable = "cpu_unavailable";
    public const string MemoryUnavailable = "memory_unavailable";
    public const string DiskUnavailable = "disk_unavailable";
    public const string ServicesUnavailable = "services_unavailable";

    /// <summary>Gateway configurado não respondeu ao ping.</summary>
    public const string GatewayUnreachable = "gw_unreachable";

    /// <summary>Não há gatewayIp configurado — medição desligada, não falha.</summary>
    public const string GatewayNotConfigured = "gw_not_configured";

    public const string CentralUnreachable = "central_unreachable";
}

/// <summary>
/// Uma amostra. Os nomes JSON são o contrato com register_metrics — mudá-los
/// exige mudar o banco junto.
/// </summary>
public sealed class MetricSample
{
    /// <summary>
    /// Relógio do AGENTE em UTC (regra 12). É a chave da série e nunca é
    /// substituído pelo servidor. Formato ISO 8601 com "Z".
    /// </summary>
    [JsonPropertyName("t")]
    public string Timestamp { get; set; } = "";

    [JsonPropertyName("cpu_pct")]
    public double? CpuPercent { get; set; }

    [JsonPropertyName("cpu_queue_length")]
    public double? CpuQueueLength { get; set; }

    [JsonPropertyName("mem_total_mb")]
    public int? MemTotalMb { get; set; }

    [JsonPropertyName("mem_used_mb")]
    public int? MemUsedMb { get; set; }

    // mem_pct NÃO é enviado: o servidor deriva de used/total.

    [JsonPropertyName("swap_used_mb")]
    public int? SwapUsedMb { get; set; }

    [JsonPropertyName("uptime_seconds")]
    public long? UptimeSeconds { get; set; }

    [JsonPropertyName("proc_count")]
    public int? ProcessCount { get; set; }

    [JsonPropertyName("thread_count")]
    public int? ThreadCount { get; set; }

    [JsonPropertyName("cpu_temp_c")]
    public double? CpuTempC { get; set; }

    [JsonPropertyName("gw_latency_ms")]
    public double? GatewayLatencyMs { get; set; }

    [JsonPropertyName("gw_loss_pct")]
    public double? GatewayLossPercent { get; set; }

    [JsonPropertyName("central_latency_ms")]
    public double? CentralLatencyMs { get; set; }

    [JsonPropertyName("flags")]
    public List<string> Flags { get; set; } = new();

    [JsonPropertyName("disks")]
    public List<DiskSample> Disks { get; set; } = new();

    [JsonPropertyName("services")]
    public List<ServiceSample> Services { get; set; } = new();
}

public sealed class DiskSample
{
    [JsonPropertyName("drive")]
    public string Drive { get; set; } = "";

    [JsonPropertyName("volume_label")]
    public string? VolumeLabel { get; set; }

    [JsonPropertyName("filesystem")]
    public string? FileSystem { get; set; }

    [JsonPropertyName("total_gb")]
    public double? TotalGb { get; set; }

    [JsonPropertyName("free_gb")]
    public double? FreeGb { get; set; }

    // free_pct é derivado no servidor.

    [JsonPropertyName("smart_ok")]
    public bool? SmartOk { get; set; }

    /// <summary>"wmi", "smartctl" ou "none" — outros valores o servidor anula.</summary>
    [JsonPropertyName("smart_source")]
    public string? SmartSource { get; set; }

    [JsonPropertyName("smart_reallocated")]
    public int? SmartReallocated { get; set; }

    [JsonPropertyName("smart_power_on_hours")]
    public int? SmartPowerOnHours { get; set; }

    [JsonPropertyName("smart_wear_pct")]
    public double? SmartWearPercent { get; set; }

    [JsonPropertyName("media_type")]
    public string? MediaType { get; set; }
}

public sealed class ServiceSample
{
    /// <summary>Nome CURTO do serviço (ServiceName), nunca DisplayName.</summary>
    [JsonPropertyName("name")]
    public string Name { get; set; } = "";

    /// <summary>
    /// O campo que decide alerta. Derivado de Win32_Service.Started (booleano).
    /// Serviço não encontrado => false, porque um serviço crítico ausente é um
    /// problema, não um dado faltante.
    /// </summary>
    [JsonPropertyName("is_running")]
    public bool IsRunning { get; set; }

    [JsonPropertyName("start_mode")]
    public string? StartMode { get; set; }

    /// <summary>
    /// String de estado como o SO reportou. Medido em Windows 11 pt-BR:
    /// Win32_Service.State devolve "Running" (invariante, vem do MOF). Guardado
    /// apenas para diagnóstico — nunca comparado.
    /// </summary>
    [JsonPropertyName("state_raw")]
    public string? StateRaw { get; set; }

    [JsonPropertyName("pid")]
    public int? Pid { get; set; }
}

/// <summary>Metadados da máquina, enviados no envelope (não por amostra).</summary>
public sealed class MachineInfo
{
    [JsonPropertyName("hostname")]
    public string? Hostname { get; set; }

    [JsonPropertyName("os_caption")]
    public string? OsCaption { get; set; }

    [JsonPropertyName("os_version")]
    public string? OsVersion { get; set; }

    /// <summary>Localizado em pt-BR ("64 bits"). Atributo, nunca usado em lógica.</summary>
    [JsonPropertyName("os_arch")]
    public string? OsArch { get; set; }

    [JsonPropertyName("cpu_model")]
    public string? CpuModel { get; set; }

    [JsonPropertyName("cpu_cores")]
    public int? CpuCores { get; set; }

    [JsonPropertyName("mem_total_mb")]
    public int? MemTotalMb { get; set; }

    [JsonPropertyName("ip_lan")]
    public string? IpLan { get; set; }
}

/// <summary>Envelope do POST /ingest.</summary>
public sealed class IngestEnvelope
{
    [JsonPropertyName("agent_version")]
    public string AgentVersion { get; set; } = "";

    /// <summary>
    /// Relógio do agente no momento do ENVIO, não da coleta. É como o servidor
    /// mede drift sem confundir com reenvio de spool.
    /// </summary>
    [JsonPropertyName("sent_at")]
    public string SentAt { get; set; } = "";

    [JsonPropertyName("machine")]
    public MachineInfo? Machine { get; set; }

    [JsonPropertyName("samples")]
    public List<MetricSample> Samples { get; set; } = new();
}
