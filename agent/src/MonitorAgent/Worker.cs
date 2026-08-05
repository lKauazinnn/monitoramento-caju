using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using MonitorAgent.Collectors;
using MonitorAgent.Config;
using MonitorAgent.Spool;
using MonitorAgent.Transport;

namespace MonitorAgent;

/// <summary>
/// Laço principal: coleta -> grava no spool -> tenta drenar.
///
/// A ordem importa e é a regra 16: SEMPRE grava antes de enviar. Um agente que
/// envia primeiro e grava só no erro perde a amostra se o processo morrer no meio
/// do POST — e o momento em que o processo morre é justamente o momento
/// interessante.
///
/// Regra 19: nenhuma exceção de coletor derruba o ciclo, e nenhuma exceção de
/// ciclo derruba o laço. O único jeito de este serviço parar é o
/// CancellationToken do host.
/// </summary>
public sealed class Worker : BackgroundService
{
    private readonly AgentConfig _cfg;
    private readonly SpoolStore _spool;
    private readonly IngestClient _cliente;
    private readonly CollectorRunner _coletores;
    private readonly ILogger<Worker> _log;
    private readonly string _versao;

    private readonly Backoff _backoff;
    private MachineInfo? _infoMaquina;
    private DateTime _proximaColetaDeInfo = DateTime.MinValue;
    private DateTime _proximoTrim = DateTime.MinValue;
    private DateTime _silencioAte = DateTime.MinValue;
    private long _ciclos;
    private bool _avisouNaoAutorizado;

    // Metadados da máquina são reenviados de hora em hora: modelo de CPU não muda
    // a cada minuto, mas hostname e IP mudam, e o servidor precisa saber.
    private static readonly TimeSpan IntervaloInfoMaquina = TimeSpan.FromHours(1);
    private static readonly TimeSpan IntervaloTrim = TimeSpan.FromMinutes(15);

