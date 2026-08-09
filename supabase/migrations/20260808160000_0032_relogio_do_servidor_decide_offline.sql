-- =============================================================================
-- 0032 — Quem decide "offline" é o relógio do SERVIDOR
-- =============================================================================
-- Uma máquina em Asa Sul aparecia offline "do nada" e voltava sozinha, sem
-- nenhuma queda de rede. O relógio dela estava 87 segundos atrasado.
--
-- A conta que explica o sintoma:
--
--   `last_seen_at` recebia `max(t)` do lote — e `t` é o relógio do AGENTE.
--   Uma máquina 87s atrasada nascia com o último contato já 87s no passado.
--   O limite de offline é 180s. Sobravam 93s de margem, e o agente envia a
--   cada 60s. Ou seja: UM ciclo mais lento que o normal — uma coleta que
--   demorou, uma retentativa, um segundo de link ruim — e ela cruzava os 180s
--   e piscava offline. No ciclo seguinte voltava.
--
-- O erro é conceitual, não da máquina. "Esta máquina está falando comigo?" é
-- uma pergunta sobre o MEU relógio. O relógio dela pode estar em 1998 — se o
-- pacote chegou agora, ela está online agora. Deixar a máquina monitorada
-- definir a própria janela de vigilância é entregar o critério para a parte
-- menos confiável do sistema, e ainda por cima do lado ERRADO: um relógio
-- adiantado ganharia margem extra e continuaria "online" depois de morrer.
--
-- A correção separa as duas datas, que sempre foram coisas diferentes:
--
--   `last_seen_at`     — quando a MEDIÇÃO foi feita, pelo relógio do agente.
--                        Continua sendo o que a série temporal precisa, e é
--                        contra ela que o desvio de relógio é diagnosticado.
--   `last_contact_at`  — quando o pacote CHEGOU, pelo relógio do servidor.
--                        É esta que decide online/offline.
--
-- É a mesma distinção que `metrics.time` e `metrics.ingested_at` já faziam
-- desde a 0004. Ela só nunca tinha subido até `machines`.
--
-- Isto NÃO dispensa acertar o relógio das máquinas: um relógio torto continua
-- deslocando o gráfico histórico e disparando o alerta de desvio. O que muda é
-- que ele para de derrubar o estado da máquina.
-- =============================================================================

alter table public.machines
  add column if not exists last_contact_at timestamptz;

comment on column public.machines.last_contact_at is
  'Relógio do SERVIDOR quando o último lote chegou. É esta coluna que decide '
  'online/offline — nunca last_seen_at, que é o relógio do agente.';

create index if not exists machines_last_contact_idx
  on public.machines (last_contact_at desc nulls first);

-- Retroativo: sem isto, toda máquina ficaria com `last_contact_at` nulo e a
-- view cairia no `coalesce` até o próximo lote. O coalesce existe de qualquer
-- forma como rede de segurança, mas partir de um valor razoável evita um
-- minuto de estado indefinido logo depois da migração.
update public.machines
   set last_contact_at = last_seen_at
 where last_contact_at is null
   and last_seen_at is not null;

