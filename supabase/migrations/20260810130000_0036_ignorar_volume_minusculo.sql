-- =============================================================================
-- 0036 — Partição de sistema não decide a saúde da loja
-- =============================================================================
-- CAJU-ITAIM aparecia em ATENÇÃO com "0,1 GB de 0,8". O disco real dela, o `C:`,
-- tinha 336 GB livres de 446 — 75%. Quem puxava o selo era um volume `E:` de
-- 0,84 GB, com 16,7% livre: partição de recuperação ou EFI que ganhou letra.
--
-- O erro não é o número, é o CRITÉRIO. Uma partição de 0,84 GB a 83% cheia é o
-- estado normal dela para sempre. Ninguém vai liberar espaço ali, e nada na loja
-- deixa de funcionar por causa disso. Um alerta que não tem ação possível não é
-- alerta, é ruído — e ruído em tela de operação treina a pessoa a ignorar o
-- vermelho que importa.
--
-- Volumes abaixo de `disk_ignore_below_gb` (16 GB) deixam de ser considerados nas
-- colunas de disco. O limiar:
--
--   - recuperação / EFI / reservada do sistema: 0,1 a 2 GB
--   - pendrive e cartão de PDV: 4 a 32 GB
--   - qualquer volume de sistema Windows de verdade: 32 GB para cima
--
-- 16 GB fica acima de tudo que é partição de serviço e abaixo do menor disco de
-- sistema plausível, inclusive de VM apertada.
--
-- SE TODOS OS VOLUMES ESTIVEREM ABAIXO DO LIMIAR, o maior deles volta a valer.
-- Uma máquina só com disco pequeno é estranha, mas não pode virar máquina sem
-- leitura de disco — isso trocaria um falso alerta por um ponto cego.
-- =============================================================================

insert into public.app_settings (key, value, description)
values ('disk_ignore_below_gb', '16',
        'Volumes menores que isto (GB) nao entram nas metricas de disco: sao particoes '
        'de recuperacao, EFI e reservadas, que vivem cheias por natureza. Se TODOS os '
        'volumes forem menores, o maior volta a valer.')
on conflict (key) do nothing;

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
  m.mac_address,
  m.mac_is_wifi
,
  m.last_contact_at
,
  ld.disk_worst_free_gb,
  ld.disk_worst_total_gb
,
  -- 0036: quantos volumes ficaram de fora por serem pequenos. Existe para o
  -- painel poder DIZER que ignorou algo, em vez de simplesmente não mostrar —
  -- um número que muda sem explicação é pior que um número errado.
  ld.disk_volumes_ignorados
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
     LEFT JOIN LATERAL (
       -- A ORDENAÇÃO É O CRITÉRIO, e ela é uma só para todas as colunas.
       --
       -- `conta` primeiro: volume grande o suficiente vem antes de qualquer
       -- partição de serviço. Só depois `free_pct`. Assim, quando existe pelo
       -- menos um volume que conta, o [1] cai nele; e quando não existe nenhum,
       -- o [1] cai no maior dos pequenos em vez de deixar tudo nulo.
       --
       -- Fazer isto com `WHERE total_gb >= limite` seria mais curto e criaria o
       -- ponto cego: máquina só com disco pequeno ficaria sem leitura nenhuma.
       SELECT
         (array_agg(v.free_pct ORDER BY v.ordem))[1]                   AS disk_min_free_pct,
         (array_agg(v.free_gb  ORDER BY v.conta DESC, v.free_gb))[1]   AS disk_min_free_gb,
         (array_agg(v.drive    ORDER BY v.ordem))[1]                   AS disk_worst_drive,
         (array_agg(v.free_gb  ORDER BY v.ordem))[1]                   AS disk_worst_free_gb,
         (array_agg(v.total_gb ORDER BY v.ordem))[1]                   AS disk_worst_total_gb,
         count(*) FILTER (WHERE NOT v.conta)                           AS disk_volumes_ignorados
       FROM (
         SELECT d.drive, d.free_pct, d.free_gb, d.total_gb,
                -- Volume sem total conhecido conta: não temos base para
                -- descartá-lo, e descartar por falta de dado esconderia disco.
                (d.total_gb IS NULL
                 OR d.total_gb >= app_setting_int('disk_ignore_below_gb'::text)) AS conta,
                -- A chave de ordenação, numa expressão só, para as colunas do
                -- mesmo volume não poderem divergir:
                --
                --   volume que conta  -> ordena por free_pct (o mais apertado)
                --   nenhum conta      -> ordena por -total_gb (o MAIOR primeiro),
                --                        que é o mais provável de ser o disco
                --                        de verdade da máquina
                --
                -- O +1e6 empurra todo volume que não conta para depois de
                -- qualquer free_pct, que vai de 0 a 100.
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

comment on view public.machines_status is
  'Estado atual por maquina. As colunas de disco ignoram volumes abaixo de '
  'disk_ignore_below_gb (particao de recuperacao, EFI, reservada) porque elas vivem '
  'cheias por natureza e nao tem acao possivel; se TODOS forem pequenos, o maior vale. '
  'disk_worst_* saem todos do mesmo volume.';
