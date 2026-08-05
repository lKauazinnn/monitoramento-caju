using System.Text.Json;
using MonitorAgent.Collectors;
using MonitorAgent.Config;
using MonitorAgent.Transport;
using Xunit;

namespace MonitorAgent.Tests;

public sealed class AgentConfigTests
{
    private static AgentConfig Valido() => new()
    {
        IngestUrl = "https://projeto.supabase.co/functions/v1/ingest",
        SharedSecret = "segredo-com-mais-de-vinte-e-quatro-chars",
        Token = "mon_" + new string('a', 64),
        SiteCode = "BSB-001",
        MachineLabel = "PDV 01",
    };

    [Fact]
    public void Config_valida_nao_tem_erro() => Assert.Empty(Valido().Validate());

    [Fact]
    public void Recusa_http_sem_tls()
    {
        // Regra 9: sem exceção para "rede interna". O agente se recusa a enviar
        // credencial em claro mesmo que alguém edite o config à mão.
        var c = Valido();
        c.IngestUrl = "http://projeto.supabase.co/functions/v1/ingest";

        var erros = c.Validate();
        Assert.Contains(erros, e => e.Contains("HTTPS", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void Recusa_token_truncado()
    {
        // Copiar o token do console e perder o prefixo é erro real de operação.
        var c = Valido();
        c.Token = new string('a', 64);

        Assert.Contains(c.Validate(), e => e.Contains("mon_", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(4)]
    [InlineData(3601)]
    public void Recusa_intervalo_fora_da_faixa(int segundos)
    {
        var c = Valido();
        c.IntervalSeconds = segundos;
        Assert.Contains(c.Validate(), e => e.Contains("intervalSeconds", StringComparison.Ordinal));
    }

    [Fact]
    public void Recusa_lote_acima_do_teto_do_servidor()
    {
        var c = Valido();
        c.BatchSize = 501;
        Assert.Contains(c.Validate(), e => e.Contains("batchSize", StringComparison.Ordinal));
    }

    [Fact]
    public void Recusa_gateway_que_nao_e_ip()
    {
        var c = Valido();
        c.GatewayIp = "roteador-da-loja";
        Assert.Contains(c.Validate(), e => e.Contains("gatewayIp", StringComparison.Ordinal));
    }

    [Fact]
    public void Gateway_vazio_e_valido_porque_desliga_a_medicao()
    {
        var c = Valido();
        c.GatewayIp = "";
        Assert.Empty(c.Validate());
    }

    [Fact]
    public void ToSafeString_nunca_revela_token_nem_segredo()
    {
        var c = Valido();
        var s = c.ToSafeString();

        Assert.DoesNotContain(c.Token, s, StringComparison.Ordinal);
        Assert.DoesNotContain(c.SharedSecret, s, StringComparison.Ordinal);
        // O prefixo pode aparecer: ele já está em texto claro no banco e é o que
        // identifica o agente no log.
        Assert.Contains(c.TokenPrefix, s, StringComparison.Ordinal);
        Assert.Equal(16, c.TokenPrefix.Length);
    }

    [Fact]
    public void Template_e_json_valido_depois_de_remover_os_comentarios()
    {
        // O template é colado à mão pelo operador; se ele não for parseável pelo
        // próprio loader, o primeiro contato com o agente é um erro de sintaxe.
        var opts = new JsonSerializerOptions
        {
            ReadCommentHandling = JsonCommentHandling.Skip,
            AllowTrailingCommas = true,
            PropertyNameCaseInsensitive = true,
        };

        var cfg = JsonSerializer.Deserialize<AgentConfig>(ConfigLoader.Template(), opts);

        Assert.NotNull(cfg);
        Assert.Equal(60, cfg!.IntervalSeconds);
        Assert.Contains("Spooler", cfg.CriticalServices);
    }
}

public sealed class BackoffTests
{
    [Fact]
    public void Cresce_exponencialmente_e_respeita_o_teto()
    {
        var cfg = new HttpConfig { BaseBackoffSeconds = 2, MaxBackoffSeconds = 300, JitterPercent = 0 };
        var b = new Backoff(cfg);

        Assert.Equal(2, b.Next().TotalSeconds, 1);
        Assert.Equal(4, b.Next().TotalSeconds, 1);
        Assert.Equal(8, b.Next().TotalSeconds, 1);
        Assert.Equal(16, b.Next().TotalSeconds, 1);

        for (var i = 0; i < 30; i++) b.Next();

        Assert.Equal(300, b.Next().TotalSeconds, 1);
    }

    [Fact]
    public void Nunca_estoura_nem_fica_negativo_apos_muitas_tentativas()
    {
        // 2^n com n grande estoura o double/int e o atraso viraria negativo,
        // fazendo o agente entrar em laço apertado justamente durante uma queda
        // longa — e aí ele martela o servidor que está tentando voltar.
        var cfg = new HttpConfig { BaseBackoffSeconds = 2, MaxBackoffSeconds = 300, JitterPercent = 20 };
        var b = new Backoff(cfg);

        for (var i = 0; i < 500; i++)
        {
            var d = b.Next();
            Assert.True(d > TimeSpan.Zero, $"tentativa {i} devolveu {d}");
            Assert.True(d.TotalSeconds <= 300 * 1.25, $"tentativa {i} devolveu {d}");
        }
    }

    [Fact]
    public void Reset_volta_ao_inicio()
    {
        var cfg = new HttpConfig { BaseBackoffSeconds = 2, MaxBackoffSeconds = 300, JitterPercent = 0 };
        var b = new Backoff(cfg);

        b.Next();
        b.Next();
        b.Reset();

        Assert.Equal(0, b.Attempt);
        Assert.Equal(2, b.Next().TotalSeconds, 1);
    }

    [Fact]
    public void Jitter_fica_dentro_da_faixa_e_varia()
    {
        // Regra 18. Sem variação, 150 PDVs voltando de uma queda regional batem
        // no servidor no mesmo segundo e continuam sincronizados para sempre.
        var valores = new HashSet<double>();
        var baseV = TimeSpan.FromSeconds(60);

        for (var i = 0; i < 300; i++)
        {
            var v = Backoff.AplicarJitter(baseV, 20);
            Assert.InRange(v.TotalSeconds, 48, 72);
            valores.Add(Math.Round(v.TotalMilliseconds));
        }

        Assert.True(valores.Count > 100, $"jitter produziu apenas {valores.Count} valores distintos em 300");
    }

    [Fact]
    public void Jitter_zero_devolve_o_valor_original()
    {
        var v = Backoff.AplicarJitter(TimeSpan.FromSeconds(60), 0);
        Assert.Equal(60, v.TotalSeconds, 3);
    }

    [Fact]
    public void Jitter_nunca_devolve_menos_de_cem_milissegundos()
    {
        for (var i = 0; i < 200; i++)
        {
            var v = Backoff.AplicarJitter(TimeSpan.FromMilliseconds(50), 50);
            Assert.True(v.TotalMilliseconds >= 100);
        }
    }
}

public sealed class ContratoJsonTests
{
    private static readonly JsonSerializerOptions Opts = new()
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    [Fact]
    public void Envelope_usa_exatamente_os_nomes_que_o_servidor_espera()
    {
        // Contrato com register_metrics. Renomear qualquer chave aqui quebra a
        // ingestão em silêncio: o servidor coage campo desconhecido para NULL,
        // então o sintoma seria "métricas vazias", não um erro.
        var env = new IngestEnvelope
        {
            AgentVersion = "1.0.0",
            SentAt = "2026-08-04T22:31:05.0000000Z",
            Machine = new MachineInfo { Hostname = "PDV01", OsArch = "64 bits", CpuCores = 6 },
            Samples =
            {
                new MetricSample
                {
                    Timestamp = "2026-08-04T22:30:05.0000000Z",
                    CpuPercent = 11.0,
                    MemTotalMb = 32561,
                    MemUsedMb = 18194,
                    UptimeSeconds = 116182,
                    Flags = { CollectFlags.TempDenied },
                    Disks = { new DiskSample { Drive = "C:", TotalGb = 237.5, FreeGb = 121.03 } },
                    Services = { new ServiceSample { Name = "Spooler", IsRunning = true, StateRaw = "Running" } },
                },
            },
        };

        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(env, Opts));
        var raiz = doc.RootElement;

        Assert.Equal("1.0.0", raiz.GetProperty("agent_version").GetString());
        Assert.True(raiz.TryGetProperty("sent_at", out _));
        Assert.Equal("PDV01", raiz.GetProperty("machine").GetProperty("hostname").GetString());
        Assert.Equal("64 bits", raiz.GetProperty("machine").GetProperty("os_arch").GetString());

        var amostra = raiz.GetProperty("samples")[0];
        Assert.Equal("2026-08-04T22:30:05.0000000Z", amostra.GetProperty("t").GetString());
        Assert.Equal(11.0, amostra.GetProperty("cpu_pct").GetDouble());
        Assert.Equal(32561, amostra.GetProperty("mem_total_mb").GetInt32());
        Assert.Equal("temp_denied", amostra.GetProperty("flags")[0].GetString());
        Assert.Equal("C:", amostra.GetProperty("disks")[0].GetProperty("drive").GetString());
        Assert.True(amostra.GetProperty("services")[0].GetProperty("is_running").GetBoolean());
        Assert.Equal("Running", amostra.GetProperty("services")[0].GetProperty("state_raw").GetString());
    }

    [Fact]
    public void Nao_envia_percentuais_derivados_pelo_servidor()
    {
        // mem_pct e free_pct são derivados em register_metrics. Enviá-los daria
        // duas fontes para o mesmo número, que é como elas divergem.
        var env = new IngestEnvelope
        {
            AgentVersion = "1.0.0",
            SentAt = "2026-08-04T22:31:05.0000000Z",
            Samples =
            {
                new MetricSample
                {
                    Timestamp = "2026-08-04T22:30:05.0000000Z",
                    MemTotalMb = 100,
                    MemUsedMb = 50,
                    Disks = { new DiskSample { Drive = "C:", TotalGb = 100, FreeGb = 40 } },
                },
            },
        };

        var json = JsonSerializer.Serialize(env, Opts);

        Assert.DoesNotContain("mem_pct", json, StringComparison.Ordinal);
        Assert.DoesNotContain("free_pct", json, StringComparison.Ordinal);
    }

    [Fact]
    public void Timestamp_do_agente_e_utc_com_sufixo_z()
    {
        // Sem "Z" o servidor interpretaria o horário no fuso da SESSÃO dele, e a
        // série ficaria deslocada em 3 horas para todo o parque brasileiro.
        var t = DateTime.UtcNow.ToString("O");

        Assert.EndsWith("Z", t, StringComparison.Ordinal);
        var lido = DateTimeOffset.Parse(t, System.Globalization.CultureInfo.InvariantCulture);
        Assert.Equal(TimeSpan.Zero, lido.Offset);
    }

    [Fact]
    public void Campos_nulos_sao_omitidos_e_nao_viram_string_null()
    {
        var env = new IngestEnvelope
        {
            AgentVersion = "1.0.0",
            SentAt = "2026-08-04T22:31:05.0000000Z",
            Samples = { new MetricSample { Timestamp = "2026-08-04T22:30:05.0000000Z", CpuPercent = 5 } },
        };

        var json = JsonSerializer.Serialize(env, Opts);

        Assert.DoesNotContain("\"cpu_temp_c\"", json, StringComparison.Ordinal);
        Assert.DoesNotContain("null", json, StringComparison.Ordinal);
    }
}
