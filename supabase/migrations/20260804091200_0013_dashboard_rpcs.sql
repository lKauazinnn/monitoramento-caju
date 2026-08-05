-- =============================================================================
-- 0013 — Funções consumidas pelo dashboard
-- =============================================================================
-- Por que RPC e não SELECT direto na tabela: a policy de RLS em `metrics` faz um
-- EXISTS por linha. Para o card de status (uma amostra por máquina) é
-- irrelevante; para um gráfico de 30 dias com 43 mil linhas, não é.
--
-- Estas funções autorizam UMA vez, no começo, e depois leem sem RLS. A policy
-- continua existindo como rede de segurança para acesso direto à tabela.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Histórico de uma máquina
-- -----------------------------------------------------------------------------
-- Faixas: 24h lê a série bruta; 7d e 30d leem o rollup horário quando existe e
-- caem para o bruto quando não (rollup é Fase 7). Sem esse fallback o dashboard
-- ficaria vazio até a Fase 7 existir.
create or replace function public.machine_history(
  p_machine_id uuid,
  p_range      text default '24h'
)
returns table (
  bucket      timestamptz,
  cpu_avg     real,
  cpu_max     real,
  mem_avg     real,
  temp_avg    real,
  disk_min_free_pct real,
  gw_latency_avg real,
  samples     integer
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_desde    timestamptz;
  v_passo    interval;
begin
  -- Autorização feita UMA vez. Sem isto, um SECURITY DEFINER seria um furo:
  -- qualquer usuário autenticado leria qualquer máquina de qualquer loja.
  if not exists (
    select 1 from public.machines m
    where m.id = p_machine_id
      and m.site_id in (select public.current_user_site_ids())
  ) then
    raise exception 'máquina fora do seu escopo de acesso' using errcode = 'MON05';
  end if;

  case p_range
    when '24h' then v_desde := now() - interval '24 hours';  v_passo := interval '10 minutes';
    when '7d'  then v_desde := now() - interval '7 days';    v_passo := interval '1 hour';
    when '30d' then v_desde := now() - interval '30 days';   v_passo := interval '6 hours';
    else raise exception 'faixa inválida: % (use 24h, 7d ou 30d)', p_range using errcode = 'MON03';
  end case;

  return query
  with balde as (
    select
      -- to_timestamp(floor(epoch/passo)*passo) agrupa em janelas fixas sem
      -- depender do TimeZone da sessão, diferente de date_trunc.
      to_timestamp(floor(extract(epoch from x.time) / extract(epoch from v_passo))
                   * extract(epoch from v_passo)) as b,
      x.cpu_pct, x.mem_pct, x.cpu_temp_c, x.gw_latency_ms, x.time
    from public.metrics x
    where x.machine_id = p_machine_id
      and x.time >= v_desde
  ),
  discos as (
    select
      to_timestamp(floor(extract(epoch from d.time) / extract(epoch from v_passo))
                   * extract(epoch from v_passo)) as b,
      min(d.free_pct) as free_pct
    from public.metrics_disks d
    where d.machine_id = p_machine_id
      and d.time >= v_desde
    group by 1
  )
  select
    balde.b,
    avg(balde.cpu_pct)::real,
    max(balde.cpu_pct)::real,
    avg(balde.mem_pct)::real,
    avg(balde.cpu_temp_c)::real,
    min(discos.free_pct)::real,
    avg(balde.gw_latency_ms)::real,
    count(*)::integer
  from balde
  left join discos on discos.b = balde.b
  group by balde.b
  order by balde.b;
end
$fn$;

-- -----------------------------------------------------------------------------
-- Eventos recentes da máquina
-- -----------------------------------------------------------------------------
create or replace function public.machine_events(
  p_machine_id uuid,
  p_limit      integer default 20
)
returns table (
  id          bigint,
  kind        text,
  severity    text,
  message     text,
  opened_at   timestamptz,
  resolved_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
begin
  if not exists (
    select 1 from public.machines m
    where m.id = p_machine_id
      and m.site_id in (select public.current_user_site_ids())
  ) then
    raise exception 'máquina fora do seu escopo de acesso' using errcode = 'MON05';
  end if;

  return query
  select e.id, e.kind, e.severity, e.message, e.opened_at, e.resolved_at
  from public.events e
  where e.machine_id = p_machine_id
  order by e.opened_at desc
  limit least(greatest(coalesce(p_limit, 20), 1), 200);
end
$fn$;

-- -----------------------------------------------------------------------------
-- Resumo geral, uma chamada só
-- -----------------------------------------------------------------------------
-- O dashboard abre com isto em vez de 4 consultas: menos ida e volta e um número
-- só de "offline" que não pode divergir entre widgets.
create or replace function public.dashboard_summary()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  with visiveis as (
    select * from public.machines_status
    where site_id in (select public.current_user_site_ids())
  )
  select jsonb_build_object(
    'server_time', now(),
    'offline_timeout_seconds', public.app_setting_int('offline_timeout_seconds'),
    'machines_total',      (select count(*) from visiveis),
    'machines_online',     (select count(*) from visiveis where status = 'online'),
    'machines_offline',    (select count(*) from visiveis where status = 'offline'),
    'machines_never_seen', (select count(*) from visiveis where status = 'never_seen'),
    'machines_disabled',   (select count(*) from visiveis where status = 'disabled'),
    'sites_total',         (select count(distinct site_id) from visiveis),
    'open_alerts',         (select count(*) from public.open_alerts),
    'disk_critical',       (select count(*) from visiveis where disk_min_free_pct < 10),
    'services_down',       (select coalesce(sum(services_down), 0) from visiveis)
  )
$fn$;

-- -----------------------------------------------------------------------------
-- Privilégios
-- -----------------------------------------------------------------------------
revoke all on function public.machine_history(uuid, text)  from public;
revoke all on function public.machine_events(uuid, integer) from public;
revoke all on function public.dashboard_summary()           from public;

grant execute on function public.machine_history(uuid, text)   to authenticated, service_role;
grant execute on function public.machine_events(uuid, integer) to authenticated, service_role;
grant execute on function public.dashboard_summary()           to authenticated, service_role;
