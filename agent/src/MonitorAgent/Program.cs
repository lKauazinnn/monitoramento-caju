using System.Reflection;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Hosting.WindowsServices;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.EventLog;
using MonitorAgent;
using MonitorAgent.Collectors;
using MonitorAgent.Config;
using MonitorAgent.Logging;
using MonitorAgent.Spool;
using MonitorAgent.Transport;

// =============================================================================
// MonitorAgent — ponto de entrada
// =============================================================================
// Modos:
//   MonitorAgent.exe                  serviço (ou console, se não for serviço)
//   MonitorAgent.exe --check          valida config e testa /healthz, sai
//   MonitorAgent.exe --collect-once   coleta UMA amostra e imprime o JSON, sai
//   MonitorAgent.exe --spool-status   estado do spool, sai
//   MonitorAgent.exe --template       imprime um config.json modelo, sai
//   MonitorAgent.exe --config <path>  usa outro arquivo de configuração
//
// --collect-once é a ferramenta de diagnóstico principal: mostra exatamente o
// que a máquina consegue coletar, e os `flags` dizem o que falhou e por quê.
// Em console NÃO elevado, temperatura e SMART aparecem como negados — é
// esperado, e o serviço (LocalSystem) não tem esse problema.
// =============================================================================

var argumentos = args.ToList();

string? Valor(string nome)
{
    var i = argumentos.IndexOf(nome);
    return i >= 0 && i + 1 < argumentos.Count ? argumentos[i + 1] : null;
}

var versao = Assembly.GetExecutingAssembly()
                     .GetCustomAttribute<AssemblyInformationalVersionAttribute>()
                     ?.InformationalVersion
                     ?.Split('+')[0]
             ?? "0.0.0";

if (argumentos.Contains("--template"))
{
    Console.WriteLine(ConfigLoader.Template());
    return 0;
}

if (argumentos.Contains("--version"))
{
    Console.WriteLine(versao);
    return 0;
}

if (argumentos.Contains("--help") || argumentos.Contains("-h"))
{
    Console.WriteLine($"""
        MonitorAgent {versao}

          (sem argumento)   roda como serviço do Windows, ou em console
          --check           valida o config.json e testa a conectividade
          --collect-once    coleta uma amostra e imprime o JSON enviado
          --spool-status    mostra o estado do spool local
          --template        imprime um config.json modelo
          --config <path>   usa outro arquivo de configuração
          --version         imprime a versão

        Arquivos:
          {ConfigLoader.CaminhoConfig}
          {ConfigLoader.DiretorioLogs}

        Em console NÃO elevado, temperatura e SMART retornam "acesso negado".
        Isto é privilégio, não ausência de sensor. Use um terminal elevado.
        """);
    return 0;
}

var caminhoConfig = Valor("--config");

// -----------------------------------------------------------------------------
// Configuração
// -----------------------------------------------------------------------------
AgentConfig cfg;
try
{
    cfg = ConfigLoader.Load(caminhoConfig);
}
catch (ConfigException ex)
{
    // Vai para o console E para o Event Log: instalado como serviço, o console
    // não existe e a mensagem se perderia. Sem o Event Log, o sintoma seria
    // "o serviço não inicia" e nada mais.
    Console.Error.WriteLine();
    Console.Error.WriteLine("ERRO DE CONFIGURAÇÃO");
    Console.Error.WriteLine(ex.Message);
    Console.Error.WriteLine();

    TentarRegistrarNoEventLog($"MonitorAgent {versao} não pôde iniciar.\n\n{ex.Message}");
    return 2;
}

// -----------------------------------------------------------------------------
// Logging
// -----------------------------------------------------------------------------
var nivel = Enum.TryParse<LogLevel>(cfg.Logging.Level, ignoreCase: true, out var n)
    ? n
    : LogLevel.Information;

var provedorArquivo = new RollingFileLoggerProvider(
    ConfigLoader.DiretorioLogs, "agent", cfg.Logging.MaxFileSizeMb, cfg.Logging.RetainFiles, nivel);

var builder = Host.CreateApplicationBuilder(args);

builder.Logging.ClearProviders();
builder.Logging.SetMinimumLevel(nivel);
builder.Logging.AddProvider(provedorArquivo);

if (!WindowsServiceHelpers.IsWindowsService())
{
    builder.Logging.AddSimpleConsole(o =>
    {
        o.SingleLine = true;
        o.TimestampFormat = "HH:mm:ss ";
    });
}

// Event Log recebe só Warning e acima: o Application log é compartilhado com
// todo o Windows e um INF por minuto o tornaria inútil para todos.
builder.Logging.AddEventLog(new EventLogSettings
{
    SourceName = "MonitorAgent",
    LogName = "Application",
    Filter = (_, lvl) => lvl >= LogLevel.Warning,
});

