-- =============================================================================
-- 0012 — Ingestão: rate limit, register_metrics e ingest_batch
-- =============================================================================
-- DECISÃO DE ARQUITETURA: toda a lógica de ingestão (validação de token, rate
-- limit, janela temporal, gravação idempotente) vive AQUI, no banco. A Edge
-- Function é uma casca fina que só faz: validar o segredo compartilhado, parsear
-- JSON, chamar este RPC e mapear SQLSTATE para status HTTP.
--
-- Por quê: a lógica no banco é atômica com a gravação, é testável com psql sem
-- subir runtime nenhum, e não duplica regra entre duas linguagens. A casca fina
-- é a parte que eu NÃO consigo testar localmente sem Deno — então ela carrega o
-- mínimo possível de decisão.
--
-- SQLSTATEs customizados (5 caracteres, classe de usuário) para que a Edge
-- Function mapeie erro em status HTTP sem parsear mensagem:
--   MON01 -> token inválido/revogado/máquina inativa   => HTTP 401
--   MON02 -> rate limit excedido                       => HTTP 429
--   MON03 -> payload malformado                        => HTTP 400
--   MON04 -> lote inteiro fora da janela temporal      => HTTP 422
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Rate limit por agente
-- -----------------------------------------------------------------------------
-- Uma linha POR MÁQUINA, não um contador global: regra 20. Um agente em loop
-- não pode criar contenção na linha que os outros 599 precisam atualizar.
create table if not exists public.ingest_rate_limit (
  machine_id      uuid primary key references public.machines(id) on delete cascade,
  window_start    timestamptz not null,
  request_count   integer not null default 0,
  last_request_at timestamptz not null default now(),
  total_requests  bigint not null default 0,
  total_rejected  bigint not null default 0
);

alter table public.ingest_rate_limit enable row level security;
revoke all on public.ingest_rate_limit from anon, authenticated;
grant all on public.ingest_rate_limit to service_role;
grant select on public.ingest_rate_limit to authenticated;

drop policy if exists ingest_rate_limit_read on public.ingest_rate_limit;
create policy ingest_rate_limit_read on public.ingest_rate_limit
  for select to authenticated
  using (exists (
    select 1 from public.machines m
    where m.id = ingest_rate_limit.machine_id
      and m.site_id in (select public.current_user_site_ids())
  ));

comment on table public.ingest_rate_limit is
  'Janela deslizante de 1 minuto por máquina. Linha por agente evita contenção entre agentes (regra 20).';

