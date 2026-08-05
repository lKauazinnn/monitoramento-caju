using System.Collections.Concurrent;
using System.Globalization;
using System.Text;
using Microsoft.Extensions.Logging;

namespace MonitorAgent.Logging;

/// <summary>
/// Log em arquivo com rotação por tamanho (regra 24).
///
/// Escrito à mão em vez de trazer Serilog/NLog: são ~150 linhas, o agente é
/// distribuído para dezenas de máquinas e cada dependência é uma superfície de
/// atualização a mais num parque que a TI não visita.
///
/// A escrita é serializada por uma fila e uma única thread. Escrever direto do
/// laço de coleta com lock faria um disco lento de PDV atrasar a amostra.
/// </summary>
public sealed class RollingFileLoggerProvider : ILoggerProvider
{
    private readonly string _diretorio;
    private readonly string _prefixo;
    private readonly long _tamanhoMaximoBytes;
    private readonly int _arquivosRetidos;
    private readonly LogLevel _nivelMinimo;

    private readonly BlockingCollection<string> _fila = new(new ConcurrentQueue<string>(), 10_000);
    private readonly Thread _escritor;
    private readonly CancellationTokenSource _cts = new();
    private bool _disposed;

    public RollingFileLoggerProvider(
        string diretorio,
        string prefixo,
        int tamanhoMaximoMb,
        int arquivosRetidos,
        LogLevel nivelMinimo)
    {
        _diretorio = diretorio;
        _prefixo = prefixo;
        _tamanhoMaximoBytes = (long)Math.Clamp(tamanhoMaximoMb, 1, 1024) * 1024 * 1024;
        _arquivosRetidos = Math.Clamp(arquivosRetidos, 1, 100);
        _nivelMinimo = nivelMinimo;

        Directory.CreateDirectory(_diretorio);

        _escritor = new Thread(Loop)
        {
            IsBackground = true,
            Name = "MonitorAgent.LogWriter",
        };
        _escritor.Start();
    }

    public string CaminhoAtual => Path.Combine(_diretorio, $"{_prefixo}.log");

    public ILogger CreateLogger(string categoryName) =>
        new RollingFileLogger(this, categoryName, _nivelMinimo);

    internal void Enfileirar(string linha)
    {
        // TryAdd, não Add: se a fila encher (disco travado), o log é DESCARTADO
        // em vez de bloquear a coleta. Log não pode ser a razão de a máquina
        // parar de ser monitorada.
        _fila.TryAdd(linha);
    }

    private void Loop()
    {
        var buffer = new StringBuilder();

        try
        {
            foreach (var linha in _fila.GetConsumingEnumerable(_cts.Token))
            {
                buffer.Clear();
                buffer.AppendLine(linha);

                // Drena o que já está na fila numa só escrita: numa rajada de
                // log, um write por linha castiga o disco.
                while (buffer.Length < 32 * 1024 && _fila.TryTake(out var extra))
                {
                    buffer.AppendLine(extra);
                }

                Escrever(buffer.ToString());
            }
        }
        catch (OperationCanceledException)
        {
            // Desligando.
        }
        catch (Exception)
        {
            // Nada a fazer: o logger não tem para onde logar o próprio erro.
        }

        // Esvazia o que sobrou no shutdown.
        try
        {
            var resto = new StringBuilder();
            while (_fila.TryTake(out var linha)) resto.AppendLine(linha);
            if (resto.Length > 0) Escrever(resto.ToString());
        }
        catch (Exception) { /* shutdown */ }
    }

    private void Escrever(string texto)
    {
        try
        {
            Rotacionar();
            File.AppendAllText(CaminhoAtual, texto, Encoding.UTF8);
        }
        catch (Exception)
        {
            // Disco cheio, permissão, arquivo travado por antivírus. O agente
            // continua funcionando sem log em arquivo — o Event Log continua.
        }
    }

    private void Rotacionar()
    {
        var atual = new FileInfo(CaminhoAtual);
        if (!atual.Exists || atual.Length < _tamanhoMaximoBytes) return;

        // Descarta o mais antigo e desloca os demais: .log -> .1.log -> .2.log
        var maisAntigo = Path.Combine(_diretorio, $"{_prefixo}.{_arquivosRetidos}.log");
        if (File.Exists(maisAntigo)) File.Delete(maisAntigo);

        for (var i = _arquivosRetidos - 1; i >= 1; i--)
        {
            var de = Path.Combine(_diretorio, $"{_prefixo}.{i}.log");
            var para = Path.Combine(_diretorio, $"{_prefixo}.{i + 1}.log");
            if (File.Exists(de)) File.Move(de, para, overwrite: true);
        }

        File.Move(CaminhoAtual, Path.Combine(_diretorio, $"{_prefixo}.1.log"), overwrite: true);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        _fila.CompleteAdding();
        // Espera limitada: no shutdown do Windows não há tempo infinito.
        _escritor.Join(TimeSpan.FromSeconds(3));
        _cts.Cancel();
        _cts.Dispose();
        _fila.Dispose();
    }
}

internal sealed class RollingFileLogger : ILogger
{
    private readonly RollingFileLoggerProvider _provider;
    private readonly string _categoria;
    private readonly LogLevel _nivelMinimo;

    public RollingFileLogger(RollingFileLoggerProvider provider, string categoria, LogLevel nivelMinimo)
    {
        _provider = provider;
        // Só a última parte do namespace: "MonitorAgent.Collectors.DiskCollector"
        // em cada linha é ruído que empurra a mensagem para fora da tela.
        var ponto = categoria.LastIndexOf('.');
        _categoria = ponto >= 0 && ponto < categoria.Length - 1 ? categoria[(ponto + 1)..] : categoria;
        _nivelMinimo = nivelMinimo;
    }

    public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;

    public bool IsEnabled(LogLevel logLevel) => logLevel >= _nivelMinimo && logLevel != LogLevel.None;

    public void Log<TState>(
        LogLevel logLevel,
        EventId eventId,
        TState state,
        Exception? exception,
        Func<TState, Exception?, string> formatter)
    {
        if (!IsEnabled(logLevel)) return;

        var sb = new StringBuilder(256);

        // Timestamp em UTC e ISO 8601: correlacionar log de agente com dado no
        // banco exige fuso explícito, e em pt-BR o formato local é dd/MM/yyyy,
        // que ordena errado em qualquer ferramenta de texto.
        sb.Append(DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture));
        sb.Append("Z ");
        sb.Append(Abreviar(logLevel));
        sb.Append(" [");
        sb.Append(_categoria);
        sb.Append("] ");
        sb.Append(formatter(state, exception));

        if (exception is not null)
        {
            sb.AppendLine();
            sb.Append("    ");
            sb.Append(exception.GetType().FullName);
            sb.Append(": ");
            sb.Append(exception.Message);

            if (exception.StackTrace is { } trace)
            {
                sb.AppendLine();
                sb.Append(trace);
            }
        }

        _provider.Enfileirar(sb.ToString());
    }

    private static string Abreviar(LogLevel n) => n switch
    {
        LogLevel.Trace => "TRC",
        LogLevel.Debug => "DBG",
        LogLevel.Information => "INF",
        LogLevel.Warning => "AVI",
        LogLevel.Error => "ERR",
        LogLevel.Critical => "CRI",
        _ => "???",
    };
}
