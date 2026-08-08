-- =============================================================================
-- 0022 — Rollup horário (fase 7)
-- =============================================================================
-- As tabelas `metrics_hourly` e `metrics_disks_hourly` existem desde a 0006, com
-- as colunas certas. NADA NUNCA AS PREENCHEU: estavam vazias.
--
-- Isso não era só uma funcionalidade faltando — era perda de dado marcada para
-- acontecer. `drop_old_partitions()` roda todo dia às 3:17 e derruba partições
-- de `metrics` com mais de `metrics_retention_days` (30). Sem rollup, o histórico
-- daquele mês some para sempre, e o gráfico de 30 dias fica vazio justamente
-- quando alguém precisa provar o que aconteceu.
--
-- Esta migração faz três coisas:
--
--   1. `rollup_horario()` agrega o cru em horas, de forma idempotente.
--   2. `run_maintenance()` passa a AGREGAR ANTES DE APAGAR. A ordem é a coisa
--      mais importante deste arquivo.
--   3. `drop_old_partitions()` ganha uma trava: recusa derrubar partição de
--      métrica cujo mês não tem cobertura no rollup. Se o rollup falhar por uma
--      semana, o resultado é disco cheio — não histórico perdido. Dá para
--      recuperar de disco cheio.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Rollup
-- -----------------------------------------------------------------------------
-- Recalcula as últimas N horas em vez de só a última: se o job falhou ou o banco
-- ficou fora do ar, a próxima execução preenche o buraco sozinha. Idempotente
-- por `on conflict`, então recalcular não duplica nem some com nada.
--
-- A hora CORRENTE fica de fora: ela ainda está recebendo amostra, e gravá-la
-- agora produziria uma média baseada em meia hora que nunca mais seria corrigida.
create or replace function public.rollup_horario(p_horas integer default 48)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_desde   timestamptz := date_trunc('hour', now()) - make_interval(hours => greatest(p_horas, 1));
  v_ate     timestamptz := date_trunc('hour', now());   -- exclusivo: a hora corrente fica fora
  v_horas   integer;
  v_discos  integer;
  v_intervalo integer := public.app_setting_int('offline_timeout_seconds');
