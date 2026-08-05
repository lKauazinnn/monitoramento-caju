-- =============================================================================
-- 0009 — Views expostas ao dashboard
-- =============================================================================
-- Regra 5: TODA view leva security_invoker = true. Sem isso a view rodaria com
-- os privilégios do dono (postgres), furando o RLS das tabelas de base.
-- Consequência: o usuário autenticado precisa das policies de SELECT de 0010.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- machines_status — uma linha por máquina, estado atual
-- -----------------------------------------------------------------------------
-- O status vem de offline_cutoff(), que lê app_settings.offline_timeout_seconds.
-- É a MESMA fonte usada pelo cron de alertas (regra 23).
create or replace view public.machines_status
with (security_invoker = true) as
select
  m.id                                       as machine_id,
  m.label,
  m.hostname,
  m.role_code,
  r.name                                     as role_name,
  s.id                                       as site_id,
  s.code                                     as site_code,
  s.name                                     as site_name,
  s.timezone                                 as site_timezone,
  b.id                                       as brand_id,
  b.code                                     as brand_code,
  b.name                                     as brand_name,
  m.is_active,
  m.last_seen_at,
  m.last_boot_at,
  m.agent_version,
  m.clock_drift_seconds,
  m.os_caption,
  m.cpu_model,
  m.cpu_cores,
  m.mem_total_mb,
  m.ip_lan,
  (m.maintenance_until is not null and m.maintenance_until > now()) as in_maintenance,
  m.maintenance_until,
  case
    when not m.is_active                        then 'disabled'
    when m.last_seen_at is null                 then 'never_seen'
    when m.last_seen_at > public.offline_cutoff() then 'online'
    else 'offline'
  end                                        as status,
  case
    when m.last_seen_at is null then null
    else extract(epoch from (now() - m.last_seen_at))::integer
  end                                        as seconds_since_seen,
  lm.time                                    as last_sample_at,
  lm.cpu_pct,
  lm.mem_pct,
  lm.mem_used_mb,
  lm.uptime_seconds,
  lm.cpu_temp_c,
  lm.gw_latency_ms,
  lm.gw_loss_pct,
  lm.central_latency_ms,
  lm.collect_flags,
  ld.disk_min_free_pct,
  ld.disk_min_free_gb,
  ld.disk_worst_drive,
  coalesce(lsv.services_down, 0)             as services_down,
  lsv.services_down_names,
  -- Acrescentados NO FIM de propósito: `create or replace view` exige que as
  -- colunas iniciais permaneçam na mesma ordem, então inserir no meio faria a
  -- migration falhar em qualquer banco que já tivesse a view antiga.
  m.os_version,
  m.os_arch
from public.machines m
join public.sites  s on s.id = m.site_id
join public.brands b on b.id = s.brand_id
join public.machine_roles r on r.code = m.role_code
left join lateral (
  select x.time, x.cpu_pct, x.mem_pct, x.mem_used_mb, x.uptime_seconds,
         x.cpu_temp_c, x.gw_latency_ms, x.gw_loss_pct, x.central_latency_ms,
         x.collect_flags
  from public.metrics x
  where x.machine_id = m.id
    and x.time > now() - make_interval(hours => public.app_setting_int('status_lookback_hours'))
  order by x.time desc
  limit 1
) lm on true
left join lateral (
  select min(d.free_pct)                                        as disk_min_free_pct,
         min(d.free_gb)                                         as disk_min_free_gb,
         (array_agg(d.drive order by d.free_pct nulls last))[1] as disk_worst_drive
  from public.metrics_disks d
  where d.machine_id = m.id and d.time = lm.time
) ld on true
left join lateral (
  select count(*) filter (where not sv.is_running)                                     as services_down,
         array_agg(sv.service_name order by sv.service_name)
           filter (where not sv.is_running)                                            as services_down_names
  from public.metrics_services sv
  where sv.machine_id = m.id and sv.time = lm.time
) lsv on true;

comment on view public.machines_status is
  'Estado atual por máquina. Status derivado de app_settings.offline_timeout_seconds (fonte única).';

