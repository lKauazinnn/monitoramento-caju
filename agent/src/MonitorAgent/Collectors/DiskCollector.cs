using Microsoft.Extensions.Logging;

namespace MonitorAgent.Collectors;

/// <summary>
/// Espaço em disco e saúde de mídia.
///
/// MEDIDO nesta máquina (Windows 11 pt-BR, sessão NÃO elevada):
///   Win32_LogicalDisk                       -> ok
///   MSFT_PhysicalDisk (HealthStatus/MediaType) -> ok SEM elevação
///   MSStorageDriver_FailurePredictStatus    -> Acesso negado
///   MSFT_StorageReliabilityCounter          -> recurso indisponível ao cliente
///
/// Ou seja: rodando como serviço (LocalSystem) o SMART detalhado aparece;
/// rodando em console sem elevação, não. Os flags smart_denied e
/// smart_unavailable distinguem os dois casos para que ninguém conclua
/// "esse disco não tem SMART" quando o problema é privilégio.
/// </summary>
public sealed class DiskCollector
{
    private readonly CimQuery _cim;
    private readonly ILogger<DiskCollector> _log;

    // A saúde física é por DISCO, não por volume, e não muda a cada minuto.
    // Consultada a cada N ciclos para não pagar o custo de root\wmi sempre.
    private const int CiclosEntreLeiturasDeSaude = 15;
    private int _ciclo;
    private SaudeFisica _saudeCache = SaudeFisica.Vazia;

    public DiskCollector(CimQuery cim, ILogger<DiskCollector> log)
    {
        _cim = cim;
        _log = log;
    }

    public void Collect(MetricSample amostra)
    {
        // DriveType=3 é disco fixo. Removível e rede ficam de fora: um pendrive
        // esquecido no PDV geraria alerta de disco cheio todo dia.
        var (volumes, falha) = _cim.TryQuery(
            CimQuery.NamespaceCimV2,
            "SELECT DeviceID, VolumeName, FileSystem, Size, FreeSpace " +
            "FROM Win32_LogicalDisk WHERE DriveType = 3");

        if (volumes.Count == 0)
        {
            amostra.Flags.Add(CollectFlags.DiskUnavailable);
            _log.LogDebug("nenhum volume fixo retornado: {Motivo}", falha?.Message ?? "lista vazia");
            return;
        }

        if (_ciclo % CiclosEntreLeiturasDeSaude == 0)
        {
            _saudeCache = LerSaudeFisica(amostra);
        }
        else if (_saudeCache.Flag is { } flagCache)
        {
            // O flag acompanha toda amostra, senão o dashboard mostraria
            // "SMART ok" em 14 de cada 15 amostras e "indisponível" numa.
            amostra.Flags.Add(flagCache);
        }
        _ciclo++;

        foreach (var v in volumes)
        {
            var deviceId = v.GetString("DeviceID");
            if (string.IsNullOrWhiteSpace(deviceId)) continue;

            var tamanho = v.GetInt64("Size");
            var livre = v.GetInt64("FreeSpace");

            var disco = new DiskSample
            {
                Drive = deviceId,
                VolumeLabel = v.GetString("VolumeName"),
                FileSystem = v.GetString("FileSystem"),
                TotalGb = tamanho is > 0 ? BytesParaGb(tamanho.Value) : null,
                FreeGb = livre is >= 0 ? BytesParaGb(livre.Value) : null,
                SmartOk = _saudeCache.SmartOk,
                SmartSource = _saudeCache.Fonte,
                MediaType = _saudeCache.MediaType,
                SmartPowerOnHours = _saudeCache.PowerOnHours,
                SmartWearPercent = _saudeCache.WearPercent,
            };

            // free_pct NÃO é enviado: o servidor deriva de free/total.
            amostra.Disks.Add(disco);
        }
    }