    public Worker(
        AgentConfig cfg,
        SpoolStore spool,
        IngestClient cliente,
        CollectorRunner coletores,
        string versao,
        ILogger<Worker> log)
    {
        _cfg = cfg;
        _spool = spool;
        _cliente = cliente;
        _coletores = coletores;
        _versao = versao;
        _log = log;
        _backoff = new Backoff(cfg.Http);
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        _log.LogInformation("MonitorAgent {Versao} iniciando", _versao);
        _log.LogInformation("configuração efetiva: {Config}", _cfg.ToSafeString());

        try
        {
            await _spool.InitializeAsync(ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            // Sem spool não há como honrar a regra 16. Parar é mais honesto que
            // rodar perdendo dado silenciosamente.
            _log.LogCritical(ex,
                "não foi possível inicializar o spool em {Caminho}. O agente NÃO vai rodar: " +
                "sem spool, uma queda de link perde dado, e é justamente esse o dado que importa.",
                _spool.DatabasePath);
            return;
        }

        var pendentes = await _spool.GetStatsAsync(ct).ConfigureAwait(false);
        if (pendentes.Count > 0)
        {
            _log.LogInformation(
                "spool tem {N} amostra(s) pendente(s) de execução anterior (de {De} a {Ate}) — serão drenadas",
                pendentes.Count, pendentes.Oldest, pendentes.Newest);
        }

        // Espalha a partida: 150 PDVs ligando às 8h não podem coletar no mesmo
        // segundo pelo resto do dia.
        var inicial = Backoff.AplicarJitter(TimeSpan.FromSeconds(2), 100);
        await Task.Delay(inicial, ct).ConfigureAwait(false);

        while (!ct.IsCancellationRequested)
        {
            var inicio = DateTime.UtcNow;

            try
            {
                await ExecutarCicloAsync(ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                // Regra 19, última rede. Nada sobe daqui.
                _log.LogError(ex, "ciclo {Ciclo} falhou por completo; o laço continua", _ciclos);
            }

            _ciclos++;

            // Regra 18: jitter no intervalo, todo ciclo. Compensa o tempo já
            // gasto para não acumular deriva no horário das amostras.
            var gasto = DateTime.UtcNow - inicio;
            var espera = Backoff.AplicarJitter(_cfg.Interval, _cfg.Http.JitterPercent) - gasto;

            if (espera < TimeSpan.FromSeconds(1)) espera = TimeSpan.FromSeconds(1);

            try
            {
                await Task.Delay(espera, ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }

        _log.LogInformation("MonitorAgent encerrando após {Ciclos} ciclo(s)", _ciclos);
    }

    private async Task ExecutarCicloAsync(CancellationToken ct)
    {
        // ---- 1. Metadados da máquina, de hora em hora
        if (DateTime.UtcNow >= _proximaColetaDeInfo)
        {
            _infoMaquina = _coletores.CollectMachineInfo();
            _proximaColetaDeInfo = DateTime.UtcNow + IntervaloInfoMaquina;
        }

        // ---- 2. Coleta
        var amostra = await _coletores.CollectAsync(ct).ConfigureAwait(false);

        // ---- 3. REGRA 16: grava no spool ANTES de tentar enviar
        await _spool.EnqueueAsync(amostra, ct).ConfigureAwait(false);

        // ---- 4. Retenção
        if (DateTime.UtcNow >= _proximoTrim)
        {
            await _spool.TrimAsync(ct).ConfigureAwait(false);
            _proximoTrim = DateTime.UtcNow + IntervaloTrim;
        }

        // ---- 5. Drenagem
        if (DateTime.UtcNow < _silencioAte)
        {
            var restante = (int)(_silencioAte - DateTime.UtcNow).TotalSeconds;
            _log.LogDebug("em recuo por mais {Segundos}s; amostra guardada no spool", restante);
            return;
        }

        await DrenarAsync(ct).ConfigureAwait(false);
    }

    /// <summary>
    /// Drena o spool em lotes, do mais antigo para o mais novo.
    ///
    /// Este método é o critério de aceite da Fase 3: depois de 10 minutos sem
    /// rede, ele envia TODAS as amostras acumuladas, e cada uma com o timestamp
    /// original da coleta — nunca o do momento do envio.
    /// </summary>
    private async Task DrenarAsync(CancellationToken ct)
    {
        // Teto de lotes por ciclo: com 10 min de spool a 60s são 10 amostras, um
        // lote só. Mas depois de uma queda de 8 horas são 480 amostras, e enviar
        // tudo num ciclo monopolizaria o link da loja no horário comercial.
        const int lotesPorCiclo = 5;

        for (var i = 0; i < lotesPorCiclo && !ct.IsCancellationRequested; i++)
        {
            var lote = await _spool.DequeueAsync(_cfg.BatchSize, ct).ConfigureAwait(false);

            if (lote.IsEmpty) return;

            // Só lixo ilegível: apagar e seguir. Sem isso a fila travaria na
            // linha corrompida para sempre.
            if (lote.OnlyGarbage)
            {
                _log.LogWarning("descartando {N} linha(s) ilegível(is) do spool", lote.Ids.Count);
                await _spool.AckAsync(lote.Ids, ct).ConfigureAwait(false);
                continue;
            }

            var r = await _cliente.SendAsync(lote.Samples, _infoMaquina, ct).ConfigureAwait(false);

            if (r.CanDelete)
            {
                await _spool.AckAsync(lote.Ids, ct).ConfigureAwait(false);
                _backoff.Reset();
                _avisouNaoAutorizado = false;

                if (r.Outcome == IngestOutcome.Success)
                {
                    // duplicates > 0 é NORMAL e não é erro: é a assinatura de um
                    // reenvio depois de o processo morrer entre o POST e o ack.
                    _log.LogInformation(
                        "enviadas {Total} amostra(s): {Aceitas} novas, {Dup} duplicadas, {Fora} fora da janela{Drift}",
                        lote.Samples.Count, r.Accepted, r.Duplicates, r.OutOfWindow,
                        r.ClockDriftSeconds is { } d and not 0 ? $", drift {d}s" : "");

                    AvisarSobreDrift(r.ClockDriftSeconds);
                }
                else
                {
                    _log.LogError(
                        "servidor rejeitou {N} amostra(s) de forma PERMANENTE (HTTP {Status} {Codigo}): {Mensagem}. " +
                        "Descartadas para não travar a fila — isto indica bug do agente ou versão incompatível.",
                        lote.Samples.Count, r.StatusCode, r.ServerCode ?? "-", r.Message);
                }

                // Lote menor que o teto significa fila esvaziada.
                if (lote.Samples.Count < _cfg.BatchSize) return;
                continue;
            }

            // Não pode apagar: registra a falha e recua.
            await _spool.MarkFailureAsync(lote.Ids, $"HTTP {r.StatusCode} {r.ServerCode}: {r.Message}", ct)
                        .ConfigureAwait(false);

            AplicarRecuo(r);
            return;
        }
    }

    private void AplicarRecuo(IngestResult r)
    {
        // O servidor pediu um tempo específico (429 com Retry-After): obedecer é
        // o que impede o agente de se manter em rate limit indefinidamente.
        var espera = r.RetryAfter is { } ra && ra > TimeSpan.Zero
            ? Backoff.AplicarJitter(ra, _cfg.Http.JitterPercent)
            : _backoff.Next();

        _silencioAte = DateTime.UtcNow + espera;

        switch (r.Outcome)
        {
            case IngestOutcome.Unauthorized:
                // Uma vez, alto e claro. Repetir a cada minuto durante dias
                // afogaria o log (regra 24) — e o sintoma no servidor já é
                // "máquina offline", que a Fase 5 alerta.
                if (!_avisouNaoAutorizado)
                {
                    _avisouNaoAutorizado = true;
                    _log.LogCritical(
                        "SERVIDOR RECUSOU A CREDENCIAL (HTTP {Status} {Codigo}): {Mensagem}. " +
                        "Token revogado, expirado, ou máquina/loja desativada. " +
                        "O spool vai acumular até o teto e então descartar o mais antigo. " +
                        "Ação: reprovisionar esta máquina e atualizar o config.json.",
                        r.StatusCode, r.ServerCode ?? "-", r.Message);
                }
                else
                {
                    _log.LogDebug("credencial ainda recusada; próxima tentativa em {Espera}", espera);
                }
                break;

            case IngestOutcome.ClockRejected:
                _log.LogError(
                    "servidor rejeitou o lote por JANELA TEMPORAL (HTTP {Status}): {Mensagem} " +
                    "O relógio desta máquina está fora de sincronia. O spool foi PRESERVADO: " +
                    "corrija o horário (w32tm /resync) e os dados serão aceitos.",
                    r.StatusCode, r.Message);
                break;

            case IngestOutcome.RateLimited:
                _log.LogWarning(
                    "rate limit no servidor (HTTP 429). Recuando {Espera}. Spool preservado.", espera);
                break;

            default:
                // Link caído é o caso comum numa loja: Debug, não Error. Um Error
                // por minuto durante 6 horas de queda esconde tudo o mais.
                _log.LogDebug(
                    "envio falhou (tentativa {Tentativa}, HTTP {Status}): {Mensagem}. Nova tentativa em {Espera}",
                    _backoff.Attempt, r.StatusCode, r.Message, espera);

                // Marco visível de tanto em tanto, para que uma queda longa
                // apareça no log sem precisar de nível Debug.
                if (_backoff.Attempt is 5 or 20 or 60)
                {
                    _log.LogWarning(
                        "sem contato com a central há {Tentativa} tentativas. Último erro: {Mensagem}. " +
                        "As amostras continuam sendo gravadas no spool.",
                        _backoff.Attempt, r.Message);
                }
                break;
        }
    }

    private void AvisarSobreDrift(int? drift)
    {
        if (drift is null) return;

        var abs = Math.Abs(drift.Value);
        if (abs < 60) return;

        _log.LogWarning(
            "relógio desta máquina está {Segundos}s {Direcao} do servidor. " +
            "Acima da tolerância as amostras passam a ser rejeitadas. Considere 'w32tm /resync'.",
            abs, drift.Value > 0 ? "adiantado" : "atrasado");
    }

    public override async Task StopAsync(CancellationToken ct)
    {
        _log.LogInformation("parada solicitada; tentando drenar o spool uma última vez");

        try
        {
            // O Windows dá alguns segundos no shutdown. Uma tentativa curta pode
            // salvar o último minuto de dado; falhando, ele fica no spool e vai
            // na próxima partida.
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(TimeSpan.FromSeconds(5));
            await DrenarAsync(cts.Token).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _log.LogDebug(ex, "drenagem final não concluída; as amostras ficam no spool");
        }

        await base.StopAsync(ct).ConfigureAwait(false);
    }
}
