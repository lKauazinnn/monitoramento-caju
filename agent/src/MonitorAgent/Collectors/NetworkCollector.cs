using System.Net.NetworkInformation;
using System.Net.Sockets;
using Microsoft.Extensions.Logging;

namespace MonitorAgent.Collectors;

/// <summary>
/// Latência até o gateway da loja e até a central.
///
/// O ping do gateway é o que distingue "a loja caiu" de "a internet da loja
/// caiu": gateway respondendo e central inalcançável significa problema de link
/// (ou de operadora, nos ER605 em load balance); gateway mudo significa
/// problema dentro da loja.
/// </summary>
public sealed class NetworkCollector
{
    private const int TentativasPorCiclo = 3;
    private const int TimeoutMs = 1000;

    private readonly ILogger<NetworkCollector> _log;
    private bool _jaAvisouGatewayAusente;

    public NetworkCollector(ILogger<NetworkCollector> log) => _log = log;

    public async Task CollectAsync(
        MetricSample amostra,
        string? gatewayIp,
        string? hostCentral,
        CancellationToken ct)
    {
        await MedirGatewayAsync(amostra, gatewayIp, ct).ConfigureAwait(false);
        await MedirCentralAsync(amostra, hostCentral, ct).ConfigureAwait(false);
    }

    private async Task MedirGatewayAsync(MetricSample amostra, string? gatewayIp, CancellationToken ct)
    {
        // Vazio DESLIGA a medição em vez de adivinhar. Adivinhar o gateway (por
        // exemplo assumir .1 na subnet) produziria série de latência de um
        // endereço que talvez não seja o roteador — dado errado é pior que dado
        // ausente, porque ninguém desconfia dele.
        if (string.IsNullOrWhiteSpace(gatewayIp))
        {
            amostra.Flags.Add(CollectFlags.GatewayNotConfigured);

            if (!_jaAvisouGatewayAusente)
            {
                _jaAvisouGatewayAusente = true;
                _log.LogInformation(
                    "gatewayIp não configurado: latência da LAN não será medida. " +
                    "Preencha em config.json para habilitar.");
            }
            return;
        }

        var (media, perda) = await PingarAsync(gatewayIp, ct).ConfigureAwait(false);

        amostra.GatewayLatencyMs = media;
        amostra.GatewayLossPercent = perda;

        if (perda >= 100)
        {
            amostra.Flags.Add(CollectFlags.GatewayUnreachable);
        }
    }

    private async Task MedirCentralAsync(MetricSample amostra, string? hostCentral, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(hostCentral)) return;

        // Uma tentativa só: a latência até a central já é medida de verdade pelo
        // tempo de resposta HTTP da ingestão. Este ping é só um sinal grosso de
        // alcançabilidade, e ICMP para a internet é frequentemente filtrado.
        try
        {
            using var ping = new Ping();
            var r = await ping.SendPingAsync(hostCentral, TimeoutMs).ConfigureAwait(false);

            if (r.Status == IPStatus.Success)
            {
                amostra.CentralLatencyMs = r.RoundtripTime;
            }
            else
            {
                amostra.Flags.Add(CollectFlags.CentralUnreachable);
            }
        }
        catch (Exception ex) when (ex is PingException or SocketException or InvalidOperationException)
        {
            // Nome não resolve, ICMP bloqueado, adaptador caindo no meio.
            amostra.Flags.Add(CollectFlags.CentralUnreachable);
            _log.LogDebug(ex, "ping para a central falhou: {Host}", hostCentral);
        }
    }

    private static async Task<(double? Media, double Perda)> PingarAsync(string alvo, CancellationToken ct)
    {
        var respostas = new List<long>(TentativasPorCiclo);
        var enviados = 0;

        for (var i = 0; i < TentativasPorCiclo; i++)
        {
            if (ct.IsCancellationRequested) break;

            enviados++;

            try
            {
                using var ping = new Ping();
                var r = await ping.SendPingAsync(alvo, TimeoutMs).ConfigureAwait(false);
                if (r.Status == IPStatus.Success) respostas.Add(r.RoundtripTime);
            }
            catch (Exception ex) when (ex is PingException or SocketException or InvalidOperationException)
            {
                // Conta como perda.
            }
        }

        if (enviados == 0) return (null, 0);

        var perda = 100.0 * (enviados - respostas.Count) / enviados;

        double? media = respostas.Count > 0
            ? Math.Round(respostas.Average(), 2)
            : null;

        return (media, Math.Round(perda, 2));
    }
}
