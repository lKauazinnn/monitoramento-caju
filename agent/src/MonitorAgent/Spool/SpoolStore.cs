using System.Text.Json;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging;
using MonitorAgent.Collectors;
using MonitorAgent.Config;

namespace MonitorAgent.Spool;

/// <summary>
/// Spool local em SQLite.
///
/// REGRA 16 — a razão de existir desta classe: o agente grava SEMPRE aqui
/// primeiro e só depois tenta enviar. Se o link cai, o dado do incidente é
/// justamente o que não pode ser perdido, e é exatamente esse o dado que se
/// perderia num agente que envia direto e descarta no erro.
///
/// REGRA 17 — o spool tem teto de linhas, de idade e de tamanho. Estourando,
/// o MAIS ANTIGO é descartado: numa queda longa, as amostras recentes valem
/// mais que as de três dias atrás.
///
/// Ordem de envio: MAIS ANTIGO PRIMEIRO. Reordenar não muda o resultado final
/// (o servidor grava por timestamp, não por ordem de chegada), mas drenar em
/// ordem cronológica mantém o gráfico preenchendo da esquerda para a direita
/// durante a recuperação, o que é o que o operador espera ver.
/// </summary>
public sealed class SpoolStore : IDisposable
{
    private readonly string _caminhoBanco;
    private readonly SpoolConfig _cfg;
    private readonly ILogger<SpoolStore> _log;
    private readonly SemaphoreSlim _lock = new(1, 1);
    private SqliteConnection? _conn;
    private bool _disposed;

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    public SpoolStore(string diretorioDados, SpoolConfig cfg, ILogger<SpoolStore> log)
    {
        _caminhoBanco = Path.Combine(diretorioDados, "spool.db");
        _cfg = cfg;
        _log = log;
    }

    public string DatabasePath => _caminhoBanco;

