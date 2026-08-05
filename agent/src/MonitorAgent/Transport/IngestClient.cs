using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using MonitorAgent.Collectors;
using MonitorAgent.Config;

namespace MonitorAgent.Transport;

/// <summary>
/// Classificação da resposta do servidor. Existe porque a decisão "posso apagar
/// o spool?" precisa ser explícita e não inferida de um código HTTP no meio do
/// Worker (regra 14).
/// </summary>
public enum IngestOutcome
{
    /// <summary>Gravado (ou já estava gravado). Pode apagar do spool.</summary>
    Success,

    /// <summary>
    /// O servidor rejeitou este payload de forma permanente (400). Reenviar
    /// igual não vai mudar nada; apagar é a única saída para não travar a fila.
    /// </summary>
    PermanentReject,

    /// <summary>
    /// Credencial inválida (401). NÃO apagar: o token pode ser reconfigurado e
    /// o dado ainda vale.
    /// </summary>
    Unauthorized,

    /// <summary>Rate limit (429). Recuar e tentar depois.</summary>
    RateLimited,

    /// <summary>
    /// Janela temporal (422). NÃO apagar: o relógio pode ser corrigido e aí o
    /// dado passa a ser aceito.
    /// </summary>
    ClockRejected,

    /// <summary>Falha transitória (5xx, timeout, DNS, link caído). Tentar de novo.</summary>
    Transient,
}

public sealed record IngestResult(
    IngestOutcome Outcome,
    int StatusCode,
    string? ServerCode,
    string Message,
    int Accepted,
    int Duplicates,
    int OutOfWindow,
    int? ClockDriftSeconds,
    TimeSpan? RetryAfter)
{
    public bool CanDelete => Outcome is IngestOutcome.Success or IngestOutcome.PermanentReject;
}

/// <summary>
/// Cliente HTTP da ingestão.
///
/// Regra 18: timeout explícito, retry com backoff exponencial e jitter.
/// Regra 9: recusa URL que não seja HTTPS — a validação está em AgentConfig e
/// aqui há uma segunda checagem, porque um config editado à mão em produção não
/// passa necessariamente pela validação de partida.
/// </summary>
public sealed class IngestClient
{
    private readonly HttpClient _http;
    private readonly AgentConfig _cfg;
    private readonly ILogger<IngestClient> _log;
    private readonly string _versaoAgente;

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    public IngestClient(HttpClient http, AgentConfig cfg, string versaoAgente, ILogger<IngestClient> log)
    {
        _http = http;
        _cfg = cfg;
        _versaoAgente = versaoAgente;
        _log = log;

        // Regra 18: timeout explícito. Sem isto o HttpClient espera 100 segundos
        // por padrão, e num link ruim o ciclo de coleta inteiro fica pendurado.
        _http.Timeout = TimeSpan.FromSeconds(cfg.Http.TimeoutSeconds);
    }

    public async Task<IngestResult> SendAsync(
        IReadOnlyList<MetricSample> amostras,
        MachineInfo? maquina,
        CancellationToken ct)
    {
        if (!_cfg.IngestUrl.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
        {
            return new IngestResult(IngestOutcome.PermanentReject, 0, null,
                "ingestUrl não é HTTPS — envio bloqueado pelo agente", 0, 0, 0, null, null);
        }

        var envelope = new IngestEnvelope
        {
            AgentVersion = _versaoAgente,
            // Relógio do agente NO ENVIO. É como o servidor mede drift sem
            // confundir com reenvio de spool.
            SentAt = DateTime.UtcNow.ToString("O"),
            Machine = maquina,
            Samples = amostras.ToList(),
        };

        using var req = new HttpRequestMessage(HttpMethod.Post, _cfg.IngestUrl)
        {
            Content = JsonContent.Create(envelope, options: JsonOpts),
        };

        // Segredo compartilhado da função (regra 6) + token da máquina (regra 2).
        req.Headers.TryAddWithoutValidation("x-monitor-secret", _cfg.SharedSecret);
        req.Headers.TryAddWithoutValidation("Authorization", $"Bearer {_cfg.Token}");

        try
        {
            using var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseContentRead, ct)
                                        .ConfigureAwait(false);

            var corpo = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            return Interpretar(resp, corpo);
        }
        catch (TaskCanceledException) when (ct.IsCancellationRequested)
        {
            // Desligamento do serviço, não falha de rede.
            throw;
        }
        catch (TaskCanceledException)
        {
            return Transitorio(0, $"timeout de {_cfg.Http.TimeoutSeconds}s no envio");
        }
        catch (HttpRequestException ex)
        {
            // Link caído, DNS sem resposta, TLS recusado. É o caso NORMAL numa
            // loja com link instável — por isso é Debug, não Error: um Error por
            // minuto durante uma queda de 6 horas enche o log e esconde o resto.
            _log.LogDebug(ex, "envio falhou por rede");
            return Transitorio(0, $"rede: {ex.Message}");
        }
    }

    /// <summary>GET /healthz — usado pelo modo de diagnóstico.</summary>
    public async Task<(bool Ok, string Detalhe)> CheckHealthAsync(CancellationToken ct)
    {
        var url = _cfg.IngestUrl.TrimEnd('/') + "/healthz";

        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.TryAddWithoutValidation("x-monitor-secret", _cfg.SharedSecret);

            using var resp = await _http.SendAsync(req, ct).ConfigureAwait(false);
            var corpo = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);