begin
  with cru as (
    select mm.*,
           lag(mm.uptime_seconds) over (partition by mm.machine_id order by mm."time") as lag_uptime
    from public.metrics mm
    where mm."time" >= v_desde and mm."time" < v_ate
  ),
  base as (
    select
      m.machine_id,
      date_trunc('hour', m."time")                            as hour,
      count(*)                                                as samples,
      round(avg(m.cpu_pct)::numeric, 2)                       as cpu_avg,
      max(m.cpu_pct)                                          as cpu_max,
      round(percentile_cont(0.95) within group (order by m.cpu_pct)::numeric, 2) as cpu_p95,
      round(avg(m.mem_pct)::numeric, 2)                       as mem_avg,
      max(m.mem_pct)                                          as mem_max,
      round(avg(m.cpu_temp_c)::numeric, 2)                    as temp_avg,
      max(m.cpu_temp_c)                                       as temp_max,
      round(avg(m.gw_latency_ms)::numeric, 2)                 as gw_latency_avg,
      max(m.gw_latency_ms)                                    as gw_latency_max,
      round(avg(m.gw_loss_pct)::numeric, 2)                   as gw_loss_avg,
      max(m.uptime_seconds)                                   as uptime_max,
      -- Reinício detectado pelo uptime CAINDO dentro da hora. É o único sinal
      -- que o agente dá de que a máquina reiniciou sem ter ficado offline tempo
      -- suficiente para virar alerta.
      count(*) filter (where m.uptime_seconds < m.lag_uptime) as reboot_count
    from cru m
    group by m.machine_id, date_trunc('hour', m."time")
  ),
  -- Serviços e discos vêm de tabelas próprias, agregados pela mesma hora.
  -- `service_down_count` é NOT NULL no esquema, então o coalesce abaixo não é
  -- zelo: sem ele, toda hora sem coleta de serviço quebraria a inserção.
  serv as (
    select s.machine_id, date_trunc('hour', s."time") as hour, max(s.parados) as parados
    from (
      select sv.machine_id, sv."time", count(*) filter (where not sv.is_running) as parados
      from public.metrics_services sv
      where sv."time" >= v_desde and sv."time" < v_ate
      group by sv.machine_id, sv."time"
    ) s
    group by s.machine_id, date_trunc('hour', s."time")
  ),
  disc as (
    select d.machine_id, date_trunc('hour', d."time") as hour, min(d.free_pct) as menor
    from public.metrics_disks d
    where d."time" >= v_desde and d."time" < v_ate
    group by d.machine_id, date_trunc('hour', d."time")
  )
  insert into public.metrics_hourly (
    machine_id, hour, samples, samples_expected,
    cpu_avg, cpu_max, cpu_p95, mem_avg, mem_max,
    temp_avg, temp_max, gw_latency_avg, gw_latency_max, gw_loss_avg,
    uptime_max, reboot_count, service_down_count, disk_min_free_pct, computed_at
  )
  select
    b.machine_id, b.hour, b.samples,
    -- Quantas amostras a hora DEVERIA ter, pelo intervalo de coleta. É o que
    -- transforma "média de CPU" em algo interpretável: uma média de 3 amostras
    -- numa hora que esperava 60 não descreve a hora.
    greatest(1, (3600 / nullif(v_intervalo, 0))),
    b.cpu_avg, b.cpu_max, b.cpu_p95, b.mem_avg, b.mem_max,
    b.temp_avg, b.temp_max, b.gw_latency_avg, b.gw_latency_max, b.gw_loss_avg,
    b.uptime_max, b.reboot_count,
    coalesce(sv.parados, 0),
    dc.menor,
    now()
  from base b
  left join serv sv on sv.machine_id = b.machine_id and sv.hour = b.hour
  left join disc dc on dc.machine_id = b.machine_id and dc.hour = b.hour
  on conflict (machine_id, hour) do update set
    samples          = excluded.samples,
    samples_expected = excluded.samples_expected,
    cpu_avg          = excluded.cpu_avg,
    cpu_max          = excluded.cpu_max,
    cpu_p95          = excluded.cpu_p95,
    mem_avg          = excluded.mem_avg,
    mem_max          = excluded.mem_max,
    temp_avg         = excluded.temp_avg,
    temp_max         = excluded.temp_max,
    gw_latency_avg   = excluded.gw_latency_avg,
    gw_latency_max   = excluded.gw_latency_max,
    gw_loss_avg      = excluded.gw_loss_avg,
    uptime_max        = excluded.uptime_max,
    reboot_count      = excluded.reboot_count,
    service_down_count = excluded.service_down_count,
    disk_min_free_pct = excluded.disk_min_free_pct,
    computed_at       = excluded.computed_at;

  get diagnostics v_horas = row_count;

  -- ------------------------------------------------------------------ discos
  insert into public.metrics_disks_hourly (
    machine_id, hour, drive, total_gb, free_gb_avg, free_gb_min, free_pct_min, samples, computed_at
  )
  select d.machine_id,
         date_trunc('hour', d."time"),
         d.drive,
         max(d.total_gb),
         round(avg(d.free_gb)::numeric, 2),
         min(d.free_gb),
         min(d.free_pct),
         count(*),
         now()
  from public.metrics_disks d
  where d."time" >= v_desde and d."time" < v_ate
  group by d.machine_id, date_trunc('hour', d."time"), d.drive
  on conflict (machine_id, hour, drive) do update set
    total_gb     = excluded.total_gb,
    free_gb_avg  = excluded.free_gb_avg,
    free_gb_min  = excluded.free_gb_min,
    free_pct_min = excluded.free_pct_min,
    samples      = excluded.samples,
    computed_at  = excluded.computed_at;

  get diagnostics v_discos = row_count;

  -- Disco vai pelo MÍNIMO, não pela média: numa hora em que o disco encheu, a
  -- média esconde o pior momento — e o pior momento é a informação.

  return jsonb_build_object(
    'de', v_desde, 'ate', v_ate,
    'horas_gravadas', v_horas,
    'discos_gravados', v_discos,
    'cobertura_ate', (select max(hour) from public.metrics_hourly)
  );
end
$fn$;

revoke all on function public.rollup_horario(integer) from public;
grant execute on function public.rollup_horario(integer) to service_role;

comment on function public.rollup_horario(integer) is
  'Agrega metrics em metrics_hourly. Idempotente; recalcula as ultimas N horas para cobrir falha do job.';

-- -----------------------------------------------------------------------------
-- Trava: não derrubar o que não foi consolidado
-- -----------------------------------------------------------------------------
create or replace function public.mes_esta_consolidado(p_particao text)
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_mes date;
begin
  -- Só partições de MÉTRICA precisam de rollup. Serviços e eventos não têm
  -- agregado correspondente, e exigir cobertura deles travaria o expurgo para
  -- sempre.
  if p_particao !~ '^metrics_[0-9]{6}$' then
    return true;
  end if;

  v_mes := to_date(right(p_particao, 6), 'YYYYMM');

  -- Mês sem nenhuma amostra crua não tem o que consolidar.
  if not exists (
    select 1 from public.metrics
    where "time" >= v_mes and "time" < (v_mes + interval '1 month')
    limit 1
  ) then
    return true;
  end if;

  return exists (
    select 1 from public.metrics_hourly
    where hour >= v_mes and hour < (v_mes + interval '1 month')
    limit 1
  );
end
$fn$;