-- -----------------------------------------------------------------------------
-- Consumo de cota
-- -----------------------------------------------------------------------------
create or replace function public.ingest_consume_quota(p_machine_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_limit integer := public.app_setting_int('ingest_rate_limit_per_minute');
  v_count integer;
begin
  insert into public.ingest_rate_limit as rl
    (machine_id, window_start, request_count, last_request_at, total_requests)
  values (p_machine_id, date_trunc('minute', now()), 1, now(), 1)
  on conflict (machine_id) do update
    set request_count = case
          when rl.window_start < date_trunc('minute', now()) then 1
          else rl.request_count + 1
        end,
        window_start = greatest(rl.window_start, date_trunc('minute', now())),
        last_request_at = now(),
        total_requests = rl.total_requests + 1
  returning rl.request_count into v_count;

  if v_count > v_limit then
    update public.ingest_rate_limit
       set total_rejected = total_rejected + 1
     where machine_id = p_machine_id;

    raise exception
      'rate limit excedido: % requisições no minuto (teto %)', v_count, v_limit
      using errcode = 'MON02',
            hint = 'Aumente app_settings.ingest_rate_limit_per_minute ou reduza a frequência do agente.';
  end if;
end
$fn$;

-- -----------------------------------------------------------------------------
-- Coerção defensiva de JSON
-- -----------------------------------------------------------------------------
-- MOTIVO, e é o mais importante deste arquivo: um lote reenviado do spool pode
-- conter uma linha corrompida (disco cheio no meio da gravação, bug de versão
-- antiga do agente, arquivo SQLite truncado). Se um único campo com tipo errado
-- abortar o lote, o agente NUNCA consegue drenar o spool — ele reenvia, falha,
-- reenvia, falha, e o dado do incidente morre ali. Foi justamente para não
-- perder esse dado que o spool existe.
--
-- Então: campo com tipo inválido vira NULL e a amostra entra; timestamp
-- inválido descarta APENAS aquela amostra. O lote só falha se estiver
-- integralmente inaproveitável.
--
-- Funções IMMUTABLE e em SQL puro: o planejador as inlineia, custo desprezível.
create or replace function public.jnum(p jsonb)
returns numeric
language sql
immutable
parallel safe
as $fn$
  select case when jsonb_typeof(p) = 'number' then p::text::numeric end
$fn$;

-- Valor só quando plausível. Fora da faixa devolve NULL em vez de estourar o
-- CHECK da tabela: sensor ruim reportando 200 °C não pode derrubar o lote.
create or replace function public.jnum_in(p jsonb, p_min numeric, p_max numeric)
returns numeric
language sql
immutable
parallel safe
as $fn$
  select case
           when jsonb_typeof(p) <> 'number' then null
           when p::text::numeric between p_min and p_max then p::text::numeric
           else null
         end
$fn$;

-- Percentual: clampar é seguro (0 e 100 são os limites reais da grandeza).
create or replace function public.jpct(p jsonb)
returns numeric
language sql
immutable
parallel safe
as $fn$
  select case
           when jsonb_typeof(p) <> 'number' then null
           else least(100::numeric, greatest(0::numeric, p::text::numeric))
         end
$fn$;

create or replace function public.jtext(p jsonb)
returns text
language sql
immutable
parallel safe
as $fn$
  select case when jsonb_typeof(p) = 'string' then p #>> '{}' end
$fn$;

create or replace function public.jbool(p jsonb)
returns boolean
language sql
immutable
parallel safe
as $fn$
  select case when jsonb_typeof(p) = 'boolean' then p::text::boolean end
$fn$;

-- Array garantido: se o agente mandar objeto ou string onde esperávamos lista,
-- devolve lista vazia em vez de fazer jsonb_array_elements() estourar.
create or replace function public.jarr(p jsonb)
returns jsonb
language sql
immutable
parallel safe
as $fn$
  select case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end
$fn$;

create or replace function public.jinet(p jsonb)
returns inet
language plpgsql
immutable
parallel safe
as $fn$
begin
  if jsonb_typeof(p) <> 'string' then
    return null;
  end if;
  return (p #>> '{}')::inet;
exception
  when others then
    return null;
end
$fn$;

create or replace function public.jts(p jsonb)
returns timestamptz
language plpgsql
immutable
parallel safe
as $fn$
begin
  if jsonb_typeof(p) <> 'string' then
    return null;
  end if;
  return (p #>> '{}')::timestamptz;
exception
  when others then
    return null;
end
$fn$;

-- -----------------------------------------------------------------------------
-- register_metrics — gravação idempotente do lote
-- -----------------------------------------------------------------------------
-- Regra 13: `on conflict do nothing` sobre (machine_id, time). Reenviar o mesmo
-- lote não duplica e não é erro — é o caminho normal depois de queda de link.
--
-- Regra 12: o timestamp gravado é o do agente. `ingested_at` recebe o do
-- servidor por default. A janela de sanidade rejeita amostra individual fora da
-- faixa; se o lote INTEIRO estiver fora, é erro (MON04), porque aí não é ruído
-- de relógio, é relógio quebrado ou agente com bug.
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
  'Gravação idempotente do lote (regra 13). Recebe machine_id já autenticado — não valida token.';

-- -----------------------------------------------------------------------------
-- ingest_batch — ponto único chamado pela Edge Function
-- -----------------------------------------------------------------------------
-- Token + rate limit + gravação em UMA chamada, dentro de UMA transação. Isso
-- é o que impede que um token revogado no meio do caminho consiga gravar.
create or replace function public.ingest_batch(
  p_token   text,
  p_payload jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_machine_id uuid;
  v_hash       bytea;
  v_result     jsonb;
begin
  if p_token is null or length(p_token) < 16 then
    raise exception 'token ausente' using errcode = 'MON01';
  end if;

  v_hash := sha256(convert_to(p_token, 'UTF8'));

  -- Busca por igualdade de HASH em índice único: o tempo de resposta depende do
  -- índice, não de quantos bytes do segredo coincidem. Não há oráculo de tempo
  -- sobre o token, e por isso não é preciso comparação byte a byte manual aqui.
  v_machine_id := public.verify_agent_token(p_token);

  if v_machine_id is null then
    raise exception 'token inválido, revogado, expirado, ou máquina/loja inativa'
      using errcode = 'MON01';
  end if;

  -- Cota antes da gravação: lote grande de agente em loop não chega ao disco.
  perform public.ingest_consume_quota(v_machine_id);

  v_result := public.register_metrics(v_machine_id, p_payload);

  perform public.touch_agent_token(v_hash);

  return v_result || jsonb_build_object('machine_id', v_machine_id);
end
$fn$;

comment on function public.ingest_batch(text, jsonb) is
  'Entrada única da ingestão: valida token, aplica rate limit e grava. Atômico.';

-- -----------------------------------------------------------------------------
-- Healthcheck
-- -----------------------------------------------------------------------------
-- Sem dado sensível: serve para monitorar o monitoramento.
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
                        where is_active and last_seen_at > public.offline_cutoff()),
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

-- -----------------------------------------------------------------------------
-- Privilégios
-- -----------------------------------------------------------------------------
-- Regra 3: a escrita de série entra por função servidor e por mais nada.
-- Nenhuma destas funções é exposta a anon: a Edge Function autentica com
-- service_role, que é variável de ambiente do lado servidor (regra 1).
revoke all on function public.ingest_consume_quota(uuid)      from public;
revoke all on function public.register_metrics(uuid, jsonb)   from public;
revoke all on function public.ingest_batch(text, jsonb)       from public;
revoke all on function public.ingest_health()                 from public;

grant execute on function public.ingest_consume_quota(uuid)    to service_role;
grant execute on function public.register_metrics(uuid, jsonb) to service_role;
grant execute on function public.ingest_batch(text, jsonb)     to service_role;
grant execute on function public.ingest_health()               to service_role, authenticated;