-- -----------------------------------------------------------------------------
-- sites_status — contadores por loja
-- -----------------------------------------------------------------------------
create or replace view public.sites_status
with (security_invoker = true) as
select
  s.id                     as site_id,
  s.code                   as site_code,
  s.name                   as site_name,
  s.city,
  s.state,
  s.vpn_subnet,
  s.gateway_ip,
  s.is_active,
  b.id                     as brand_id,
  b.code                   as brand_code,
  b.name                   as brand_name,
  count(ms.machine_id)                                                as machines_total,
  count(*) filter (where ms.status = 'online')                        as machines_online,
  count(*) filter (where ms.status = 'offline')                       as machines_offline,
  count(*) filter (where ms.status = 'never_seen')                    as machines_never_seen,
  count(*) filter (where ms.status = 'disabled')                      as machines_disabled,
  count(*) filter (where ms.in_maintenance)                           as machines_in_maintenance,
  max(ms.last_seen_at)                                                as last_contact_at,
  round(avg(ms.cpu_pct) filter (where ms.status = 'online')::numeric, 1) as cpu_avg_online,
  min(ms.disk_min_free_pct)                                           as disk_min_free_pct
from public.sites s
join public.brands b on b.id = s.brand_id
left join public.machines_status ms on ms.site_id = s.id
group by s.id, s.code, s.name, s.city, s.state, s.vpn_subnet, s.gateway_ip,
         s.is_active, b.id, b.code, b.name;

-- -----------------------------------------------------------------------------
-- brands_status — contadores por marca
-- -----------------------------------------------------------------------------
create or replace view public.brands_status
with (security_invoker = true) as
select
  b.id                                              as brand_id,
  b.code                                            as brand_code,
  b.name                                            as brand_name,
  b.is_active,
  count(distinct ss.site_id)                        as sites_total,
  coalesce(sum(ss.machines_total), 0)               as machines_total,
  coalesce(sum(ss.machines_online), 0)              as machines_online,
  coalesce(sum(ss.machines_offline), 0)             as machines_offline,
  coalesce(sum(ss.machines_never_seen), 0)          as machines_never_seen,
  max(ss.last_contact_at)                           as last_contact_at
from public.brands b
left join public.sites_status ss on ss.brand_id = b.id
group by b.id, b.code, b.name, b.is_active;

-- -----------------------------------------------------------------------------
-- agent_tokens_admin — inventário de credenciais SEM expor o hash
-- -----------------------------------------------------------------------------
create or replace view public.agent_tokens_admin
with (security_invoker = true) as
select
  t.id                as token_id,
  t.token_prefix,
  t.machine_id,
  m.label             as machine_label,
  s.code              as site_code,
  b.code              as brand_code,
  t.created_at,
  t.created_by,
  t.expires_at,
  t.revoked_at,
  t.revoked_reason,
  t.last_used_at,
  t.use_count,
  case
    when t.revoked_at is not null                          then 'revoked'
    when t.expires_at is not null and t.expires_at <= now() then 'expired'
    when t.last_used_at is null                            then 'never_used'
    else 'active'
  end                 as token_status,
  -- Sobra de rotação esquecida fica visível aqui.
  count(*) filter (where t.revoked_at is null)
    over (partition by t.machine_id) as active_tokens_for_machine
from public.agent_tokens t
join public.machines m on m.id = t.machine_id
join public.sites s on s.id = m.site_id
join public.brands b on b.id = s.brand_id;

comment on view public.agent_tokens_admin is
  'Inventário de tokens. token_hash NUNCA é projetado aqui.';

-- -----------------------------------------------------------------------------
-- machine_services_expected — lista efetiva de serviços críticos por máquina
-- -----------------------------------------------------------------------------
create or replace view public.machine_services_expected
with (security_invoker = true) as
select
  m.id                                                  as machine_id,
  m.site_id,
  m.label,
  m.role_code,
  coalesce(m.critical_services_override, r.critical_services) as critical_services,
  (m.critical_services_override is not null)            as is_override
from public.machines m
join public.machine_roles r on r.code = m.role_code;

-- -----------------------------------------------------------------------------
-- open_alerts — alertas abertos, para o painel
-- -----------------------------------------------------------------------------
create or replace view public.open_alerts
with (security_invoker = true) as
select
  e.id                as event_id,
  e.machine_id,
  m.label             as machine_label,
  e.site_id,
  s.code              as site_code,
  b.code              as brand_code,
  e.rule_id,
  ar.name             as rule_name,
  ar.kind             as rule_kind,
  e.severity,
  e.metric,
  e.value,
  e.threshold,
  e.message,
  e.opened_at,
  extract(epoch from (now() - e.opened_at))::integer as open_seconds,
  e.notified_at,
  e.acknowledged_at,
  e.acknowledged_by
from public.events e
left join public.machines m on m.id = e.machine_id
left join public.sites s on s.id = coalesce(e.site_id, m.site_id)
left join public.brands b on b.id = s.brand_id
left join public.alert_rules ar on ar.id = e.rule_id
where e.kind = 'alert_open' and e.resolved_at is null;