    /// <summary>
    /// Saúde física, na ordem do mais informativo para o mais disponível.
    ///
    /// Não há tentativa de casar volume com disco físico: mapear C: para o disco
    /// 0 exige percorrer MSFT_Partition e MSFT_Disk, e em máquina com RAID ou
    /// storage spaces o mapeamento é ambíguo. O agente reporta a PIOR saúde
    /// entre os discos físicos e aplica a todos os volumes — para "esse PDV tem
    /// disco morrendo" isso basta, e é honesto sobre a granularidade.
    /// </summary>
    private SaudeFisica LerSaudeFisica(MetricSample amostra)
    {
        // 1. MSFT_StorageReliabilityCounter: desgaste, horas ligado, temperatura.
        var (rel, falhaRel) = _cim.TryQuery(
            CimQuery.NamespaceStorage,
            "SELECT DeviceId, Wear, PowerOnHours, ReadErrorsUncorrected FROM MSFT_StorageReliabilityCounter");

        int? horas = null;
        double? desgaste = null;

        if (rel.Count > 0)
        {
            foreach (var r in rel)
            {
                var h = r.GetInt32("PowerOnHours");
                if (h is > 0 && (horas is null || h > horas)) horas = h;

                var w = r.GetDouble("Wear");
                if (w is >= 0 && (desgaste is null || w > desgaste)) desgaste = w;
            }
        }

        // 2. MSFT_PhysicalDisk: funciona sem elevação e dá HealthStatus.
        var (fisicos, falhaFisico) = _cim.TryQuery(
            CimQuery.NamespaceStorage,
            "SELECT FriendlyName, MediaType, HealthStatus FROM MSFT_PhysicalDisk");

        if (fisicos.Count > 0)
        {
            bool? ok = true;
            string? tipo = null;

            foreach (var d in fisicos)
            {
                // HealthStatus: 0=Healthy, 1=Warning, 2=Unhealthy.
                var saude = d.GetInt32("HealthStatus");
                if (saude is not null && saude != 0) ok = false;

                tipo ??= TraduzirMediaType(d.GetInt32("MediaType"));
            }

            return new SaudeFisica(ok, "wmi", tipo, horas, desgaste, null);
        }

        // 3. Último recurso: predição booleana do driver (exige elevação).
        var (pred, falhaPred) = _cim.TryQuery(
            CimQuery.NamespaceWmi,
            "SELECT InstanceName, PredictFailure FROM MSStorageDriver_FailurePredictStatus");

        if (pred.Count > 0)
        {
            bool? ok = true;
            foreach (var p in pred)
            {
                if (p.GetBool("PredictFailure") == true) ok = false;
            }
            return new SaudeFisica(ok, "wmi", null, horas, desgaste, null);
        }

        // Nada funcionou: distinguir privilégio de ausência é o que evita
        // diagnóstico errado.
        var negado = (falhaFisico?.AccessDenied ?? false)
                  || (falhaPred?.AccessDenied ?? false)
                  || (falhaRel?.AccessDenied ?? false);

        var flag = negado ? CollectFlags.SmartDenied : CollectFlags.SmartUnavailable;
        amostra.Flags.Add(flag);

        if (negado)
        {
            _log.LogDebug(
                "SMART inacessível por privilégio. Como serviço (LocalSystem) funciona; " +
                "em console é preciso elevar.");
        }

        return new SaudeFisica(null, "none", null, horas, desgaste, flag);
    }

    private static string? TraduzirMediaType(int? valor) => valor switch
    {
        3 => "HDD",
        4 => "SSD",
        5 => "SCM",
        _ => null,
    };

    private static double BytesParaGb(long bytes) =>
        Math.Round(bytes / 1024.0 / 1024.0 / 1024.0, 2);

    private sealed record SaudeFisica(
        bool? SmartOk,
        string? Fonte,
        string? MediaType,
        int? PowerOnHours,
        double? WearPercent,
        string? Flag)
    {
        public static readonly SaudeFisica Vazia = new(null, "none", null, null, null, null);
    }
}
