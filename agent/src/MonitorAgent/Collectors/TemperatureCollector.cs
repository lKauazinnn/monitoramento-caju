using Microsoft.Extensions.Logging;

namespace MonitorAgent.Collectors;

/// <summary>
/// Temperatura, best-effort e honesta sobre o motivo da falha.
///
/// MEDIDO nesta máquina (Windows 11 pt-BR, sessão NÃO elevada):
///   MSAcpi_ThermalZoneTemperature -> "Acesso negado"
///
/// Como serviço (LocalSystem) o acesso existe. Em console sem elevação, não.
/// Sem distinguir os dois casos, o diagnóstico natural é "essa máquina não tem
/// sensor" — e alguém perde horas atrás de um problema que não existe.
///
/// A grande maioria dos PDVs de varejo NÃO expõe zona térmica ACPI mesmo
/// elevado: é hardware de escritório, não servidor. Ausência é o caso comum e
/// esperado, por isso ela é registrada uma vez e nunca mais.
/// </summary>
public sealed class TemperatureCollector
{
    private readonly CimQuery _cim;
    private readonly ILogger<TemperatureCollector> _log;

    private bool _jaAvisou;
    private bool _desistiu;
    private int _falhasConsecutivas;

    // Depois disto o coletor para de tentar: consultar root\wmi a cada minuto
    // numa máquina que nunca vai responder é custo puro.
    private const int FalhasAteDesistir = 10;

    public TemperatureCollector(CimQuery cim, ILogger<TemperatureCollector> log)
    {
        _cim = cim;
        _log = log;
    }

    public void Collect(MetricSample amostra)
    {
        if (_desistiu)
        {
            amostra.Flags.Add(CollectFlags.TempUnavailable);
            return;
        }

        var (linhas, falha) = _cim.TryQuery(
            CimQuery.NamespaceWmi,
            "SELECT InstanceName, CurrentTemperature FROM MSAcpi_ThermalZoneTemperature");

        if (linhas.Count == 0)
        {
            _falhasConsecutivas++;

            var negado = falha?.AccessDenied ?? false;
            amostra.Flags.Add(negado ? CollectFlags.TempDenied : CollectFlags.TempUnavailable);

            if (!_jaAvisou)
            {
                _jaAvisou = true;
                if (negado)
                {
                    _log.LogWarning(
                        "temperatura inacessível por PRIVILÉGIO. Rodando como serviço isto funciona; " +
                        "em modo console é preciso terminal elevado. Não é ausência de sensor.");
                }
                else
                {
                    _log.LogInformation(
                        "esta máquina não expõe zona térmica ACPI — normal em hardware de PDV. " +
                        "A temperatura ficará nula e o coletor será desligado após {N} tentativas.",
                        FalhasAteDesistir);
                }
            }

            // Acesso negado pode mudar (o serviço sobe elevado depois do teste em
            // console), então só a AUSÊNCIA faz desistir.
            if (!negado && _falhasConsecutivas >= FalhasAteDesistir)
            {
                _desistiu = true;
                _log.LogInformation("coletor de temperatura desligado após {N} tentativas sem sensor.",
                    FalhasAteDesistir);
            }

            return;
        }

        _falhasConsecutivas = 0;

        // CurrentTemperature vem em DÉCIMOS DE KELVIN. 3032 => 30,05 °C.
        double? maiorC = null;

        foreach (var linha in linhas)
        {
            var decimosKelvin = linha.GetDouble("CurrentTemperature");
            if (decimosKelvin is null or <= 0) continue;

            var celsius = (decimosKelvin.Value / 10.0) - 273.15;

            // Faixa igual à do CHECK no banco. Sensor devolvendo lixo (0 K, ou
            // 128 constante em placas defeituosas) entra como ausente em vez de
            // virar dado falso ou fazer o servidor rejeitar o lote.
            if (celsius is < -20 or > 150) continue;

            if (maiorC is null || celsius > maiorC) maiorC = celsius;
        }

        if (maiorC is null)
        {
            amostra.Flags.Add(CollectFlags.TempUnavailable);
            return;
        }

        // A MAIOR zona térmica, não a média: o que interessa é o pior ponto.
        amostra.CpuTempC = Math.Round(maiorC.Value, 1);
    }
}
