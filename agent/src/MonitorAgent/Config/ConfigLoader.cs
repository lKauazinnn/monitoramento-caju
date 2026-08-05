using System.Text.Json;

namespace MonitorAgent.Config;

/// <summary>
/// Carga do config.json de %ProgramData%\MonitorAgent\.
///
/// %ProgramData% e não %AppData%: o serviço roda como LocalSystem e o perfil de
/// usuário do LocalSystem não é onde a TI espera achar o arquivo. Também não é
/// ao lado do binário, porque isso quebra a auto-atualização da Fase 6 (o
/// diretório do binário é substituído).
/// </summary>
public static class ConfigLoader
{
    public const string NomeArquivo = "config.json";

    private static readonly JsonSerializerOptions Opcoes = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    public static string DiretorioDados =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "MonitorAgent");

    public static string DiretorioLogs => Path.Combine(DiretorioDados, "logs");

    public static string CaminhoConfig => Path.Combine(DiretorioDados, NomeArquivo);

    /// <summary>
    /// Lê e valida. Lança <see cref="ConfigException"/> com mensagem dirigida ao
    /// operador — não a um desenvolvedor.
    /// </summary>
    public static AgentConfig Load(string? caminhoAlternativo = null)
    {
        var caminho = caminhoAlternativo ?? CaminhoConfig;

        if (!File.Exists(caminho))
        {
            throw new ConfigException(
                $"config.json não encontrado em {caminho}.\n\n" +
                "Gere o arquivo provisionando a máquina no servidor:\n" +
                "  .\\scripts\\provision-machine.ps1 -SiteCode <LOJA> -Label '<MAQUINA>' \\\n" +
                "      -IngestUrl https://<projeto>.supabase.co/functions/v1/ingest \\\n" +
                "      -SharedSecret <segredo> -OutConfig C:\\temp\\config.json\n\n" +
                $"Depois copie o arquivo para {caminho}.");
        }

        AgentConfig? cfg;
        try
        {
            var json = File.ReadAllText(caminho);
            cfg = JsonSerializer.Deserialize<AgentConfig>(json, Opcoes);
        }
        catch (JsonException ex)
        {
            // Linha e coluna são o que resolve o problema na prática: quase
            // sempre é vírgula sobrando depois de editar à mão.
            throw new ConfigException(
                $"config.json em {caminho} não é JSON válido.\n" +
                $"Linha {ex.LineNumber}, posição {ex.BytePositionInLine}: {ex.Message}", ex);
        }
        catch (IOException ex)
        {
            throw new ConfigException($"não foi possível ler {caminho}: {ex.Message}", ex);
        }
        catch (UnauthorizedAccessException ex)
        {
            throw new ConfigException(
                $"sem permissão para ler {caminho}. O serviço roda como LocalSystem; " +
                $"verifique as permissões do diretório.", ex);
        }

        if (cfg is null)
        {
            throw new ConfigException($"config.json em {caminho} está vazio ou contém apenas 'null'.");
        }

        var erros = cfg.Validate();
        if (erros.Count > 0)
        {
            throw new ConfigException(
                $"config.json em {caminho} tem {erros.Count} problema(s):\n  - " +
                string.Join("\n  - ", erros));
        }

        return cfg;
    }

    /// <summary>Gera um modelo comentado, para o operador preencher à mão.</summary>
    public static string Template() => """
        {
          "// AVISO": "Este arquivo contém o TOKEN em texto claro. Trate como credencial.",

          "ingestUrl": "https://SEUPROJETO.supabase.co/functions/v1/ingest",
          "sharedSecret": "<INGEST_SHARED_SECRET configurado na Edge Function>",
          "token": "mon_<64 caracteres hex, obtidos no provisionamento>",
          "machineId": "<GUID devolvido pelo provisionamento>",

          "siteCode": "BSB-001",
          "machineLabel": "PDV 01",
          "role": "pdv",

          "intervalSeconds": 60,
          "batchSize": 200,

          "// gatewayIp": "Vazio DESLIGA a medição de latência da LAN. Não é adivinhado.",
          "gatewayIp": "10.10.1.1",

          "// criticalServices": "NOME CURTO do serviço (ServiceName), nunca o nome exibido.",
          "criticalServices": ["Spooler"],

          "spool": {
            "maxRows": 200000,
            "maxAgeHours": 72,
            "maxSizeMb": 256
          },

          "http": {
            "timeoutSeconds": 30,
            "maxRetries": 5,
            "baseBackoffSeconds": 2,
            "maxBackoffSeconds": 300,
            "jitterPercent": 20
          },

          "logging": {
            "level": "Information",
            "maxFileSizeMb": 10,
            "retainFiles": 7
          },

          "// disabledCollectors": "Para contornar máquina problemática: system, disk, services, temperature, network",
          "disabledCollectors": []
        }
        """;
}

public sealed class ConfigException : Exception
{
    public ConfigException(string mensagem) : base(mensagem) { }
    public ConfigException(string mensagem, Exception inner) : base(mensagem, inner) { }
}