-- -----------------------------------------------------------------------------
-- register_metrics — idêntica à 0012, exceto pelo `last_contact_at = now()`
-- -----------------------------------------------------------------------------
create or replace function public.register_metrics(
  p_machine_id uuid,
  p_payload    jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_max_batch     integer := public.app_setting_int('ingest_max_batch_size');
  v_skew_future   integer := public.app_setting_int('clock_skew_future_seconds');
  v_max_age       integer := public.app_setting_int('backfill_max_age_seconds');
  v_agent_version text;
  v_sent_at       timestamptz;
  v_drift         integer;
  v_total         integer;
  v_valid         integer;
  v_ins_metrics   integer;
  v_ins_disks     integer;
  v_ins_services  integer;
  v_min_t         timestamptz;
  v_max_t         timestamptz;
  v_uptime_newest bigint;
  v_machine       record;
  v_maq           jsonb;
  v_new_hostname  text;
begin
  -- ---------------------------------------------------------------- validações
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'payload deve ser um objeto JSON' using errcode = 'MON03';
  end if;

  -- jtext e não ->> : agent_version é do envelope e precisa ser string de fato.
  -- Vindo como número ou objeto, é bug do agente e o operador precisa saber.
  v_agent_version := public.jtext(p_payload -> 'agent_version');
  if v_agent_version is null or length(v_agent_version) not between 1 and 32 then
    raise exception 'agent_version ausente ou inválido (regra 25)' using errcode = 'MON03';
  end if;

  if jsonb_typeof(p_payload -> 'samples') <> 'array' then
    raise exception 'samples deve ser um array' using errcode = 'MON03';
  end if;

  v_total := jsonb_array_length(p_payload -> 'samples');

  if v_total = 0 then
    raise exception 'lote vazio' using errcode = 'MON03';
  end if;

  if v_total > v_max_batch then
    raise exception 'lote com % amostras excede o teto de %', v_total, v_max_batch
      using errcode = 'MON03';
  end if;

  select m.id, m.hostname, m.agent_version, m.site_id
    into v_machine
  from public.machines m
  where m.id = p_machine_id;

  if not found then
    raise exception 'máquina inexistente: %', p_machine_id using errcode = 'MON01';
  end if;

  -- `sent_at` é o relógio do agente NO MOMENTO DO ENVIO. É a única medida de
  -- drift que não se confunde com reenvio de spool: max(t) de um lote antigo
  -- também é antigo, mas sent_at é sempre "agora" na visão do agente.
  --
  -- Aqui a exigência É estrita: sent_at é do envelope, não do spool. Vindo
  -- errado, é bug do agente e o operador precisa saber.
  if p_payload ? 'sent_at' then
    v_sent_at := public.jts(p_payload -> 'sent_at');
    if v_sent_at is null then
      raise exception 'sent_at inválido: %', p_payload -> 'sent_at' using errcode = 'MON03';
    end if;
    v_drift := extract(epoch from (v_sent_at - now()))::integer;
  end if;

  -- ------------------------------------------------------------------ gravação
  with amostras as (
    select
      elem,
      -- Timestamp inválido vira null e cai fora do filtro de `validas`,
      -- descartando SÓ esta amostra em vez de abortar o lote inteiro por causa
      -- de uma linha corrompida no spool.
      public.jts(elem -> 't') as t
    from jsonb_array_elements(public.jarr(p_payload -> 'samples')) elem
  ),
  validas as (
    select *
    from amostras
    where t is not null
      and t <= now() + make_interval(secs => v_skew_future)
      and t >= now() - make_interval(secs => v_max_age)
  ),
  ins_m as (
    insert into public.metrics (
      machine_id, time, agent_version, collect_flags,
      cpu_pct, cpu_queue_length, mem_total_mb, mem_used_mb, mem_pct, swap_used_mb,
      uptime_seconds, proc_count, thread_count, cpu_temp_c,
      gw_latency_ms, gw_loss_pct, central_latency_ms
    )
    select
      p_machine_id,
      v.t,
      v_agent_version,
      coalesce(
        (select array_agg(f #>> '{}')
         from jsonb_array_elements(public.jarr(v.elem -> 'flags')) f),
        '{}'::text[]
      ),
      public.jpct(v.elem -> 'cpu_pct')::real,
      public.jnum_in(v.elem -> 'cpu_queue_length', 0, 1e6)::real,
      public.jnum_in(v.elem -> 'mem_total_mb', 0, 2e7)::integer,
      public.jnum_in(v.elem -> 'mem_used_mb', 0, 2e7)::integer,
      -- mem_pct é DERIVADO no servidor: uma conta a menos para o agente errar.
      case
        when public.jnum(v.elem -> 'mem_total_mb') > 0
         and public.jnum(v.elem -> 'mem_used_mb') is not null
        then least(100, greatest(0,
               100.0 * public.jnum(v.elem -> 'mem_used_mb')
                     / public.jnum(v.elem -> 'mem_total_mb')))::real
        else null
      end,
      public.jnum_in(v.elem -> 'swap_used_mb', 0, 2e7)::integer,
      public.jnum_in(v.elem -> 'uptime_seconds', 0, 4e9)::bigint,
      public.jnum_in(v.elem -> 'proc_count', 0, 1e6)::integer,
      public.jnum_in(v.elem -> 'thread_count', 0, 1e7)::integer,
      -- Faixa idêntica ao CHECK da tabela: sensor reportando 200 °C entra como
      -- NULL (não temos leitura) em vez de violar a constraint e matar o lote.
      public.jnum_in(v.elem -> 'cpu_temp_c', -20, 150)::real,
      public.jnum_in(v.elem -> 'gw_latency_ms', 0, 1e6)::real,
      public.jpct(v.elem -> 'gw_loss_pct')::real,
      public.jnum_in(v.elem -> 'central_latency_ms', 0, 1e6)::real
    from validas v
    on conflict (machine_id, time) do nothing
    returning 1
  ),
  ins_d as (
    insert into public.metrics_disks (
      machine_id, time, drive, volume_label, filesystem,
      total_gb, free_gb, free_pct,
      smart_ok, smart_source, smart_reallocated, smart_pending,
      smart_power_on_hours, smart_wear_pct, media_type
    )
    select
      p_machine_id,
      v.t,
      left(public.jtext(d -> 'drive'), 16),
      public.jtext(d -> 'volume_label'),
      public.jtext(d -> 'filesystem'),
      public.jnum_in(d -> 'total_gb', 0, 1e9)::numeric(12,2),
      public.jnum_in(d -> 'free_gb', 0, 1e9)::numeric(12,2),
      case
        when public.jnum(d -> 'total_gb') > 0
         and public.jnum(d -> 'free_gb') is not null
        then least(100, greatest(0,
               100.0 * public.jnum(d -> 'free_gb') / public.jnum(d -> 'total_gb')))::real
        else null
      end,
      public.jbool(d -> 'smart_ok'),
      -- Fora da lista aceita pelo CHECK, entra NULL em vez de derrubar o lote.
      case
        when public.jtext(d -> 'smart_source') in ('wmi', 'smartctl', 'none')
        then public.jtext(d -> 'smart_source')
      end,
      public.jnum_in(d -> 'smart_reallocated', 0, 1e9)::integer,
      public.jnum_in(d -> 'smart_pending', 0, 1e9)::integer,
      public.jnum_in(d -> 'smart_power_on_hours', 0, 1e7)::integer,
      public.jpct(d -> 'smart_wear_pct')::real,
      public.jtext(d -> 'media_type')
    from validas v
    cross join lateral jsonb_array_elements(public.jarr(v.elem -> 'disks')) d
    where public.jtext(d -> 'drive') is not null
    on conflict (machine_id, time, drive) do nothing
    returning 1
  ),
  ins_s as (
    insert into public.metrics_services (
      machine_id, time, service_name, is_running, start_mode, state_raw, pid
    )
    select
      p_machine_id,
      v.t,
      left(public.jtext(s -> 'name'), 128),
      -- Ausente ou tipo errado => false. Um serviço crítico que o agente não
      -- conseguiu ler conta como PARADO: falso positivo é preferível a um PDV
      -- sem impressão passando batido.
      coalesce(public.jbool(s -> 'is_running'), false),
      case
        when public.jtext(s -> 'start_mode')
             in ('Boot', 'System', 'Auto', 'Manual', 'Disabled', 'Unknown')
        then public.jtext(s -> 'start_mode')
      end,
      public.jtext(s -> 'state_raw'),
      public.jnum_in(s -> 'pid', 0, 2147483647)::integer
    from validas v
    cross join lateral jsonb_array_elements(public.jarr(v.elem -> 'services')) s
    where public.jtext(s -> 'name') is not null
    on conflict (machine_id, time, service_name) do nothing
    returning 1
  )
  select
    (select count(*) from validas),
    (select count(*) from ins_m),
    (select count(*) from ins_d),
    (select count(*) from ins_s),
    (select min(t) from validas),
    (select max(t) from validas),
    -- Uptime da amostra MAIS RECENTE válida, calculado aqui dentro onde a
    -- validação já ocorreu. Fazer este cálculo fora do CTE foi o que antes
    -- reintroduzia o parse da amostra corrompida e matava o lote.
    (select public.jnum_in(v.elem -> 'uptime_seconds', 0, 4e9)::bigint
     from validas v order by v.t desc limit 1)
  into v_valid, v_ins_metrics, v_ins_disks, v_ins_services, v_min_t, v_max_t,
       v_uptime_newest;

  -- Lote inteiro fora da janela: não é ruído, é defeito. Erro explícito para que
  -- o agente NÃO apague o spool achando que enviou (regra 14).
  if v_valid = 0 then
    raise exception
      'nenhuma das % amostras está na janela temporal aceitável (futuro máx %s, idade máx %s)',
      v_total, v_skew_future, v_max_age
      using errcode = 'MON04',
            hint = 'Relógio da máquina provavelmente dessincronizado. Verifique o serviço de horário do Windows.';
  end if;

  -- ---------------------------------------------------- metadados da máquina
  v_maq          := p_payload -> 'machine';
  v_new_hostname := left(public.jtext(v_maq -> 'hostname'), 253);

  update public.machines m
     set last_seen_at = greatest(coalesce(m.last_seen_at, v_max_t), v_max_t),
         -- ESTA é a linha da 0032. `now()` é o relógio do servidor, e o único
         -- que pode responder "ela falou comigo agora". Vale inclusive para
         -- reenvio de spool: o lote pode ser de duas horas atrás, mas quem o
         -- entregou está vivo NESTE instante — e é isso que a tela mostra.
         last_contact_at = now(),
         hostname      = coalesce(v_new_hostname, m.hostname),
         os_caption    = coalesce(public.jtext(v_maq -> 'os_caption'), m.os_caption),
         os_version    = coalesce(public.jtext(v_maq -> 'os_version'), m.os_version),
         os_arch       = coalesce(public.jtext(v_maq -> 'os_arch'), m.os_arch),
         cpu_model     = coalesce(public.jtext(v_maq -> 'cpu_model'), m.cpu_model),
         cpu_cores     = coalesce(public.jnum_in(v_maq -> 'cpu_cores', 1, 1024)::smallint, m.cpu_cores),
         mem_total_mb  = coalesce(public.jnum_in(v_maq -> 'mem_total_mb', 0, 2e7)::integer, m.mem_total_mb),
         ip_lan        = coalesce(public.jinet(v_maq -> 'ip_lan'), m.ip_lan),
         last_boot_at  = coalesce(
                           v_max_t - make_interval(secs => v_uptime_newest),
                           m.last_boot_at),
         agent_version = v_agent_version,
         clock_drift_seconds = coalesce(v_drift, m.clock_drift_seconds)
   where m.id = p_machine_id;

  -- ----------------------------------------------------------- trilha mínima
  if v_machine.agent_version is null then
    insert into public.events (machine_id, site_id, kind, severity, message, payload)
    values (p_machine_id, v_machine.site_id, 'machine_first_seen', 'info',
            format('primeiro contato do agente %s (host %s)',
                   v_agent_version, coalesce(v_new_hostname, 'desconhecido')),
            jsonb_build_object('agent_version', v_agent_version, 'hostname', v_new_hostname));
  end if;

  if v_new_hostname is not null
     and v_machine.hostname is not null
     and v_new_hostname <> v_machine.hostname then
    insert into public.events (machine_id, site_id, kind, severity, message, payload)
    values (p_machine_id, v_machine.site_id, 'machine_renamed', 'info',
            format('hostname mudou de %s para %s (identidade preservada pelo GUID)',
                   v_machine.hostname, v_new_hostname),
            jsonb_build_object('de', v_machine.hostname, 'para', v_new_hostname));
  end if;

  return jsonb_build_object(
    'ok', true,
    'received', v_total,
    'accepted', v_ins_metrics,
    'duplicates', v_valid - v_ins_metrics,
    'out_of_window', v_total - v_valid,
    'disk_rows', v_ins_disks,
    'service_rows', v_ins_services,
    'oldest', v_min_t,
    'newest', v_max_t,
    'clock_drift_seconds', v_drift,
    'server_time', now()
  );
end
$fn$;

comment on function public.register_metrics(uuid, jsonb) is
  'Gravação idempotente do lote (regra 13). Recebe machine_id já autenticado — não valida token. '
  'Carimba last_contact_at com o relógio do servidor (0032).';

-- -----------------------------------------------------------------------------
-- machines_status — o estado passa a sair do relógio do servidor
-- -----------------------------------------------------------------------------
-- Definição extraída da view VIVA (0030). Mudam apenas as duas expressões de
-- `status` e `seconds_since_seen`, e entra `last_contact_at` no fim — colunas
-- novas só podem ser acrescentadas ao final.
--
-- O `coalesce` cobre a máquina cadastrada que nunca reportou depois desta
-- migração: sem ele, uma linha com `last_contact_at` nulo apareceria como
-- 'never_seen' mesmo tendo histórico.
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

-- -----------------------------------------------------------------------------
-- O healthcheck contava online pelo mesmo critério antigo
-- -----------------------------------------------------------------------------
-- Deixá-lo para trás faria "monitorar o monitoramento" discordar do painel —
-- que é exatamente o tipo de divergência que faz alguém perder uma hora
-- decidindo em qual dos dois acreditar.
create or replace function public.ingest_health()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select jsonb_build_object(
    'ok', true,
    'server_time', now(),
    'offline_timeout_seconds', public.app_setting_int('offline_timeout_seconds'),
    'max_batch_size', public.app_setting_int('ingest_max_batch_size'),
    'machines_total', (select count(*) from public.machines where is_active),
    'machines_online', (select count(*) from public.machines
                        where is_active
                          and coalesce(last_contact_at, last_seen_at) > public.offline_cutoff()),
    'partitions_ahead', (
      select count(*)
      from pg_inherits i
      join pg_class c on c.oid = i.inhrelid
      join pg_class p on p.oid = i.inhparent
      where p.relname = 'metrics'
        and to_date(right(c.relname, 6), 'YYYYMM') > date_trunc('month', now())::date
    ),
    'samples_last_hour', (
      select count(*) from public.metrics where time > now() - interval '1 hour'
    )
  )
$fn$;
