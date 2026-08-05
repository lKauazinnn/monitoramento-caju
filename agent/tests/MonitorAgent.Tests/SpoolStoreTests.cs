using Microsoft.Extensions.Logging.Abstractions;
using MonitorAgent.Collectors;
using MonitorAgent.Config;
using MonitorAgent.Spool;
using Xunit;

namespace MonitorAgent.Tests;

/// <summary>
/// Testes do spool. É a classe que decide se o dado do incidente sobrevive a uma
/// queda de link (regra 16), então cada comportamento aqui tem consequência
/// operacional, não só de código.
/// </summary>
public sealed class SpoolStoreTests : IAsyncLifetime
{
    private string _dir = "";
    private SpoolStore _spool = null!;

    public async Task InitializeAsync()
    {
        _dir = Path.Combine(Path.GetTempPath(), "monitoragent-teste-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(_dir);

        _spool = new SpoolStore(_dir, new SpoolConfig(), NullLogger<SpoolStore>.Instance);
        await _spool.InitializeAsync(CancellationToken.None);
    }

    public Task DisposeAsync()
    {
        _spool.Dispose();
        try { Directory.Delete(_dir, recursive: true); } catch (IOException) { }
        return Task.CompletedTask;
    }

    private static MetricSample Amostra(DateTime t, double cpu = 10) => new()
    {
        Timestamp = t.ToString("O"),
        CpuPercent = cpu,
        MemTotalMb = 32561,
        MemUsedMb = 18194,
        Disks = { new DiskSample { Drive = "C:", TotalGb = 237.5, FreeGb = 121.0 } },
        Services = { new ServiceSample { Name = "Spooler", IsRunning = true, StateRaw = "Running" } },
    };

    [Fact]
    public async Task Enfileirar_e_retirar_preserva_o_timestamp_do_agente()
    {
        // Regra 12: o timestamp é o do agente e não pode ser reescrito em nenhum
        // ponto do caminho — nem na ida ao SQLite, nem na volta.
        var t = new DateTime(2026, 8, 4, 22, 31, 5, DateTimeKind.Utc);
        await _spool.EnqueueAsync(Amostra(t), CancellationToken.None);

        var lote = await _spool.DequeueAsync(10, CancellationToken.None);

        Assert.Single(lote.Samples);
        Assert.Equal(t.ToString("O"), lote.Samples[0].Timestamp);
        Assert.Equal(10, lote.Samples[0].CpuPercent);
        Assert.Single(lote.Samples[0].Disks);
        Assert.Single(lote.Samples[0].Services);
        Assert.True(lote.Samples[0].Services[0].IsRunning);
    }

    [Fact]
    public async Task Retirar_nao_remove_ate_o_ack()
    {
        // É este comportamento que faz o critério de aceite passar: se o processo
        // morre entre o POST e o ack, a amostra continua no spool.
        await _spool.EnqueueAsync(Amostra(DateTime.UtcNow), CancellationToken.None);

        var primeiro = await _spool.DequeueAsync(10, CancellationToken.None);
        Assert.Single(primeiro.Samples);

        var segundo = await _spool.DequeueAsync(10, CancellationToken.None);
        Assert.Single(segundo.Samples);

        await _spool.AckAsync(primeiro.Ids, CancellationToken.None);

        var terceiro = await _spool.DequeueAsync(10, CancellationToken.None);
        Assert.True(terceiro.IsEmpty);
    }

    [Fact]
    public async Task Drena_do_mais_antigo_para_o_mais_novo()
    {
        var baseT = new DateTime(2026, 8, 4, 12, 0, 0, DateTimeKind.Utc);

        // Enfileira fora de ordem para provar que a ordenação é por sample_time
        // e não por ordem de inserção.
        await _spool.EnqueueAsync(Amostra(baseT.AddMinutes(5), 50), CancellationToken.None);
        await _spool.EnqueueAsync(Amostra(baseT.AddMinutes(1), 10), CancellationToken.None);
        await _spool.EnqueueAsync(Amostra(baseT.AddMinutes(3), 30), CancellationToken.None);

        var lote = await _spool.DequeueAsync(10, CancellationToken.None);

        Assert.Equal(3, lote.Samples.Count);
        Assert.Equal(10, lote.Samples[0].CpuPercent);
        Assert.Equal(30, lote.Samples[1].CpuPercent);
        Assert.Equal(50, lote.Samples[2].CpuPercent);
    }

    [Fact]
    public async Task Dez_minutos_offline_preserva_todas_as_amostras()
    {
        // O critério de aceite da Fase 3, na camada do spool: 10 minutos a cada
        // 60s são 10 amostras, e TODAS têm de sair com o timestamp original.
        var inicio = new DateTime(2026, 8, 4, 20, 0, 0, DateTimeKind.Utc);
        var esperados = new List<string>();

        for (var i = 0; i < 10; i++)
        {
            var t = inicio.AddMinutes(i);
            esperados.Add(t.ToString("O"));
            await _spool.EnqueueAsync(Amostra(t, 20 + i), CancellationToken.None);
        }

        var lote = await _spool.DequeueAsync(200, CancellationToken.None);

        Assert.Equal(10, lote.Samples.Count);
        Assert.Equal(esperados, lote.Samples.Select(s => s.Timestamp).ToList());

        // E os valores não se embaralharam junto com a ordem.
        for (var i = 0; i < 10; i++)
        {
            Assert.Equal(20 + i, lote.Samples[i].CpuPercent);
        }
    }

    [Fact]
    public async Task Linha_com_json_corrompido_nao_trava_a_fila()
    {
        // Sem isso, uma gravação interrompida (queda de energia, disco cheio)
        // criaria uma linha que é sempre a mais antiga, sempre falha, e o spool
        // nunca drena. O dado do incidente morreria por causa de um byte.
        await _spool.EnqueueAsync(Amostra(new DateTime(2026, 8, 4, 10, 0, 0, DateTimeKind.Utc)),
            CancellationToken.None);

        CorromperPrimeiraLinha();

        await _spool.EnqueueAsync(Amostra(new DateTime(2026, 8, 4, 11, 0, 0, DateTimeKind.Utc), 42),
            CancellationToken.None);

        var lote = await _spool.DequeueAsync(10, CancellationToken.None);

        // A linha corrompida entra em Ids (para ser apagada) mas não em Samples.
        Assert.Equal(2, lote.Ids.Count);
        Assert.Single(lote.Samples);
        Assert.Equal(42, lote.Samples[0].CpuPercent);

        await _spool.AckAsync(lote.Ids, CancellationToken.None);
        Assert.True((await _spool.DequeueAsync(10, CancellationToken.None)).IsEmpty);
    }

    [Fact]
    public async Task Lote_somente_com_lixo_e_sinalizado()
    {
        await _spool.EnqueueAsync(Amostra(DateTime.UtcNow), CancellationToken.None);
        CorromperPrimeiraLinha();

        var lote = await _spool.DequeueAsync(10, CancellationToken.None);

        Assert.True(lote.OnlyGarbage);
        Assert.Empty(lote.Samples);
        Assert.Single(lote.Ids);
    }

    [Fact]
    public async Task Trim_por_idade_descarta_o_mais_antigo()
    {
        var cfg = new SpoolConfig { MaxAgeHours = 24, MaxRows = 1_000_000, MaxSizeMb = 4096 };
        using var spool = new SpoolStore(_dir, cfg, NullLogger<SpoolStore>.Instance);
        await spool.InitializeAsync(CancellationToken.None);

        await spool.EnqueueAsync(Amostra(DateTime.UtcNow.AddHours(-48), 1), CancellationToken.None);
        await spool.EnqueueAsync(Amostra(DateTime.UtcNow.AddHours(-30), 2), CancellationToken.None);
        await spool.EnqueueAsync(Amostra(DateTime.UtcNow.AddHours(-1), 3), CancellationToken.None);

        var trim = await spool.TrimAsync(CancellationToken.None);

        Assert.Equal(2, trim.ByAge);

        var lote = await spool.DequeueAsync(10, CancellationToken.None);
        Assert.Single(lote.Samples);
        Assert.Equal(3, lote.Samples[0].CpuPercent);
    }

    [Fact]
    public async Task Trim_por_quantidade_mantem_as_mais_recentes()
    {
        // Regra 17: estourando o teto, o MAIS ANTIGO é descartado. Numa queda
        // longa as amostras recentes valem mais.
        var cfg = new SpoolConfig { MaxRows = 1000, MaxAgeHours = 720, MaxSizeMb = 4096 };
        using var spool = new SpoolStore(_dir, cfg, NullLogger<SpoolStore>.Instance);
        await spool.InitializeAsync(CancellationToken.None);

        var baseT = DateTime.UtcNow.AddHours(-5);
        for (var i = 0; i < 1005; i++)
        {
            await spool.EnqueueAsync(Amostra(baseT.AddSeconds(i), i % 100), CancellationToken.None);
        }

        var trim = await spool.TrimAsync(CancellationToken.None);
        Assert.Equal(5, trim.ByCount);

        var st = await spool.GetStatsAsync(CancellationToken.None);
        Assert.Equal(1000, st.Count);

        // A mais antiga sobrevivente é a de índice 5, não a de índice 0.
        var lote = await spool.DequeueAsync(1, CancellationToken.None);
        Assert.Equal(baseT.AddSeconds(5).ToString("O"), lote.Samples[0].Timestamp);
    }

    [Fact]
    public async Task Estatisticas_refletem_o_conteudo()
    {
        var t1 = new DateTime(2026, 8, 4, 10, 0, 0, DateTimeKind.Utc);
        var t2 = new DateTime(2026, 8, 4, 12, 0, 0, DateTimeKind.Utc);

        await _spool.EnqueueAsync(Amostra(t1), CancellationToken.None);
        await _spool.EnqueueAsync(Amostra(t2), CancellationToken.None);

        var st = await _spool.GetStatsAsync(CancellationToken.None);

        Assert.Equal(2, st.Count);
        Assert.Equal(t1.ToString("O"), st.Oldest);
        Assert.Equal(t2.ToString("O"), st.Newest);
        Assert.True(st.SizeBytes > 0);
    }

    [Fact]
    public async Task Falha_de_envio_conta_tentativas()
    {
        // `attempts` alto com o mesmo erro é a assinatura de token revogado ou
        // URL errada — o operador precisa poder ver isso em --spool-status.
        await _spool.EnqueueAsync(Amostra(DateTime.UtcNow), CancellationToken.None);

        var lote = await _spool.DequeueAsync(10, CancellationToken.None);
        await _spool.MarkFailureAsync(lote.Ids, "HTTP 401 MON01: token revogado", CancellationToken.None);
        await _spool.MarkFailureAsync(lote.Ids, "HTTP 401 MON01: token revogado", CancellationToken.None);

        var st = await _spool.GetStatsAsync(CancellationToken.None);
        Assert.Equal(2, st.MaxAttempts);
        Assert.Equal(1, st.Count);
    }

    [Fact]
    public async Task Sobrevive_a_reabertura_do_arquivo()
    {
        // Reinício do serviço não pode perder o que estava pendente.
        var t = new DateTime(2026, 8, 4, 15, 30, 0, DateTimeKind.Utc);
        await _spool.EnqueueAsync(Amostra(t, 77), CancellationToken.None);
        _spool.Dispose();

        using var reaberto = new SpoolStore(_dir, new SpoolConfig(), NullLogger<SpoolStore>.Instance);
        await reaberto.InitializeAsync(CancellationToken.None);

        var lote = await reaberto.DequeueAsync(10, CancellationToken.None);
        Assert.Single(lote.Samples);
        Assert.Equal(77, lote.Samples[0].CpuPercent);
        Assert.Equal(t.ToString("O"), lote.Samples[0].Timestamp);

        // Reatribui para o DisposeAsync não estourar.
        _spool = new SpoolStore(_dir, new SpoolConfig(), NullLogger<SpoolStore>.Instance);
    }

    /// <summary>Substitui o payload da linha mais antiga por JSON inválido.</summary>
    private void CorromperPrimeiraLinha()
    {
        using var conn = new Microsoft.Data.Sqlite.SqliteConnection(
            $"Data Source={Path.Combine(_dir, "spool.db")}");
        conn.Open();

        using var cmd = conn.CreateCommand();
        cmd.CommandText = "update samples set payload = '{isto nao e json' where id = (select min(id) from samples)";
        cmd.ExecuteNonQuery();
    }
}