// -----------------------------------------------------------------------------
// Serviços
// -----------------------------------------------------------------------------
builder.Services.AddSingleton(cfg);
builder.Services.AddSingleton(cfg.Spool);
builder.Services.AddSingleton<CimQuery>();
builder.Services.AddSingleton<SystemCollector>();
builder.Services.AddSingleton<DiskCollector>();
builder.Services.AddSingleton<ServiceCollector>();
builder.Services.AddSingleton<TemperatureCollector>();
builder.Services.AddSingleton<NetworkCollector>();
builder.Services.AddSingleton<CollectorRunner>();

builder.Services.AddSingleton(sp => new SpoolStore(
    ConfigLoader.DiretorioDados,
    cfg.Spool,
    sp.GetRequiredService<ILogger<SpoolStore>>()));

// HttpClient único, sem IHttpClientFactory: o agente fala com UM endereço fixo
// pelo resto da vida do processo, então a fábrica não agrega nada e traria mais
// uma dependência.
//
// PooledConnectionLifetime é o que a fábrica resolveria e aqui é resolvido
// explicitamente: sem ele, um HttpClient de vida longa NUNCA reconsulta o DNS.
// Num serviço que roda por meses, uma troca de IP no Supabase deixaria o agente
// mudo sem nenhum erro compreensível.
builder.Services.AddSingleton(sp =>
{
    var handler = new SocketsHttpHandler
    {
        PooledConnectionLifetime = TimeSpan.FromMinutes(5),
        ConnectTimeout = TimeSpan.FromSeconds(10),
        AutomaticDecompression = System.Net.DecompressionMethods.All,
    };

    var http = new HttpClient(handler, disposeHandler: true);
    http.DefaultRequestHeaders.UserAgent.ParseAdd($"MonitorAgent/{versao}");
    // Sem cache em nenhum ponto do caminho: um proxy de loja cacheando POST não
    // deveria acontecer, mas já aconteceu.
    http.DefaultRequestHeaders.TryAddWithoutValidation("Cache-Control", "no-store");

    return new IngestClient(http, cfg, versao, sp.GetRequiredService<ILogger<IngestClient>>());
});

builder.Services.AddSingleton(sp => new Worker(
    cfg,
    sp.GetRequiredService<SpoolStore>(),
    sp.GetRequiredService<IngestClient>(),
    sp.GetRequiredService<CollectorRunner>(),
    versao,
    sp.GetRequiredService<ILogger<Worker>>()));

// -----------------------------------------------------------------------------
// Modos de diagnóstico
// -----------------------------------------------------------------------------
if (argumentos.Contains("--check") ||
    argumentos.Contains("--collect-once") ||
    argumentos.Contains("--spool-status"))
{
    using var host = builder.Build();
    var sp = host.Services;

    if (argumentos.Contains("--check"))
        return await Diagnostico.CheckAsync(sp, cfg, versao, provedorArquivo);

    if (argumentos.Contains("--collect-once"))
        return await Diagnostico.CollectOnceAsync(sp, versao);

    return await Diagnostico.SpoolStatusAsync(sp);
}

// -----------------------------------------------------------------------------
// Serviço
// -----------------------------------------------------------------------------
builder.Services.AddWindowsService(o => o.ServiceName = "MonitorAgent");
builder.Services.AddHostedService(sp => sp.GetRequiredService<Worker>());

try
{
    var host = builder.Build();
    await host.RunAsync();
    return 0;
}
catch (Exception ex)
{
    // Regra 19 na fronteira do processo: se nem o host subiu, o Event Log é o
    // único lugar onde a TI vai encontrar o motivo.
    TentarRegistrarNoEventLog($"MonitorAgent {versao} terminou com exceção não tratada:\n\n{ex}");
    Console.Error.WriteLine(ex);
    return 1;
}
finally
{
    provedorArquivo.Dispose();
}

static void TentarRegistrarNoEventLog(string mensagem)
{
    try
    {
        // A origem só pode ser criada com elevação. Se não existir, o Windows
        // registra sob "Application" mesmo assim na maioria dos casos; falhando,
        // não há nada a fazer e engolir é correto — não se derruba o processo por
        // causa do log.
        using var log = new System.Diagnostics.EventLog("Application");
        log.Source = System.Diagnostics.EventLog.SourceExists("MonitorAgent")
            ? "MonitorAgent"
            : "Application";
        log.WriteEntry(mensagem, System.Diagnostics.EventLogEntryType.Error);
    }
    catch (Exception)
    {
        // Sem elevação e sem origem registrada.
    }
}