    public async Task InitializeAsync(CancellationToken ct)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_caminhoBanco)!);

        var cs = new SqliteConnectionStringBuilder
        {
            DataSource = _caminhoBanco,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Cache = SqliteCacheMode.Private,
            Pooling = false,
        }.ToString();

        _conn = new SqliteConnection(cs);
        await _conn.OpenAsync(ct).ConfigureAwait(false);

        // WAL: uma queda de energia no meio de um commit não corrompe o arquivo.
        // synchronous=NORMAL em WAL já sobrevive a crash de processo; FULL só
        // protege contra queda de energia e custa um fsync por commit, o que num
        // PDV com disco lento vira segundos por ciclo.
        await ExecutarAsync("PRAGMA journal_mode=WAL", ct).ConfigureAwait(false);
        await ExecutarAsync("PRAGMA synchronous=NORMAL", ct).ConfigureAwait(false);
        await ExecutarAsync("PRAGMA busy_timeout=5000", ct).ConfigureAwait(false);

        await ExecutarAsync("""
            create table if not exists samples (
                id          integer primary key autoincrement,
                sample_time text    not null,
                created_at  text    not null,
                payload     text    not null,
                attempts    integer not null default 0,
                last_error  text
            )
            """, ct).ConfigureAwait(false);

        // Ordem de drenagem: o índice cobre exatamente o ORDER BY do Dequeue.
        await ExecutarAsync(
            "create index if not exists idx_samples_time on samples (sample_time)", ct).ConfigureAwait(false);

        _log.LogInformation("spool em {Caminho}", _caminhoBanco);

        // Verificação de integridade na partida: um arquivo corrompido por queda
        // de energia tem que ser detectado AGORA, não no primeiro envio.
        await VerificarIntegridadeAsync(ct).ConfigureAwait(false);
    }

    /// <summary>
    /// Enfileira a amostra. É a primeira coisa que acontece depois da coleta.
    /// </summary>
    public async Task EnqueueAsync(MetricSample amostra, CancellationToken ct)
    {
        var json = JsonSerializer.Serialize(amostra, JsonOpts);

        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await using var cmd = Conn.CreateCommand();
            cmd.CommandText = """
                insert into samples (sample_time, created_at, payload)
                values ($t, $c, $p)
                """;
            cmd.Parameters.AddWithValue("$t", amostra.Timestamp);
            cmd.Parameters.AddWithValue("$c", DateTime.UtcNow.ToString("O"));
            cmd.Parameters.AddWithValue("$p", json);
            await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
        }
        finally
        {
            _lock.Release();
        }
    }

    /// <summary>
    /// Pega o lote mais ANTIGO ainda não enviado, sem removê-lo. A remoção só
    /// acontece em <see cref="AckAsync"/>, depois de o servidor confirmar.
    ///
    /// Este é o detalhe que faz o critério de aceite passar: se o processo morrer
    /// entre o envio e o ack, a amostra continua no spool e é reenviada. O
    /// servidor é idempotente (regra 13), então reenviar não duplica.
    /// </summary>
    public async Task<SpoolBatch> DequeueAsync(int tamanhoMaximo, CancellationToken ct)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var ids = new List<long>(tamanhoMaximo);
            var amostras = new List<MetricSample>(tamanhoMaximo);

            await using var cmd = Conn.CreateCommand();
            cmd.CommandText = """
                select id, payload from samples
                order by sample_time asc, id asc
                limit $n
                """;
            cmd.Parameters.AddWithValue("$n", tamanhoMaximo);

            await using var r = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);

            while (await r.ReadAsync(ct).ConfigureAwait(false))
            {
                var id = r.GetInt64(0);
                var json = r.GetString(1);

                try
                {
                    var amostra = JsonSerializer.Deserialize<MetricSample>(json, JsonOpts);
                    if (amostra is not null)
                    {
                        ids.Add(id);
                        amostras.Add(amostra);
                        continue;
                    }
                }
                catch (JsonException ex)
                {
                    _log.LogWarning(ex,
                        "linha {Id} do spool tem JSON inválido e será descartada. " +
                        "Provável gravação interrompida.", id);
                }

                // Linha ilegível entra no lote de ids para ser APAGADA no ack, mas
                // não vai para as amostras. Sem isso ela bloquearia a fila para
                // sempre: seria sempre a mais antiga, sempre falharia, e o spool
                // nunca drenaria.
                ids.Add(id);
            }

            return new SpoolBatch(ids, amostras);
        }
        finally
        {
            _lock.Release();
        }
    }

    /// <summary>Remove definitivamente as linhas confirmadas pelo servidor.</summary>
    public async Task AckAsync(IReadOnlyList<long> ids, CancellationToken ct)
    {
        if (ids.Count == 0) return;

        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await using var tx = (SqliteTransaction)await Conn.BeginTransactionAsync(ct).ConfigureAwait(false);

            await using var cmd = Conn.CreateCommand();
            cmd.Transaction = tx;
            cmd.CommandText = "delete from samples where id = $id";
            var p = cmd.CreateParameter();
            p.ParameterName = "$id";
            cmd.Parameters.Add(p);

            foreach (var id in ids)
            {
                p.Value = id;
                await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
            }

            await tx.CommitAsync(ct).ConfigureAwait(false);
        }
        finally
        {
            _lock.Release();
        }
    }

    /// <summary>
    /// Registra a falha de envio nas linhas do lote. Serve para diagnóstico:
    /// `attempts` alto com o mesmo `last_error` é a assinatura de "token
    /// revogado" ou "URL errada", que o operador precisa ver.
    /// </summary>
    public async Task MarkFailureAsync(IReadOnlyList<long> ids, string erro, CancellationToken ct)
    {
        if (ids.Count == 0) return;

        var truncado = erro.Length > 500 ? erro[..500] : erro;

        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await using var tx = (SqliteTransaction)await Conn.BeginTransactionAsync(ct).ConfigureAwait(false);

            await using var cmd = Conn.CreateCommand();
            cmd.Transaction = tx;
            cmd.CommandText = """
                update samples set attempts = attempts + 1, last_error = $e where id = $id
                """;
            cmd.Parameters.AddWithValue("$e", truncado);
            var p = cmd.CreateParameter();
            p.ParameterName = "$id";
            cmd.Parameters.Add(p);

            foreach (var id in ids)
            {
                p.Value = id;
                await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
            }

            await tx.CommitAsync(ct).ConfigureAwait(false);
        }
        finally
        {
            _lock.Release();
        }
    }

    /// <summary>
    /// Aplica a política de retenção (regra 17). Descarta pelo MAIS ANTIGO.
    /// </summary>
    public async Task<SpoolTrim> TrimAsync(CancellationToken ct)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var porIdade = 0;
            var porQuantidade = 0;
            var porTamanho = 0;

            // 1. Idade. Amostra mais velha que backfill_max_age_seconds do
            //    servidor já seria rejeitada; guardá-la é gastar disco por nada.
            var limite = DateTime.UtcNow.AddHours(-_cfg.MaxAgeHours).ToString("O");
            await using (var cmd = Conn.CreateCommand())
            {
                cmd.CommandText = "delete from samples where sample_time < $limite";
                cmd.Parameters.AddWithValue("$limite", limite);
                porIdade = await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
            }

            // 2. Quantidade.
            await using (var cmd = Conn.CreateCommand())
            {
                cmd.CommandText = """
                    delete from samples where id in (
                        select id from samples order by sample_time asc, id asc
                        limit max(0, (select count(*) from samples) - $teto)
                    )
                    """;
                cmd.Parameters.AddWithValue("$teto", _cfg.MaxRows);
                porQuantidade = await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
            }

            // 3. Tamanho em disco. Verificado depois dos outros dois, porque
            //    normalmente eles já resolvem.
            var bytes = TamanhoEmBytes();
            var tetoBytes = (long)_cfg.MaxSizeMb * 1024 * 1024;

            if (bytes > tetoBytes)
            {
                // Descarta 10% das linhas mais antigas por rodada em vez de
                // calcular quantas cabem: o tamanho da linha varia (número de
                // discos e serviços), e uma estimativa erraria nas duas direções.
                await using var cmd = Conn.CreateCommand();
                cmd.CommandText = """
                    delete from samples where id in (
                        select id from samples order by sample_time asc, id asc
                        limit max(1, (select count(*) from samples) / 10)
                    )
                    """;
                porTamanho = await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
            }

            var total = porIdade + porQuantidade + porTamanho;

            if (total > 0)
            {
                _log.LogWarning(
                    "spool aparado: {Total} amostras descartadas (idade={Idade}, quantidade={Qtd}, tamanho={Tam}). " +
                    "Descarte do mais antigo primeiro.",
                    total, porIdade, porQuantidade, porTamanho);

                // VACUUM só quando houve descarte: em WAL o arquivo não encolhe
                // sozinho, e num PDV com disco pequeno isso importa.
                await ExecutarAsync("PRAGMA wal_checkpoint(TRUNCATE)", ct).ConfigureAwait(false);
            }

            return new SpoolTrim(porIdade, porQuantidade, porTamanho);
        }
        finally
        {
            _lock.Release();
        }
    }

    public async Task<SpoolStats> GetStatsAsync(CancellationToken ct)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await using var cmd = Conn.CreateCommand();
            cmd.CommandText = """
                select count(*), min(sample_time), max(sample_time), max(attempts)
                from samples
                """;

            await using var r = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);

            if (!await r.ReadAsync(ct).ConfigureAwait(false))
                return new SpoolStats(0, null, null, 0, TamanhoEmBytes());

            return new SpoolStats(
                r.IsDBNull(0) ? 0 : r.GetInt32(0),
                r.IsDBNull(1) ? null : r.GetString(1),
                r.IsDBNull(2) ? null : r.GetString(2),
                r.IsDBNull(3) ? 0 : r.GetInt32(3),
                TamanhoEmBytes());
        }
        finally
        {
            _lock.Release();
        }
    }

    private long TamanhoEmBytes()
    {
        try
        {
            var total = 0L;
            foreach (var sufixo in new[] { "", "-wal", "-shm" })
            {
                var f = new FileInfo(_caminhoBanco + sufixo);
                if (f.Exists) total += f.Length;
            }
            return total;
        }
        catch (IOException)
        {
            return 0;
        }
    }

    private async Task VerificarIntegridadeAsync(CancellationToken ct)
    {
        try
        {
            await using var cmd = Conn.CreateCommand();
            cmd.CommandText = "PRAGMA quick_check";
            var resultado = (await cmd.ExecuteScalarAsync(ct).ConfigureAwait(false)) as string;

            if (!string.Equals(resultado, "ok", StringComparison.OrdinalIgnoreCase))
            {
                _log.LogError(
                    "spool com integridade comprometida: {Resultado}. " +
                    "O arquivo será movido e um novo será criado — as amostras pendentes serão perdidas.",
                    resultado);
                await RecriarBancoAsync(ct).ConfigureAwait(false);
            }
        }
        catch (SqliteException ex)
        {
            _log.LogError(ex, "falha ao verificar integridade do spool; recriando");
            await RecriarBancoAsync(ct).ConfigureAwait(false);
        }
    }

    /// <summary>
    /// Move o arquivo corrompido e cria um novo.
    ///
    /// Perder o spool é ruim, mas um spool corrompido que faz o agente estourar
    /// a cada partida é pior: aí a máquina fica muda para sempre e ninguém sabe.
    /// O arquivo antigo é preservado com sufixo para perícia.
    /// </summary>
    private async Task RecriarBancoAsync(CancellationToken ct)
    {
        var conn = _conn;
        if (conn is not null)
        {
            await conn.CloseAsync().ConfigureAwait(false);
            await conn.DisposeAsync().ConfigureAwait(false);
            _conn = null;
        }

        SqliteConnection.ClearAllPools();

        var carimbo = DateTime.UtcNow.ToString("yyyyMMdd-HHmmss");
        foreach (var sufixo in new[] { "", "-wal", "-shm" })
        {
            var origem = _caminhoBanco + sufixo;
            if (!File.Exists(origem)) continue;

            try
            {
                File.Move(origem, $"{origem}.corrompido-{carimbo}", overwrite: true);
            }
            catch (IOException ex)
            {
                _log.LogError(ex, "não foi possível mover {Arquivo}; tentando apagar", origem);
                try { File.Delete(origem); } catch (IOException) { /* último recurso falhou */ }
            }
        }

        await InitializeAsync(ct).ConfigureAwait(false);
    }

    private SqliteConnection Conn =>
        _conn ?? throw new InvalidOperationException("SpoolStore.InitializeAsync não foi chamado");

    private async Task ExecutarAsync(string sql, CancellationToken ct)
    {
        await using var cmd = Conn.CreateCommand();
        cmd.CommandText = sql;
        await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        try
        {
            _conn?.Close();
            _conn?.Dispose();
        }
        catch (SqliteException)
        {
            // Fechando no shutdown: nada a fazer com o erro.
        }

        _lock.Dispose();
    }
}

public sealed record SpoolBatch(List<long> Ids, List<MetricSample> Samples)
{
    public bool IsEmpty => Ids.Count == 0;

    /// <summary>Lote só com linhas ilegíveis: não há o que enviar, só o que apagar.</summary>
    public bool OnlyGarbage => Ids.Count > 0 && Samples.Count == 0;
}

public sealed record SpoolTrim(int ByAge, int ByCount, int BySize)
{
    public int Total => ByAge + ByCount + BySize;
}

public sealed record SpoolStats(int Count, string? Oldest, string? Newest, int MaxAttempts, long SizeBytes);
