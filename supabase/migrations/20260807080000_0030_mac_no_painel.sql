-- =============================================================================
-- 0030 — O MAC aparece no painel
-- =============================================================================
-- A coluna existia em `machines` desde a 0026, mas `machines_status` nunca a
-- expos — entao o dado chegava ao banco e ficava invisivel. Nao havia como
-- responder "o agente ja reportou o MAC?" olhando a tela, que e exatamente a
-- pergunta que se faz depois de atualizar um agente.
--
-- Acrescentadas no FIM da lista de colunas: `create or replace view` recusa
-- mudanca de ordem ou de tipo das existentes, e so aceita colunas novas ao
-- final.
--
-- A definicao abaixo foi extraida da view VIVA, e nao reescrita a partir da
-- 0009: reescrever perderia qualquer ajuste feito entre uma e outra.
-- =============================================================================

create or replace view public.machines_status
with (security_invoker = true) as
SELECT m.id AS machine_id,
    m.label,
    m.hostname,
    m.role_code,
    r.name AS role_name,
    s.id AS site_id,
    s.code AS site_code,
    s.name AS site_name,
    s.timezone AS site_timezone,
    b.id AS brand_id,
    b.code AS brand_code,
    b.name AS brand_name,
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
    m.maintenance_until IS NOT NULL AND m.maintenance_until > now() AS in_maintenance,
    m.maintenance_until,
        CASE
            WHEN NOT m.is_active THEN 'disabled'::text
            WHEN m.last_seen_at IS NULL THEN 'never_seen'::text
            WHEN m.last_seen_at > offline_cutoff() THEN 'online'::text
            ELSE 'offline'::text
        END AS status,
        CASE
            WHEN m.last_seen_at IS NULL THEN NULL::integer
            ELSE EXTRACT(epoch FROM now() - m.last_seen_at)::integer
        END AS seconds_since_seen,
    lm."time" AS last_sample_at,
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
    COALESCE(lsv.services_down, 0::bigint) AS services_down,
    lsv.services_down_names,
    m.os_version,
    m.os_arch
,
  -- Endereco da placa que carrega a rota padrao. Sem ele nao ha Wake-on-LAN:
  -- o pacote magico nao usa IP.
  m.mac_address,
  -- Wi-Fi marcado: WoL sobre Wi-Fi quase nunca funciona, e o painel precisa
  -- dizer QUAL e o impedimento em vez de so desabilitar o botao.
  m.mac_is_wifi
   FROM machines m
     JOIN sites s ON s.id = m.site_id
     JOIN brands b ON b.id = s.brand_id
     JOIN machine_roles r ON r.code = m.role_code
     LEFT JOIN LATERAL ( SELECT x."time",
            x.cpu_pct,
            x.mem_pct,
            x.mem_used_mb,
            x.uptime_seconds,
            x.cpu_temp_c,
            x.gw_latency_ms,
            x.gw_loss_pct,
            x.central_latency_ms,
            x.collect_flags
           FROM metrics x
          WHERE x.machine_id = m.id AND x."time" > (now() - make_interval(hours => app_setting_int('status_lookback_hours'::text)))
          ORDER BY x."time" DESC
         LIMIT 1) lm ON true
     LEFT JOIN LATERAL ( SELECT min(d.free_pct) AS disk_min_free_pct,
            min(d.free_gb) AS disk_min_free_gb,
            (array_agg(d.drive ORDER BY d.free_pct))[1] AS disk_worst_drive
           FROM metrics_disks d
          WHERE d.machine_id = m.id AND d."time" = lm."time") ld ON true
     LEFT JOIN LATERAL ( SELECT count(*) FILTER (WHERE NOT sv.is_running) AS services_down,
            array_agg(sv.service_name ORDER BY sv.service_name) FILTER (WHERE NOT sv.is_running) AS services_down_names
           FROM metrics_services sv
          WHERE sv.machine_id = m.id AND sv."time" = lm."time") lsv ON true;
