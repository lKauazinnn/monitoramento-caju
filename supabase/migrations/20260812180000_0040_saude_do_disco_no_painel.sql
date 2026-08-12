-- =============================================================================
-- 0040 — Saúde do disco no painel
-- =============================================================================
-- `smart_wear_pct` e `smart_power_on_hours` existem em `metrics_disks` desde a
-- 0004 e a ingestão sempre as gravou. O agente é que nunca as preencheu: mandava
-- só o `HealthStatus` binário do Windows, que diz "OK" até o disco estar
-- morrendo — justamente o momento em que a informação deixa de servir.
--
-- O agente ps-1.7.0 passa a medir com `Get-StorageReliabilityCounter`:
--   Wear         -> desgaste do SSD em %, o número que decide troca de peça
--   PowerOnHours -> idade real de uso, não data de compra
--
-- E manda NULO quando o driver não expõe o contador, nunca zero. O painel
-- mostrava `0%` de desgaste nos 44 discos da frota — um número que parecia medido
-- e não era. Isso é pior que campo vazio, porque ninguém desconfia de um zero.
--
-- Aqui as duas viram coluna da view, do MESMO volume que `disk_worst_drive`,
-- seguindo a regra da 0033: número e nome do disco não podem vir de discos
-- diferentes.
-- =============================================================================

create or replace view public.machines_status
with (security_invoker = true) as
SELECT m.id AS machine_id, m.label, m.hostname, m.role_code,
    r.name AS role_name,
    s.id AS site_id, s.code AS site_code, s.name AS site_name, s.timezone AS site_timezone,
    b.id AS brand_id, b.code AS brand_code, b.name AS brand_name,
    m.is_active, m.last_seen_at, m.last_boot_at, m.agent_version, m.clock_drift_seconds,
    m.os_caption, m.cpu_model, m.cpu_cores, m.mem_total_mb, m.ip_lan,
    m.maintenance_until IS NOT NULL AND m.maintenance_until > now() AS in_maintenance,
    m.maintenance_until,
        CASE
            WHEN NOT m.is_active THEN 'disabled'::text
            WHEN COALESCE(m.last_contact_at, m.last_seen_at) IS NULL THEN 'never_seen'::text
            WHEN COALESCE(m.last_contact_at, m.last_seen_at) > offline_cutoff() THEN 'online'::text
            ELSE 'offline'::text
        END AS status,
        CASE
            WHEN COALESCE(m.last_contact_at, m.last_seen_at) IS NULL THEN NULL::integer
            ELSE EXTRACT(epoch FROM now() - COALESCE(m.last_contact_at, m.last_seen_at))::integer
        END AS seconds_since_seen,
    lm."time" AS last_sample_at,
    lm.cpu_pct, lm.mem_pct, lm.mem_used_mb, lm.uptime_seconds, lm.cpu_temp_c,
    lm.gw_latency_ms, lm.gw_loss_pct, lm.central_latency_ms, lm.collect_flags,
    ld.disk_min_free_pct, ld.disk_min_free_gb, ld.disk_worst_drive,
    COALESCE(lsv.services_down, 0::bigint) AS services_down,
    lsv.services_down_names,
    m.os_version, m.os_arch,
    m.mac_address, m.mac_is_wifi,
    m.last_contact_at,
    ld.disk_worst_free_gb, ld.disk_worst_total_gb,
    ld.disk_volumes_ignorados,
    m.mac_is_virtual, m.virt_fabricante, m.virt_modelo, m.virt_uuid,
    public.hipervisor_de(m.virt_fabricante, m.virt_modelo, m.virt_bios) AS hipervisor
