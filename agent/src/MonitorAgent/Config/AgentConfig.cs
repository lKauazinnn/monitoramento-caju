using System.Text.Json.Serialization;

namespace MonitorAgent.Config;

/// <summary>
/// Configuração do agente, lida de %ProgramData%\MonitorAgent\config.json.
/// Regra 22: nada de const no código — tudo que um operador pode querer mudar
/// numa loja específica passa por aqui.
/// </summary>
public sealed class AgentConfig
{
    /// <summary>URL da Edge Function de ingestão. Obrigatoriamente HTTPS (regra 9).</summary>
    public string IngestUrl { get; set; } = "";

    /// <summary>
    /// Segredo compartilhado da Edge Function (regra 6).
    ///
    /// TRADE-OFF ACEITO: este segredo é o MESMO em todas as máquinas, então um
    /// PDV comprometido o expõe. Ele é um portão grosso — impede varredura
    /// anônima da função. A credencial real é o <see cref="Token"/>, que é por
    /// máquina e revogável individualmente. Se este segredo vazar, rotacione-o
    /// na função e nos agentes; os tokens continuam válidos.
    /// </summary>
    public string SharedSecret { get; set; } = "";

    /// <summary>Token da máquina. Só existe aqui e como hash no banco (regra 2).</summary>
    public string Token { get; set; } = "";

    /// <summary>
    /// GUID da máquina, emitido no provisionamento (regra 11). O servidor
    /// resolve a identidade pelo token; este campo existe para diagnóstico e
    /// para o log — nunca para decidir nada.
    /// </summary>
    public string MachineId { get; set; } = "";

    public string SiteCode { get; set; } = "";
    public string MachineLabel { get; set; } = "";
    public string Role { get; set; } = "pdv";

    public int IntervalSeconds { get; set; } = 60;

    /// <summary>Amostras por requisição. Deve respeitar app_settings.ingest_max_batch_size.</summary>
    public int BatchSize { get; set; } = 200;

    /// <summary>
    /// IP do gateway para medir latência da LAN. Vazio desliga a medição em vez
    /// de adivinhar — adivinhar gateway errado produz série de latência falsa.
    /// </summary>
    public string GatewayIp { get; set; } = "";

    /// <summary>
    /// Serviços críticos por NOME CURTO (ServiceName, ex. "Spooler"), nunca
    /// DisplayName — este é traduzido em Windows pt-BR.
    /// </summary>
    public List<string> CriticalServices { get; set; } = new();

    public SpoolConfig Spool { get; set; } = new();
    public HttpConfig Http { get; set; } = new();
    public LoggingConfig Logging { get; set; } = new();

    /// <summary>Coletores desligáveis por nome, para contornar máquina problemática.</summary>
    public List<string> DisabledCollectors { get; set; } = new();

    [JsonIgnore]
    public TimeSpan Interval => FromSecondsSafe(IntervalSeconds, 60, 5, 3600);

    private static TimeSpan FromSecondsSafe(int value, int fallback, int min, int max) =>
        TimeSpan.FromSeconds(value < min || value > max ? fallback : value);

    /// <summary>
    /// Valida e devolve a lista de problemas. Não corrige silenciosamente o que
    /// não pode ser inferido: URL ou token errados têm que falhar visíveis.
    /// </summary>
    public List<string> Validate()
    {
        var erros = new List<string>();

        if (string.IsNullOrWhiteSpace(IngestUrl))
        {
            erros.Add("ingestUrl vazio");
        }
        else if (!Uri.TryCreate(IngestUrl, UriKind.Absolute, out var uri))
        {
            erros.Add($"ingestUrl não é URL absoluta: {IngestUrl}");
        }
        else if (uri.Scheme != Uri.UriSchemeHttps)
        {
            // Regra 9: sem exceção para "rede interna".
            erros.Add($"ingestUrl deve ser HTTPS (recebido {uri.Scheme})");
        }

        if (string.IsNullOrWhiteSpace(Token))
            erros.Add("token vazio");
        else if (!Token.StartsWith("mon_", StringComparison.Ordinal))
            erros.Add("token não começa com 'mon_' — provavelmente foi truncado na cópia");

        if (string.IsNullOrWhiteSpace(SharedSecret))
            erros.Add("sharedSecret vazio (a função de ingestão vai devolver 401)");

        if (IntervalSeconds is < 5 or > 3600)
            erros.Add($"intervalSeconds fora da faixa 5..3600: {IntervalSeconds}");

        if (BatchSize is < 1 or > 500)
            erros.Add($"batchSize fora da faixa 1..500: {BatchSize}");

        if (!string.IsNullOrWhiteSpace(GatewayIp) &&
            !System.Net.IPAddress.TryParse(GatewayIp, out _))
            erros.Add($"gatewayIp não é um IP válido: {GatewayIp}");

        erros.AddRange(Spool.Validate());
        erros.AddRange(Http.Validate());

        return erros;
    }

