-- =============================================================================
-- 0033 — Disco em GB, e do MESMO volume
-- =============================================================================
-- "DISCO 10%" nao diz nada sozinho: 10% de 238 GB e 24 GB, e 10% de 500 GB e
-- 50 GB. Quem opera precisa de "100 GB de 238", que qualquer pessoa entende sem
-- fazer conta de cabeca. A porcentagem continua sendo o eixo dos limiares — ela
-- so deixa de ser a unica coisa na tela.
--
-- Para isso falta o TOTAL do volume, que a view nunca expos.
--
-- E ao buscar o total apareceu um defeito antigo. A juncao lateral fazia:
--
--   min(d.free_pct)                            as disk_min_free_pct
--   min(d.free_gb)                             as disk_min_free_gb
--   (array_agg(d.drive ORDER BY d.free_pct))[1] as disk_worst_drive
--
-- Os dois `min` sao INDEPENDENTES. Num PC com C: 8% de 240 GB (19 GB livres) e
-- D: 40% de 2 TB (800 GB livres), o menor free_pct e do C: e o menor free_gb
-- tambem — coincidiu. Mas com C: 8% de 2 TB (160 GB) e D: 40% de 120 GB
-- (48 GB), o painel escrevia "Disco critico em C: (48 GB)": o nome de um volume
-- com o numero de outro. Uma mensagem que manda alguem olhar o disco errado.
--
-- As tres colunas novas saem todas do MESMO volume — o pior por porcentagem
-- livre, que e o que dispara o alerta.
--
-- As antigas ficam: `create or replace view` nao deixa remover coluna, e
-- `disk_min_free_gb` ainda tem sentido proprio ("o volume com menos espaco
-- absoluto"). O que muda e que o painel para de misturar as duas familias.
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
            WHEN COALESCE(m.last_contact_at, m.last_seen_at) IS NULL THEN 'never_seen'::text
            WHEN COALESCE(m.last_contact_at, m.last_seen_at) > offline_cutoff() THEN 'online'::text
            ELSE 'offline'::text
        END AS status,
        CASE
            WHEN COALESCE(m.last_contact_at, m.last_seen_at) IS NULL THEN NULL::integer
            ELSE EXTRACT(epoch FROM now() - COALESCE(m.last_contact_at, m.last_seen_at))::integer
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
,
  -- Quando o pacote chegou, pelo relógio do servidor (0032).
  m.last_contact_at
,
  -- 0033: livre e total DO MESMO volume que `disk_worst_drive`, para o painel
  -- poder dizer "100 GB de 238" sem juntar numero de um disco com nome de outro.
  ld.disk_worst_free_gb,
  ld.disk_worst_total_gb
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
            (array_agg(d.drive ORDER BY d.free_pct))[1] AS disk_worst_drive,
            -- A MESMA ordenacao das tres: `ORDER BY d.free_pct` em todas, para o
            -- indice [1] cair sempre no mesmo volume.
            (array_agg(d.free_gb ORDER BY d.free_pct))[1] AS disk_worst_free_gb,
            (array_agg(d.total_gb ORDER BY d.free_pct))[1] AS disk_worst_total_gb
           FROM metrics_disks d
          WHERE d.machine_id = m.id AND d."time" = lm."time") ld ON true
     LEFT JOIN LATERAL ( SELECT count(*) FILTER (WHERE NOT sv.is_running) AS services_down,
            array_agg(sv.service_name ORDER BY sv.service_name) FILTER (WHERE NOT sv.is_running) AS services_down_names
           FROM metrics_services sv
          WHERE sv.machine_id = m.id AND sv."time" = lm."time") lsv ON true;

comment on view public.machines_status is
  'Estado atual por maquina. disk_worst_* saem todos do mesmo volume (o pior por '
  'porcentagem livre); disk_min_free_gb e independente e significa "menor espaco '
  'absoluto entre os volumes".';