,
  -- 0040: saúde do MESMO volume que disk_worst_drive.
  ld.disk_worst_media_type,
  ld.disk_worst_smart_ok,
  ld.disk_worst_wear_pct,
  ld.disk_worst_power_on_hours,
  -- O pior desgaste e a maior idade da máquina INTEIRA, que é o que importa para
  -- decidir troca: o volume mais apertado não é necessariamente o disco mais
  -- gasto.
  ld.disk_pior_wear_pct,
  ld.disk_maior_horas
   FROM machines m
     JOIN sites s ON s.id = m.site_id
     JOIN brands b ON b.id = s.brand_id
     JOIN machine_roles r ON r.code = m.role_code
     LEFT JOIN LATERAL ( SELECT x."time", x.cpu_pct, x.mem_pct, x.mem_used_mb,
            x.uptime_seconds, x.cpu_temp_c, x.gw_latency_ms, x.gw_loss_pct,
            x.central_latency_ms, x.collect_flags
           FROM metrics x
          WHERE x.machine_id = m.id AND x."time" > (now() - make_interval(hours => app_setting_int('status_lookback_hours'::text)))
          ORDER BY x."time" DESC
         LIMIT 1) lm ON true
     LEFT JOIN LATERAL (
       SELECT
         (array_agg(v.free_pct ORDER BY v.ordem))[1]                   AS disk_min_free_pct,
         (array_agg(v.free_gb  ORDER BY v.conta DESC, v.free_gb))[1]   AS disk_min_free_gb,
         (array_agg(v.drive    ORDER BY v.ordem))[1]                   AS disk_worst_drive,
         (array_agg(v.free_gb  ORDER BY v.ordem))[1]                   AS disk_worst_free_gb,
         (array_agg(v.total_gb ORDER BY v.ordem))[1]                   AS disk_worst_total_gb,
         count(*) FILTER (WHERE NOT v.conta)                           AS disk_volumes_ignorados,
         -- Do mesmo volume, pela mesma ordenacao.
         (array_agg(v.media_type ORDER BY v.ordem))[1]                 AS disk_worst_media_type,
         (array_agg(v.smart_ok   ORDER BY v.ordem))[1]                 AS disk_worst_smart_ok,
         (array_agg(v.wear       ORDER BY v.ordem))[1]                 AS disk_worst_wear_pct,
         (array_agg(v.horas      ORDER BY v.ordem))[1]                 AS disk_worst_power_on_hours,
         -- Da maquina toda: max ignora nulo, entao disco sem contador nao zera
         -- o resultado de quem tem.
         max(v.wear)                                                   AS disk_pior_wear_pct,
         max(v.horas)                                                  AS disk_maior_horas
       FROM (
         SELECT d.drive, d.free_pct, d.free_gb, d.total_gb,
                d.media_type, d.smart_ok,
                d.smart_wear_pct AS wear, d.smart_power_on_hours AS horas,
                (d.total_gb IS NULL
                 OR d.total_gb >= app_setting_int('disk_ignore_below_gb'::text)) AS conta,
                (CASE
                   WHEN d.total_gb IS NULL
                     OR d.total_gb >= app_setting_int('disk_ignore_below_gb'::text)
                   THEN coalesce(d.free_pct, 100)::numeric
                   ELSE 1e6 - coalesce(d.total_gb, 0)
                 END) AS ordem
         FROM metrics_disks d
         WHERE d.machine_id = m.id AND d."time" = lm."time"
       ) v) ld ON true
     LEFT JOIN LATERAL ( SELECT count(*) FILTER (WHERE NOT sv.is_running) AS services_down,
            array_agg(sv.service_name ORDER BY sv.service_name) FILTER (WHERE NOT sv.is_running) AS services_down_names
           FROM metrics_services sv
          WHERE sv.machine_id = m.id AND sv."time" = lm."time") lsv ON true;

-- -----------------------------------------------------------------------------
-- Todos os discos de uma máquina, para a gaveta
-- -----------------------------------------------------------------------------
-- A view devolve o pior volume. A gaveta precisa de TODOS: uma máquina com dois
-- discos, um novo e um gasto, é a situação em que a informação mais importa, e
-- um resumo por máquina esconde exatamente isso.
create or replace function public.discos_da_maquina(p_machine_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_t timestamptz;
begin
  if not exists (
    select 1 from public.machines m
    where m.id = p_machine_id
      and m.site_id in (select public.current_user_site_ids())
  ) then
    raise exception 'esta máquina não é de uma loja sua' using errcode = 'MON09';
  end if;

  -- A hora da última amostra COM disco. Usar max(time) de `metrics` traria um
  -- instante em que o coletor de disco falhou, e a gaveta ficaria vazia numa
  -- máquina que tem dado bom no ciclo anterior.
  select max(d."time") into v_t
  from public.metrics_disks d
  where d.machine_id = p_machine_id
    and d."time" > now() - make_interval(hours => public.app_setting_int('status_lookback_hours'));

  if v_t is null then
    return jsonb_build_object('medido_em', null, 'discos', '[]'::jsonb);
  end if;

  return jsonb_build_object(
    'medido_em', v_t,
    'discos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'drive', d.drive,
               'etiqueta', d.volume_label,
               'fs', d.filesystem,
               'total_gb', d.total_gb,
               'free_gb', d.free_gb,
               'free_pct', d.free_pct,
               'tipo', d.media_type,
               'saude_ok', d.smart_ok,
               'fonte', d.smart_source,
               -- Nulo quando nao medido. A tela DIZ "nao medido" em vez de 0.
               'desgaste_pct', d.smart_wear_pct,
               'horas_ligado', d.smart_power_on_hours,
               'pequeno', (d.total_gb is not null
                           and d.total_gb < public.app_setting_int('disk_ignore_below_gb'))
             ) order by d.total_gb desc nulls last)
      from public.metrics_disks d
      where d.machine_id = p_machine_id and d."time" = v_t), '[]'::jsonb));
end
$fn$;

revoke all on function public.discos_da_maquina(uuid) from public;
grant execute on function public.discos_da_maquina(uuid) to authenticated, service_role;
