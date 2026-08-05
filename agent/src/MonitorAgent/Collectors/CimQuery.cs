using Microsoft.Extensions.Logging;
using Microsoft.Management.Infrastructure;

namespace MonitorAgent.Collectors;

/// <summary>
/// Acesso a CIM com uma sessão reaproveitada e leitura de propriedade tolerante.
///
/// REGRA 10, na prática: só classes CIM são consultadas, nunca
/// PerformanceCounter com nome de categoria. Nomes de classe e de propriedade em
/// CIM vêm do MOF e são invariantes de idioma; nomes de categoria de contador de
/// desempenho são LOCALIZADOS e quebram em Windows pt-BR.
///
/// Medições feitas em Windows 11 Pro 10.0.26200 pt-BR, sessão NÃO elevada:
///   Win32_PerfFormattedData_PerfOS_Processor.PercentProcessorTime -> 11    (ok)
///   Win32_PerfFormattedData_PerfOS_System.ProcessorQueueLength     -> 0     (ok)
///   Win32_Service.State                                           -> "Running" (invariante)
///   Win32_Service.DisplayName                                     -> "Spooler de Impressão" (traduzido)
///   Win32_OperatingSystem.OSArchitecture                          -> "64 bits" (traduzido)
///   MSAcpi_ThermalZoneTemperature                                 -> Acesso negado
///   MSStorageDriver_FailurePredictStatus                          -> Acesso negado
///   MSFT_PhysicalDisk                                             -> ok sem elevação
/// </summary>
public sealed class CimQuery : IDisposable
{
    public const string NamespaceCimV2 = @"root\cimv2";
    public const string NamespaceWmi = @"root\wmi";
    public const string NamespaceStorage = @"root\microsoft\windows\storage";

    private readonly ILogger<CimQuery> _log;
    private CimSession? _session;
    private bool _disposed;

    public CimQuery(ILogger<CimQuery> log) => _log = log;

    private CimSession Session
    {
        get
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            // Sessão local (DCOM), criada sob demanda e reaproveitada: criar uma
            // por ciclo custa handles e latência à toa.
            return _session ??= CimSession.Create(null);
        }
    }

    /// <summary>
    /// Executa WQL e devolve as instâncias materializadas.
    ///
    /// As instâncias são copiadas para uma lista e liberadas aqui: manter
    /// CimInstance vivo depois do enumerador é vazamento de handle COM, e num
    /// serviço que roda por meses isso aparece como esgotamento de memória.
    /// </summary>
    public List<CimRow> Query(string ns, string wql)
    {
        var linhas = new List<CimRow>();

        using var enumerador = Session.QueryInstances(ns, "WQL", wql).GetEnumerator();

        while (enumerador.MoveNext())
        {
            var inst = enumerador.Current;
            if (inst is null) continue;

            try
            {
                var valores = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
                foreach (var p in inst.CimInstanceProperties)
                {
                    valores[p.Name] = p.Value;
                }
                linhas.Add(new CimRow(valores));
            }
            finally
            {
                inst.Dispose();
            }
        }

        return linhas;
    }

    /// <summary>
    /// Consulta que não lança: devolve lista vazia e o motivo. É o que permite
    /// à regra 19 valer — falha de um sensor não derruba o ciclo.
    /// </summary>
    public (List<CimRow> Rows, CimFailure? Failure) TryQuery(string ns, string wql)
    {
        try
        {
            return (Query(ns, wql), null);
        }
        catch (CimException ex)
        {
            var negado = ex.NativeErrorCode is NativeErrorCode.AccessDenied;
            _log.LogDebug(
                "consulta CIM falhou ns={Namespace} wql={Wql} code={Code}: {Mensagem}",
                ns, wql, ex.NativeErrorCode, ex.Message);
            return (new List<CimRow>(), new CimFailure(negado, ex.Message));
        }
        catch (Exception ex)
        {
            // Inclui o caso de MI.dll ausente ou serviço WMI parado.
            _log.LogDebug(ex, "consulta CIM falhou de forma inesperada ns={Namespace} wql={Wql}", ns, wql);
            return (new List<CimRow>(), new CimFailure(false, ex.Message));
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _session?.Dispose();
        _session = null;
    }

    /// <summary>Força a recriação da sessão. Usado após falha suspeita de sessão morta.</summary>
    public void ResetSession()
    {
        _session?.Dispose();
        _session = null;
    }
}

public sealed record CimFailure(bool AccessDenied, string Message);

/// <summary>
/// Uma instância CIM já materializada, com conversões que nunca lançam.
///
/// Conversão tolerante é intencional: WMI devolve o mesmo campo como uint32,
/// uint64 ou string dependendo do provedor e da versão do Windows. Um cast
/// direto funcionaria na máquina de teste e estouraria num PDV específico.
/// </summary>
public sealed class CimRow
{
    private readonly Dictionary<string, object?> _valores;

    public CimRow(Dictionary<string, object?> valores) => _valores = valores;

    public object? Raw(string nome) => _valores.TryGetValue(nome, out var v) ? v : null;

    public string? GetString(string nome)
    {
        var v = Raw(nome);
        if (v is null) return null;
        var s = v as string ?? Convert.ToString(v, System.Globalization.CultureInfo.InvariantCulture);
        return string.IsNullOrWhiteSpace(s) ? null : s.Trim();
    }

    public double? GetDouble(string nome)
    {
        var v = Raw(nome);
        if (v is null) return null;

        try
        {
            // InvariantCulture obrigatório: em pt-BR o separador decimal é vírgula
            // e um Convert dependente de cultura leria 1.5 como 15.
            return Convert.ToDouble(v, System.Globalization.CultureInfo.InvariantCulture);
        }
        catch (Exception ex) when (ex is FormatException or InvalidCastException or OverflowException)
        {
            return null;
        }
    }

    public long? GetInt64(string nome)
    {
        var v = Raw(nome);
        if (v is null) return null;

        try
        {
            return Convert.ToInt64(v, System.Globalization.CultureInfo.InvariantCulture);
        }
        catch (Exception ex) when (ex is FormatException or InvalidCastException or OverflowException)
        {
            return null;
        }
    }

    public int? GetInt32(string nome)
    {
        var l = GetInt64(nome);
        if (l is null) return null;
        if (l > int.MaxValue || l < int.MinValue) return null;
        return (int)l.Value;
    }

    public bool? GetBool(string nome)
    {
        var v = Raw(nome);
        return v switch
        {
            null => null,
            bool b => b,
            string s when bool.TryParse(s, out var p) => p,
            _ => GetInt64(nome) is { } n ? n != 0 : null,
        };
    }

    public DateTime? GetDateTime(string nome)
    {
        var v = Raw(nome);
        return v switch
        {
            null => null,
            DateTime dt => dt,
            DateTimeOffset dto => dto.UtcDateTime,
            _ => null,
        };
    }
}