-- `drop_old_partitions` recriada com a trava.
--
-- A assinatura de saida e a MESMA da 0007: (partition_name, action). Trocar os
-- nomes exigiria DROP antes do CREATE, e um DROP aqui revogaria os grants que a
-- 0010 concedeu — a funcao voltaria sem permissao para o service_role, e o job
-- de manutencao pararia em silencio na madrugada seguinte.
create or replace function public.drop_old_partitions(p_retention_days integer default null)
returns table (partition_name text, action text)
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_retention integer := coalesce(p_retention_days, public.app_setting_int('metrics_retention_days'));
  v_cutoff    date;
  r           record;
begin
  -- Trava de segurança: erro de digitação em app_settings não pode apagar tudo.
  if v_retention < 7 then
    raise exception 'retenção mínima é 7 dias (recebido %). Ajuste app_settings.metrics_retention_days.', v_retention;
  end if;

  v_cutoff := date_trunc('month', now() - make_interval(days => v_retention))::date;

  for r in
    -- Cast obrigatório: pg_class.relname é do tipo `name`, e RETURN QUERY
    -- rejeita name onde a assinatura declara text.
    select c.relname::text as child, p.relname::text as parent
    from pg_inherits i
    join pg_class c on c.oid = i.inhrelid
    join pg_class p on p.oid = i.inhparent
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and p.relname = any (public.partitioned_metric_tables())
      and c.relname ~ '_[0-9]{6}$'
      and to_date(right(c.relname, 6), 'YYYYMM') < v_cutoff
    order by c.relname
  loop
    -- A TRAVA. Derrubar a particao de um mes que nunca foi consolidado apaga
    -- aquele historico para sempre. Se o rollup estiver quebrado, o resultado
    -- disto e disco cheio — e disco cheio a gente resolve.
    if not public.mes_esta_consolidado(r.child) then
      insert into public.events (kind, severity, message, payload)
      values ('retention_purge', 'warning',
              format('particao %s NAO removida: o mes nao foi consolidado no rollup', r.child),
              jsonb_build_object('partition', r.child, 'motivo', 'sem_rollup'));

      -- Devolve a linha com o motivo: quem chama precisa poder distinguir
      -- "nao havia o que remover" de "havia, e eu me recusei".
      partition_name := r.child;
      action := 'mantida_sem_rollup';
      return next;
      continue;
    end if;

    execute format('drop table public.%I', r.child);

    insert into public.events (kind, severity, message, payload)
    values (
      'partition_dropped', 'info',
      format('partição %s removida (retenção de %s dias)', r.child, v_retention),
      jsonb_build_object('parent', r.parent, 'partition', r.child, 'retention_days', v_retention)
    );

    partition_name := r.child;
    action := 'removida';
    return next;
  end loop;
end
$fn$;

-- -----------------------------------------------------------------------------
-- Manutenção: agregar ANTES de apagar
-- -----------------------------------------------------------------------------
create or replace function public.run_maintenance()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_created  integer;
  v_dropped  integer;
  v_purged   jsonb;
  v_rollup   jsonb;
begin
  -- PRIMEIRO o rollup. Esta ordem é a razão de a função ter sido reescrita: o
  -- expurgo abaixo derruba partições de métrica crua, e o que não foi agregado
  -- antes disso não existe mais depois.
  --
  -- 26 horas de janela: cobre o dia inteiro com folga para o job ter falhado uma
  -- vez, sem recalcular a base toda todo dia.
  v_rollup := public.rollup_horario(26);

  select count(*) into v_created
  from public.maintain_partitions() where action = 'criada';

  -- So as REMOVIDAS. A funcao agora tambem devolve as que ela se recusou a
  -- remover, e contar as duas juntas faria o relatorio dizer que apagou o que
  -- justamente preservou.
  select count(*) into v_dropped
  from public.drop_old_partitions() where action = 'removida';

  select jsonb_object_agg(target, rows_deleted) into v_purged
  from public.purge_aggregates();

  return jsonb_build_object(
    'ran_at', now(),
    'rollup', v_rollup,
    'partitions_created', v_created,
    'partitions_dropped', v_dropped,
    'purged', coalesce(v_purged, '{}'::jsonb)
  );
end
$fn$;

-- -----------------------------------------------------------------------------
-- Agendamento
-- -----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise warning 'pg_cron ausente: rollup_horario() NAO sera agendada.';
    return;
  end if;

  perform cron.unschedule('rollup-horario') where exists (
    select 1 from cron.job where jobname = 'rollup-horario');

  -- Minuto 7: depois de a hora fechar, e longe do minuto redondo, onde todo job
  -- de todo mundo dispara.
  perform cron.schedule('rollup-horario', '7 * * * *', 'select public.rollup_horario(3);');

  raise notice 'rollup_horario() agendada de hora em hora';
end
$$;