    /// <summary>Cópia sem segredo, para logar a configuração efetiva na partida.</summary>
    public string ToSafeString() =>
        $"ingestUrl={IngestUrl} site={SiteCode} label={MachineLabel} role={Role} " +
        $"machineId={MachineId} interval={IntervalSeconds}s batch={BatchSize} " +
        $"gateway={(string.IsNullOrWhiteSpace(GatewayIp) ? "(desligado)" : GatewayIp)} " +
        $"services=[{string.Join(",", CriticalServices)}] " +
        $"spool(rows={Spool.MaxRows},age={Spool.MaxAgeHours}h,size={Spool.MaxSizeMb}MB) " +
        $"http(timeout={Http.TimeoutSeconds}s,retries={Http.MaxRetries},jitter={Http.JitterPercent}%) " +
        $"token={TokenPrefix} secret={(string.IsNullOrEmpty(SharedSecret) ? "AUSENTE" : "definido")}";

    /// <summary>Prefixo de 16 caracteres — o mesmo que o banco guarda em texto claro.</summary>
    [JsonIgnore]
    public string TokenPrefix =>
        string.IsNullOrEmpty(Token) ? "(vazio)" : Token[..Math.Min(16, Token.Length)];
}

public sealed class SpoolConfig
{
    /// <summary>Teto de linhas. Regra 17: estourando, o MAIS ANTIGO é descartado.</summary>
    public int MaxRows { get; set; } = 200_000;

    /// <summary>Idade máxima. Amostra mais velha que isso já foi rejeitada pelo servidor.</summary>
    public int MaxAgeHours { get; set; } = 72;

    public int MaxSizeMb { get; set; } = 256;

    public List<string> Validate()
    {
        var e = new List<string>();
        if (MaxRows is < 1000 or > 5_000_000) e.Add($"spool.maxRows fora de 1000..5000000: {MaxRows}");
        if (MaxAgeHours is < 1 or > 720) e.Add($"spool.maxAgeHours fora de 1..720: {MaxAgeHours}");
        if (MaxSizeMb is < 8 or > 8192) e.Add($"spool.maxSizeMb fora de 8..8192: {MaxSizeMb}");
        return e;
    }
}

public sealed class HttpConfig
{
    /// <summary>Regra 18: timeout explícito. Sem isso o envio pode pendurar para sempre.</summary>
    public int TimeoutSeconds { get; set; } = 30;

    public int MaxRetries { get; set; } = 5;
    public int BaseBackoffSeconds { get; set; } = 2;
    public int MaxBackoffSeconds { get; set; } = 300;

    /// <summary>
    /// Regra 18: jitter no intervalo. Sem ele, 150 PDVs que ligam às 8h batem no
    /// servidor no mesmo segundo, para sempre — e o pico é indistinguível de
    /// ataque.
    /// </summary>
    public int JitterPercent { get; set; } = 20;

    public List<string> Validate()
    {
        var e = new List<string>();
        if (TimeoutSeconds is < 5 or > 300) e.Add($"http.timeoutSeconds fora de 5..300: {TimeoutSeconds}");
        if (MaxRetries is < 0 or > 20) e.Add($"http.maxRetries fora de 0..20: {MaxRetries}");
        if (BaseBackoffSeconds is < 1 or > 60) e.Add($"http.baseBackoffSeconds fora de 1..60: {BaseBackoffSeconds}");
        if (MaxBackoffSeconds < BaseBackoffSeconds) e.Add("http.maxBackoffSeconds menor que baseBackoffSeconds");
        if (JitterPercent is < 0 or > 50) e.Add($"http.jitterPercent fora de 0..50: {JitterPercent}");
        return e;
    }
}

public sealed class LoggingConfig
{
    public string Level { get; set; } = "Information";
    public int MaxFileSizeMb { get; set; } = 10;
    public int RetainFiles { get; set; } = 7;
}
