-- =============================================================================
-- 0045 — Todos os volumes acompanhados no cartao
-- =============================================================================
-- O cartao da loja mostrava UM numero de disco: o do volume mais apertado. Numa
-- maquina com C: e D:, o D: cheio escondia o C: -- ou o contrario --, e a unica
-- forma de ver os dois era abrir a maquina.
--
-- A 0044 deu a escolha de QUAIS volumes acompanhar. Esta da a visao: os volumes
-- escolhidos aparecem todos, um por linha, na grade.
--
-- POR QUE NA VIEW, e nao numa RPC por maquina: o painel ja faz
-- `machines_status?select=*` a cada leitura. Uma coluna nova viaja nesse mesmo
-- select. Uma RPC por maquina custaria uma requisicao por cartao a cada 10 s --
-- com 45 maquinas, 270 requisicoes por minuto para mostrar um numero que ja
-- estava no banco.
--
-- O texto da view foi EXTRAIDO da 0044, nao redigitado. Redigitando o corpo de
-- discos_da_maquina na 0044 eu troquei a forma do retorno sem querer e quase
-- deixei a gaveta de discos vazia em producao, sem erro no console. Sessenta
-- linhas copiadas a mao e sessenta chances de repetir isso.
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
    public.hipervisor_de(m.virt_fabricante, m.virt_modelo, m.virt_bios) AS hipervisor,
  ld.disk_worst_media_type,
  ld.disk_worst_smart_ok,
  ld.disk_worst_wear_pct,
  ld.disk_worst_power_on_hours,
  ld.disk_pior_wear_pct,
  ld.disk_maior_horas,
  -- 0044: quantos volumes o operador tirou do acompanhamento. Vai para a tela.
  --
  -- Não é detalhe de auditoria: sem este número o cartão diria "disco 40 GB de
  -- 120" sem avisar que existe um segundo volume cheio fora da conta, e a pessoa
  -- que desmarcou não é necessariamente a que está olhando.
  COALESCE(lvf.disk_volumes_fora, 0::bigint) AS disk_volumes_fora,
  -- Quais são, para a dica caber na tela sem uma segunda consulta por máquina.
  lvf.disk_drives_fora,
  -- 0045: TODOS os volumes acompanhados, num jsonb.
  --
  -- O cartao mostrava um numero de disco so, o do volume mais apertado, e o Kaua
  -- queria ver o C: E o D: na grade sem abrir maquina nenhuma. Um pedido por
  -- maquina resolveria e custaria N requisicoes por leitura; aqui os volumes
  -- viajam junto com o resto do estado, no mesmo select que ja acontece.
  lvol.disk_volumes
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
         (array_agg(v.media_type ORDER BY v.ordem))[1]                 AS disk_worst_media_type,
         (array_agg(v.smart_ok   ORDER BY v.ordem))[1]                 AS disk_worst_smart_ok,
         (array_agg(v.wear       ORDER BY v.ordem))[1]                 AS disk_worst_wear_pct,
         (array_agg(v.horas      ORDER BY v.ordem))[1]                 AS disk_worst_power_on_hours,
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
         -- 0044: o volume desmarcado sai AQUI, antes de qualquer agregação.
         -- Filtrar depois (num FILTER, ou dando ordem alta) deixaria a porta do
         -- escape da 0036 aberta: quando não sobra nenhum volume grande, o
         -- array_agg pegaria o desmarcado por falta de opção.
         LEFT JOIN public.machine_volumes mv
                ON mv.machine_id = d.machine_id
               AND mv.drive = upper(btrim(d.drive))
         WHERE d.machine_id = m.id AND d."time" = lm."time"
           AND coalesce(mv.acompanhar, true)
       ) v) ld ON true
     LEFT JOIN LATERAL (
       -- Os desmarcados, contados à parte justamente porque saíram da conta
       -- acima. Sem esta lateral eles seriam invisíveis para a tela.
       SELECT count(*) AS disk_volumes_fora,
              string_agg(d2.drive, ', ' ORDER BY d2.drive) AS disk_drives_fora
       FROM metrics_disks d2
       JOIN public.machine_volumes mv2
            ON mv2.machine_id = d2.machine_id
           AND mv2.drive = upper(btrim(d2.drive))
       WHERE d2.machine_id = m.id AND d2."time" = lm."time"
         AND mv2.acompanhar = false
     ) lvf ON true
     LEFT JOIN LATERAL (
       -- Ordenado pelo mais apertado: e a ordem em que o operador quer ler, e e a
       -- mesma ordem que decide qual volume manda no resumo da maquina. Duas
       -- ordens diferentes para a mesma coisa fariam o cartao contradizer a gaveta.
       SELECT jsonb_agg(jsonb_build_object(
                'drive',    d.drive,
                'etiqueta', d.volume_label,
                'total_gb', d.total_gb,
                'free_gb',  d.free_gb,
                'free_pct', d.free_pct,
                'tipo',     d.media_type
              ) ORDER BY coalesce(d.free_pct, 100), d.drive) AS disk_volumes
       FROM metrics_disks d
       LEFT JOIN public.machine_volumes mv
              ON mv.machine_id = d.machine_id
             AND mv.drive = upper(btrim(d.drive))
       WHERE d.machine_id = m.id AND d."time" = lm."time"
         -- As duas exclusoes da 0044/0036 valem aqui igual, senao o cartao
         -- mostraria uma linha para a particao de boot de 500 MB e outra para um
         -- volume que alguem desmarcou de proposito.
         AND coalesce(mv.acompanhar, true)
         AND (d.total_gb IS NULL
              OR d.total_gb >= app_setting_int('disk_ignore_below_gb'::text))
     ) lvol ON true
     LEFT JOIN LATERAL ( SELECT count(*) FILTER (WHERE NOT sv.is_running) AS services_down,
            array_agg(sv.service_name ORDER BY sv.service_name) FILTER (WHERE NOT sv.is_running) AS services_down_names
           FROM metrics_services sv
          WHERE sv.machine_id = m.id AND sv."time" = lm."time") lsv ON true;

comment on column public.machines_status.disk_volumes is
  'Todos os volumes acompanhados da ultima leitura, do mais apertado ao menos. Respeita machine_volumes e disk_ignore_below_gb.';

notify pgrst, 'reload schema';
