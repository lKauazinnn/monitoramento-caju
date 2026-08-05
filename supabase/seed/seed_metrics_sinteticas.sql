-- =============================================================================
-- Seed OPCIONAL — 24h de métricas sintéticas
-- =============================================================================
-- Serve apenas para desenvolver o dashboard (Fase 4) antes de o agente existir.
-- NÃO rode em produção.
--
-- Todo dado gerado aqui carrega agent_version = 'seed-0.0.0': é impossível
-- confundir com amostra real, e um `delete ... where agent_version like 'seed-%'`
-- limpa tudo.
--
-- Cenários embutidos:
--   PDV 02 da BSB-001  -> sem amostras nas últimas 3h (fica "offline")
--   PDV 01 da BSB-002  -> disco em 6% livre (dispara a regra global disk_low)
--   Estação gerência   -> sem temperatura (collect_flags = {temp_unavailable})
-- =============================================================================

begin;

with base as (
  select
    m.id as machine_id,
    m.role_code,
    generate_series(
      date_trunc('minute', now()) - interval '24 hours',
      date_trunc('minute', now()),
      make_interval(secs => public.app_setting_int('agent_interval_seconds'))
    ) as t
  from public.machines m
  where m.id in (
    'bbbbbbbb-0001-4001-8001-000000000001',
    'bbbbbbbb-0002-4002-8002-000000000002',
    'bbbbbbbb-0003-4003-8003-000000000003',
    'bbbbbbbb-0004-4004-8004-000000000004',
    'bbbbbbbb-0005-4005-8005-000000000005'
  )
),
filtrado as (
  select * from base
  -- PDV 02: silencia as últimas 3h para produzir uma máquina offline.
  where not (machine_id = 'bbbbbbbb-0003-4003-8003-000000000003'
             and t > now() - interval '3 hours')
),
gerado as (
  select
    machine_id,
    role_code,
    t,
    -- Onda diária + ruído determinístico derivado do próprio timestamp, para
    -- que reexecutar o seed produza exatamente a mesma série.
    greatest(2, least(99,
      case role_code when 'server' then 35 else 18 end
      + 22 * sin(extract(epoch from t) / 3600.0)
      + 12 * (('x' || substr(md5(machine_id::text || t::text), 1, 4))::bit(16)::int / 65535.0)
    ))::real as cpu_pct,
    case role_code when 'server' then 16384 when 'pdv' then 8192 else 8192 end as mem_total_mb
  from filtrado
)
insert into public.metrics (
  machine_id, time, agent_version, collect_flags,
  cpu_pct, mem_total_mb, mem_used_mb, mem_pct,
  uptime_seconds, proc_count, cpu_temp_c, gw_latency_ms, gw_loss_pct, central_latency_ms
)
select
  g.machine_id,
  g.t,
  'seed-0.0.0',
  case when g.machine_id = 'bbbbbbbb-0005-4005-8005-000000000005'
       then array['temp_unavailable']::text[]
       else '{}'::text[] end,
  g.cpu_pct,
  g.mem_total_mb,
  (g.mem_total_mb * (0.45 + 0.003 * g.cpu_pct))::integer,
  (100 * (0.45 + 0.003 * g.cpu_pct))::real,
  extract(epoch from (g.t - (now() - interval '9 days')))::bigint,
  (110 + g.cpu_pct / 3)::integer,
  case when g.machine_id = 'bbbbbbbb-0005-4005-8005-000000000005'
       then null
       else (44 + g.cpu_pct * 0.28)::real end,
  (0.6 + g.cpu_pct / 90.0)::real,
  0::real,
  (14 + g.cpu_pct / 8.0)::real
from gerado g
on conflict (machine_id, time) do nothing;

-- Discos, com a BSB-002/PDV 01 no vermelho.
insert into public.metrics_disks (
  machine_id, time, drive, filesystem, total_gb, free_gb, free_pct, smart_ok, smart_source, media_type
)
select
  x.machine_id,
  x.time,
  d.drive,
  'NTFS',
  d.total_gb,
  round(d.total_gb * d.free_frac, 2),
  (100 * d.free_frac)::real,
  true,
  'wmi',
  'SSD'
from public.metrics x
join lateral (
  select *
  from (values
    ('C:', 476.00,
     case when x.machine_id = 'bbbbbbbb-0004-4004-8004-000000000004' then 0.06 else 0.41 end),
    ('D:', 931.00, 0.68)
  ) as v(drive, total_gb, free_frac)
  -- Só o servidor tem segundo volume.
  where v.drive = 'C:' or x.machine_id = 'bbbbbbbb-0001-4001-8001-000000000001'
) d on true
where x.agent_version = 'seed-0.0.0'
on conflict (machine_id, time, drive) do nothing;

-- Serviços críticos: o Spooler do PDV 01 da BSB-001 cai nas últimas 2h.
insert into public.metrics_services (machine_id, time, service_name, is_running, start_mode, state_raw)
select
  x.machine_id,
  x.time,
  svc.service_name,
  not (x.machine_id = 'bbbbbbbb-0002-4002-8002-000000000002'
       and x.time > now() - interval '2 hours'),
  'Auto',
  -- Valores reais medidos em Windows 11 pt-BR: State é invariante ('Running'),
  -- vem do MOF. state_raw existe só para diagnóstico; quem decide é is_running.
  case when (x.machine_id = 'bbbbbbbb-0002-4002-8002-000000000002'
             and x.time > now() - interval '2 hours')
       then 'Stopped' else 'Running' end
from public.metrics x
join public.machine_services_expected mse on mse.machine_id = x.machine_id
join lateral unnest(mse.critical_services) as svc(service_name) on true
where x.agent_version = 'seed-0.0.0'
on conflict (machine_id, time, service_name) do nothing;

-- Espelha o último heartbeat em machines, como a ingestão fará na Fase 2.
update public.machines m
set last_seen_at  = agg.last_time,
    last_boot_at  = now() - interval '9 days',
    agent_version = 'seed-0.0.0',
    hostname      = coalesce(m.hostname, 'SEED-' || upper(replace(m.label, ' ', '')))
from (
  select machine_id, max(time) as last_time
  from public.metrics
  where agent_version = 'seed-0.0.0'
  group by machine_id
) agg
where agg.machine_id = m.id;

commit;

select
  agent_version,
  count(*)      as amostras,
  min(time)     as de,
  max(time)     as ate,
  count(distinct machine_id) as maquinas
from public.metrics
group by agent_version;