            return (resp.IsSuccessStatusCode, $"HTTP {(int)resp.StatusCode}: {corpo}");
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
        {
            return (false, ex.Message);
        }
    }

    private IngestResult Interpretar(HttpResponseMessage resp, string corpo)
    {
        var status = (int)resp.StatusCode;

        string? codigoServidor = null;
        var mensagem = corpo;
        var aceitos = 0;
        var duplicados = 0;
        var foraJanela = 0;
        int? drift = null;

        try
        {
            using var doc = JsonDocument.Parse(corpo);
            var raiz = doc.RootElement;

            if (raiz.ValueKind == JsonValueKind.Object)
            {
                if (raiz.TryGetProperty("code", out var c) && c.ValueKind == JsonValueKind.String)
                    codigoServidor = c.GetString();

                if (raiz.TryGetProperty("error", out var e) && e.ValueKind == JsonValueKind.String)
                    mensagem = e.GetString() ?? corpo;

                if (raiz.TryGetProperty("accepted", out var a) && a.TryGetInt32(out var av)) aceitos = av;
                if (raiz.TryGetProperty("duplicates", out var d) && d.TryGetInt32(out var dv)) duplicados = dv;
                if (raiz.TryGetProperty("out_of_window", out var o) && o.TryGetInt32(out var ov)) foraJanela = ov;
                if (raiz.TryGetProperty("clock_drift_seconds", out var k) && k.TryGetInt32(out var kv)) drift = kv;
            }
        }
        catch (JsonException)
        {
            // Corpo não-JSON (gateway devolvendo HTML de erro, por exemplo).
            // A mensagem crua já está em `mensagem`.
        }

        TimeSpan? retryAfter = null;
        if (resp.Headers.RetryAfter?.Delta is { } delta) retryAfter = delta;
        else if (resp.Headers.RetryAfter?.Date is { } data) retryAfter = data - DateTimeOffset.UtcNow;

        var desfecho = status switch
        {
            >= 200 and < 300 => IngestOutcome.Success,
            400 => IngestOutcome.PermanentReject,
            401 or 403 => IngestOutcome.Unauthorized,
            413 => IngestOutcome.PermanentReject,
            422 => IngestOutcome.ClockRejected,
            429 => IngestOutcome.RateLimited,
            // 404 é config errada (URL sem /ingest, função não publicada). É
            // permanente do ponto de vista deste payload, mas o dado continua
            // válido — então Transient, para não apagar o spool por erro de URL.
            404 => IngestOutcome.Transient,
            _ => IngestOutcome.Transient,
        };

        return new IngestResult(desfecho, status, codigoServidor,
            Encurtar(mensagem), aceitos, duplicados, foraJanela, drift, retryAfter);
    }

    private static IngestResult Transitorio(int status, string mensagem) =>
        new(IngestOutcome.Transient, status, null, Encurtar(mensagem), 0, 0, 0, null, null);

    private static string Encurtar(string? s)
    {
        if (string.IsNullOrEmpty(s)) return "(sem detalhe)";
        var limpo = s.ReplaceLineEndings(" ").Trim();
        return limpo.Length > 300 ? limpo[..300] + "..." : limpo;
    }
}

/// <summary>
/// Backoff exponencial com jitter (regra 18).
///
/// O jitter não é enfeite: 150 PDVs voltando ao mesmo tempo depois de uma queda
/// de link regional, todos com o mesmo backoff determinístico, batem no servidor
/// no mesmo segundo — e continuam sincronizados em cada tentativa seguinte. O
/// resultado é indistinguível de ataque e derruba a ingestão justamente quando
/// ela é mais necessária.
/// </summary>
public sealed class Backoff
{
    private readonly HttpConfig _cfg;
    private int _tentativa;

    public Backoff(HttpConfig cfg) => _cfg = cfg;

    public int Attempt => _tentativa;

    public void Reset() => _tentativa = 0;

    public TimeSpan Next()
    {
        _tentativa++;

        // Expoente limitado a 16 antes do shift: 2^31 estoura o int e o atraso
        // viraria negativo.
        var expoente = Math.Min(_tentativa - 1, 16);
        var baseSeg = (double)_cfg.BaseBackoffSeconds * Math.Pow(2, expoente);
        var limitado = Math.Min(baseSeg, _cfg.MaxBackoffSeconds);

        return AplicarJitter(TimeSpan.FromSeconds(limitado), _cfg.JitterPercent);
    }

    /// <summary>
    /// Jitter simétrico: ±N% do valor. Usa Random.Shared, que é thread-safe e
    /// semeado por processo — dois agentes que sobem no mesmo instante não
    /// recebem a mesma sequência.
    /// </summary>
    public static TimeSpan AplicarJitter(TimeSpan valor, int percentual)
    {
        if (percentual <= 0) return valor;

        var fator = 1.0 + ((Random.Shared.NextDouble() * 2 - 1) * percentual / 100.0);
        var ms = valor.TotalMilliseconds * fator;

        return TimeSpan.FromMilliseconds(Math.Max(100, ms));
    }
}
