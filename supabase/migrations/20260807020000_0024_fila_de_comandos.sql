-- =============================================================================
-- 0024 — Fila de comandos (ação remota, parte 1)
-- =============================================================================
-- O sistema era passivo: observava e mostrava. Isto o torna capaz de AGIR na
-- máquina da loja — reiniciar um serviço, limpar disco, reiniciar o PC.
--
-- A RESTRIÇÃO QUE DEFINE O DESENHO: o agente só faz conexão de SAÍDA. Não existe
-- rota do servidor até o PC da loja, e criar uma exigiria porta liberada, IP
-- público ou VPN — as três coisas que esta arquitetura evita de propósito.
--
-- Então o servidor não manda: ele DEIXA O COMANDO NA FILA, e o agente pergunta.
-- A pergunta acontece no mesmo ciclo de telemetria que já existe, autenticada
-- pelo mesmo token da máquina. Nenhum canal novo, nenhuma credencial nova,
-- nenhuma porta nova.
--
-- O CICLO COMPLETO:
--
--   agente  --POST telemetria + resultados-->  Edge Function
--                                                  |
--                                              ingest_batch          (grava)
--                                              agente_sincronizar    (fila)
--                                                  |
--   agente  <--comandos pendentes---------------- resposta
--   executa, e reporta no ciclo SEGUINTE
--
-- O relato vir no ciclo seguinte é consequência de não haver canal de volta. Não
-- é atraso acidental: é o preço de não abrir porta na loja, e é barato.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A fila
-- -----------------------------------------------------------------------------
create table if not exists public.agent_commands (
  id             uuid primary key default gen_random_uuid(),
  machine_id     uuid not null references public.machines(id) on delete cascade,
  site_id        uuid not null references public.sites(id) on delete cascade,

  kind           text not null,
  params         jsonb not null default '{}'::jsonb,
  dry_run        boolean not null default false,

  status         text not null default 'pending',

  -- Quem pediu. `origem` distingue mão humana de automação, e um dia de
  -- playbook: sem isso, a auditoria de um reboot não diz se alguém clicou ou se
  -- uma regra disparou sozinha.
  created_by     uuid,
  origem         text not null default 'painel',

  created_at     timestamptz not null default now(),
  -- Agendamento: comando pode nascer para o futuro (reiniciar 40 PDVs às 4h).
  not_before     timestamptz not null default now(),
  expires_at     timestamptz not null,

  sent_at        timestamptz,
  acked_at       timestamptz,
  finished_at    timestamptz,

  result_ok      boolean,
  result_text    text,
  result_payload jsonb,

  constraint ac_kind_ck check (kind in (
    'restart_service', 'clear_temp', 'restart_machine', 'run_test_collection'
  )),

  constraint ac_status_ck check (status in (
    'pending', 'sent', 'acked', 'succeeded', 'failed', 'expired', 'canceled'
  )),

  constraint ac_origem_ck check (origem in ('painel', 'playbook', 'incidente')),

  -- Janela coerente: um comando que expira antes de poder rodar nunca rodaria, e
  -- ficaria eternamente `pending` até o expurgo — sintoma sem causa visível.
  constraint ac_janela_ck check (expires_at > not_before),

  -- Terminal exige carimbo de fim, e vice-versa. Sem isto, um comando
  -- "succeeded" sem `finished_at` faria a duração do playbook ser incalculável.
  constraint ac_fim_ck check (
    (status in ('succeeded', 'failed', 'expired', 'canceled')) = (finished_at is not null)
  )
);

create index if not exists ac_fila_idx
  on public.agent_commands (machine_id, status, not_before)
  where status = 'pending';

create index if not exists ac_hist_idx
  on public.agent_commands (machine_id, created_at desc);

comment on table public.agent_commands is
  'Fila de comandos por máquina. O agente PERGUNTA; o servidor nunca conecta na loja.';

-- -----------------------------------------------------------------------------
-- Ajustes de comportamento, por escopo
-- -----------------------------------------------------------------------------
insert into public.app_settings (key, value, description) values
  ('command_ttl_minutes', '30',
   'Minutos até um comando não retirado expirar. Loja offline não pode acumular comando velho.'),
  ('command_reboot_cooldown_minutes', '30',
   'Intervalo mínimo entre dois reinícios da MESMA máquina.'),
  ('command_site_burst_limit', '10',
   'Máximo de comandos por loja numa janela de 10 minutos.'),
  ('command_allow_destructive_auto', 'false',
   'Se automação pode disparar comando destrutivo sem confirmação humana.')
on conflict (key) do nothing;

-- Leitura booleana de app_settings; só existia a versão inteira e a de texto.
create or replace function public.app_settings_bool(p_key text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select lower(coalesce((select value from public.app_settings where key = p_key), 'false'))
         in ('true', '1', 'sim', 'yes')
$fn$;

revoke all on function public.app_settings_bool(text) from public;
grant execute on function public.app_settings_bool(text) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Quais comandos são destrutivos
-- -----------------------------------------------------------------------------
-- Num lugar só. Espalhar esta lista pelo código garantiria que um dia alguém
-- acrescentasse um comando destrutivo e esquecesse de marcá-lo em algum ponto.
create or replace function public.comando_e_destrutivo(p_kind text)
returns boolean
language sql
immutable
as $fn$
  select p_kind in ('restart_machine')
$fn$;

-- -----------------------------------------------------------------------------
-- Validação dos parâmetros
-- -----------------------------------------------------------------------------
-- NÃO EXISTE COMANDO DE SHELL LIVRE. O painel escolhe um TIPO e informa
-- parâmetros; o servidor valida cada um contra o que aquele tipo aceita. Uma
-- string de comando vinda do navegador seria execução remota arbitrária com
-- extra passos.
create or replace function public.validar_comando(
  p_machine_id uuid, p_kind text, p_params jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_servico text;
  v_dias    integer;
  v_conhecidos text[];
begin
  if p_kind = 'restart_service' then
    v_servico := btrim(coalesce(p_params ->> 'servico', ''));

    if v_servico = '' then
      raise exception 'informe o serviço a reiniciar' using errcode = 'MON07';
    end if;

    -- Nome de serviço do Windows não tem espaço nem pontuação exótica. O padrão
    -- rejeita tentativa de embutir argumento, e o `in` abaixo rejeita serviço
    -- que esta máquina nem monitora.
    if v_servico !~ '^[A-Za-z0-9_.-]{1,64}$' then
      raise exception 'nome de serviço inválido: %', v_servico using errcode = 'MON07';
    end if;

    -- A lista efetiva já resolve override-da-máquina vence perfil.
    v_conhecidos := public.effective_critical_services(p_machine_id);

    if v_conhecidos is null or not (v_servico = any(v_conhecidos)) then
      raise exception 'o serviço % não está entre os vigiados desta máquina (%)',
        v_servico, coalesce(array_to_string(v_conhecidos, ', '), 'nenhum')
        using errcode = 'MON07',
              hint = 'Só é possível reiniciar serviço que o perfil da máquina declara como crítico.';
    end if;

    return jsonb_build_object('servico', v_servico);

  elsif p_kind = 'clear_temp' then
    v_dias := coalesce((p_params ->> 'dias_minimos')::integer, 7);

    -- Piso de 1 dia: apagar temporário criado agora quebra software em uso.
    if v_dias < 1 or v_dias > 365 then
      raise exception 'dias_minimos fora da faixa 1..365 (recebido %)', v_dias
        using errcode = 'MON07';
    end if;

    return jsonb_build_object('dias_minimos', v_dias);

  elsif p_kind in ('restart_machine', 'run_test_collection') then
    -- Sem parâmetro. Ignora o que vier: aceitar campo desconhecido em silêncio
    -- cria a ilusão de que ele faz alguma coisa.
    return '{}'::jsonb;
  end if;

  raise exception 'tipo de comando desconhecido: %', p_kind using errcode = 'MON07';
end
$fn$;

-- -----------------------------------------------------------------------------
-- Enfileirar
-- -----------------------------------------------------------------------------
create or replace function public.enfileirar_comando(
  p_machine_id  uuid,
  p_kind        text,
  p_params      jsonb    default '{}'::jsonb,
  p_dry_run     boolean  default false,
  p_confirmado  boolean  default false,
  p_quando      timestamptz default null,
  p_origem      text     default 'painel'
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_m          record;
  v_params     jsonb;
  v_ttl        integer := public.app_setting_int('command_ttl_minutes');
  v_cooldown   integer := public.app_setting_int('command_reboot_cooldown_minutes');
  v_burst      integer := public.app_setting_int('command_site_burst_limit');
  v_quando     timestamptz := coalesce(p_quando, now());
  v_id         uuid;
  v_quem       uuid := auth.uid();
  v_ultimo     timestamptz;
  v_na_janela  integer;
  v_pendentes  integer;
begin
  -- ------------------------------------------------------------- autorização
  if not public.current_user_is_admin() and p_origem = 'painel' then
    raise exception 'apenas administradores podem enviar comandos' using errcode = 'MON09';
  end if;

  select m.machine_id, m.label, m.site_id, m.site_code, m.status, m.agent_version
    into v_m
  from public.machines_status m
  where m.machine_id = p_machine_id;

  if not found then
    raise exception 'máquina não encontrada' using errcode = 'MON07';
  end if;

  if p_origem = 'painel'
     and not exists (select 1 from public.current_user_site_ids() s where s = v_m.site_id) then
    raise exception 'esta máquina não é de uma loja sua' using errcode = 'MON09';
  end if;

  v_params := public.validar_comando(p_machine_id, p_kind, p_params);

  -- ------------------------------------------------------------- guardrails
  -- 1. Destrutivo exige confirmação EXPLÍCITA, sempre. Um `dry_run` é isento
  --    porque, por definição, não faz nada.
  if public.comando_e_destrutivo(p_kind) and not p_dry_run then
    if p_origem <> 'painel'
       and public.app_settings_bool('command_allow_destructive_auto') is not true then
      raise exception 'automação não pode disparar % sem autorização explícita', p_kind
        using errcode = 'MON09',
              hint = 'Ligue command_allow_destructive_auto por sua conta e risco.';
    end if;

    if not p_confirmado then
      raise exception '% é destrutivo e exige confirmação', p_kind
        using errcode = 'MON08',
              hint = 'Repita a chamada com p_confirmado = true.';
    end if;
  end if;

  -- 2. Reinício da MESMA máquina, no máximo um por cooldown.
  --    Sem isto, uma máquina que não volta vira laço de reboot: o alerta segue
  --    aberto, a automação reage, e a loja passa a noite reiniciando.
  if p_kind = 'restart_machine' and not p_dry_run then
    select max(c.created_at) into v_ultimo
    from public.agent_commands c
    where c.machine_id = p_machine_id
      and c.kind = 'restart_machine'
      and not c.dry_run
      and c.status <> 'canceled';

    if v_ultimo is not null and v_ultimo > now() - make_interval(mins => v_cooldown) then
      raise exception 'esta máquina foi reiniciada há menos de % min', v_cooldown
        using errcode = 'MON02',
              hint = 'Se não voltou, o problema não é resolvido reiniciando de novo.';
    end if;
  end if;

  -- 3. Rajada por LOJA. Uma loja inteira travada por fila de comando é um
  --    incidente causado pelo próprio monitoramento.
  select count(*) into v_na_janela
  from public.agent_commands c
  where c.site_id = v_m.site_id
    and c.created_at > now() - interval '10 minutes'
    and c.status <> 'canceled';

  if v_na_janela >= v_burst then
    raise exception 'limite de % comandos por loja em 10 min atingido (%)',
      v_burst, v_m.site_code using errcode = 'MON02';
  end if;

  -- 4. Um comando pendente por vez, por máquina e tipo. Dois "reinicie o
  --    Spooler" na fila executariam duas vezes seguidas sem necessidade.
  select count(*) into v_pendentes
  from public.agent_commands c
  where c.machine_id = p_machine_id
    and c.kind = p_kind
    and c.status in ('pending', 'sent', 'acked');

  if v_pendentes > 0 then
    raise exception 'já existe um % pendente para %', p_kind, v_m.label
      using errcode = 'MON02';
  end if;

  -- ------------------------------------------------------------- enfileira
  insert into public.agent_commands (
    machine_id, site_id, kind, params, dry_run, created_by, origem,
    not_before, expires_at
  ) values (
    p_machine_id, v_m.site_id, p_kind, v_params, p_dry_run, v_quem, p_origem,
    v_quando, v_quando + make_interval(mins => v_ttl)
  )
  returning id into v_id;

  insert into public.events (machine_id, site_id, kind, severity, message, payload)
  values (p_machine_id, v_m.site_id, 'command_queued',
          case when public.comando_e_destrutivo(p_kind) then 'warning' else 'info' end,
          format('comando %s enfileirado para %s%s', p_kind, v_m.label,
                 case when p_dry_run then ' (simulação)' else '' end),
          jsonb_build_object('command_id', v_id, 'kind', p_kind, 'params', v_params,
                             'dry_run', p_dry_run, 'origem', p_origem,
                             'actor', coalesce(v_quem::text, 'sistema')));

  return jsonb_build_object(
    'ok', true, 'command_id', v_id, 'kind', p_kind, 'params', v_params,
    'dry_run', p_dry_run, 'maquina', v_m.label,
    'expira_em', v_quando + make_interval(mins => v_ttl),
    'aviso', case
      when v_m.status <> 'online' then 'a máquina está ' || v_m.status ||
           ': o comando só sai quando ela voltar, e expira antes disso se demorar'
      else null end
  );
end
$fn$;

revoke all on function public.enfileirar_comando(uuid, text, jsonb, boolean, boolean, timestamptz, text) from public;
grant execute on function public.enfileirar_comando(uuid, text, jsonb, boolean, boolean, timestamptz, text)
  to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- O ciclo do agente
-- -----------------------------------------------------------------------------
-- Chamada pela Edge Function logo após `ingest_batch`, com o MESMO token. Faz
-- duas coisas numa transação: registra o que o agente executou, e entrega o que
-- ele deve executar agora.
create or replace function public.agente_sincronizar(
  p_token      text,
  p_resultados jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_maquina uuid;
  v_r       jsonb;
  v_c       record;
  v_saida   jsonb := '[]'::jsonb;
begin
  -- Mesma autenticação da ingestão. Um canal de comando com autenticação
  -- própria seria uma segunda porta para vigiar.
  v_maquina := public.verify_agent_token(p_token);
  if v_maquina is null then
    raise exception 'token inválido' using errcode = 'MON01';
  end if;

  -- ----------------------------------------------------- resultados do ciclo
  for v_r in select * from jsonb_array_elements(coalesce(p_resultados, '[]'::jsonb))
  loop
    update public.agent_commands c
       set status      = case when (v_r ->> 'ok')::boolean then 'succeeded' else 'failed' end,
           finished_at = now(),
           result_ok   = (v_r ->> 'ok')::boolean,
           -- Corta o texto: stdout de um comando pode vir enorme, e a fila não é
           -- lugar de guardar log. O suficiente para diagnosticar, não mais.
           result_text = left(coalesce(v_r ->> 'texto', ''), 4000),
           result_payload = case when jsonb_typeof(v_r -> 'payload') = 'object'
                                 then v_r -> 'payload' else null end
     where c.id = (v_r ->> 'command_id')::uuid
       -- Só a própria máquina fecha o próprio comando.
       and c.machine_id = v_maquina
       and c.status in ('sent', 'acked');

    if found then
      insert into public.events (machine_id, site_id, kind, severity, message, payload)
      select c.machine_id, c.site_id, 'command_result',
             case when c.result_ok then 'info' else 'warning' end,
             format('comando %s em %s: %s', c.kind, m.label,
                    case when c.result_ok then 'sucesso' else 'FALHOU' end),
             jsonb_build_object('command_id', c.id, 'kind', c.kind,
                                'ok', c.result_ok, 'texto', left(coalesce(c.result_text, ''), 500),
                                'dry_run', c.dry_run)
      from public.agent_commands c
      join public.machines m on m.id = c.machine_id
      where c.id = (v_r ->> 'command_id')::uuid;
    end if;
  end loop;

  -- ------------------------------------------------------ comandos a executar
  -- `for update skip locked`: dois ciclos simultâneos da mesma máquina — que
  -- acontece quando um envio demora e o próximo começa — não podem retirar o
  -- mesmo comando duas vezes.
  for v_c in
    update public.agent_commands c
       set status = 'sent', sent_at = now()
     where c.id in (
       select c2.id from public.agent_commands c2
       where c2.machine_id = v_maquina
         and c2.status = 'pending'
         and c2.not_before <= now()
         and c2.expires_at > now()
       order by c2.created_at
       limit 5
       for update skip locked
     )
    returning c.id, c.kind, c.params, c.dry_run, c.expires_at
  loop
    v_saida := v_saida || jsonb_build_object(
      'command_id', v_c.id, 'kind', v_c.kind, 'params', v_c.params,
      'dry_run', v_c.dry_run, 'expires_at', v_c.expires_at);
  end loop;

  return jsonb_build_object('ok', true, 'comandos', v_saida);
end
$fn$;

revoke all on function public.agente_sincronizar(text, jsonb) from public;
grant execute on function public.agente_sincronizar(text, jsonb) to service_role;

comment on function public.agente_sincronizar(text, jsonb) is
  'Ciclo do agente: registra resultados e entrega comandos pendentes. Autenticado pelo token da máquina.';

-- -----------------------------------------------------------------------------
-- Expiração
-- -----------------------------------------------------------------------------
-- Loja offline não pode acumular comando velho. Um "reinicie o Spooler" de
-- ontem executado hoje age sobre um estado que ninguém mais conhece.
create or replace function public.expirar_comandos()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_n integer;
begin
  with venceram as (
    update public.agent_commands c
       set status = 'expired', finished_at = now(),
           result_ok = false,
           result_text = 'expirou sem ser executado'
     where c.status in ('pending', 'sent', 'acked')
       and c.expires_at <= now()
    returning c.id, c.machine_id, c.site_id, c.kind
  )
  insert into public.events (machine_id, site_id, kind, severity, message, payload)
  select v.machine_id, v.site_id, 'command_expired', 'warning',
         format('comando %s expirou sem ser executado', v.kind),
         jsonb_build_object('command_id', v.id, 'kind', v.kind)
  from venceram v;

  get diagnostics v_n = row_count;
  return jsonb_build_object('expirados', v_n, 'em', now());
end
$fn$;

revoke all on function public.expirar_comandos() from public;
grant execute on function public.expirar_comandos() to service_role;

-- -----------------------------------------------------------------------------
-- Leitura pelo painel
-- -----------------------------------------------------------------------------
create or replace view public.comandos_da_maquina with (security_invoker = true) as
select c.id, c.machine_id, c.site_id, c.kind, c.params, c.dry_run, c.status,
       c.origem, c.created_at, c.not_before, c.expires_at, c.sent_at, c.finished_at,
       c.result_ok, c.result_text,
       extract(epoch from (coalesce(c.finished_at, now()) - c.created_at))::integer as duracao_s,
       c.status in ('pending', 'sent', 'acked') as em_andamento
from public.agent_commands c;

comment on view public.comandos_da_maquina is
  'Histórico de comandos. security_invoker: a RLS de agent_commands decide o que aparece.';

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------
alter table public.agent_commands enable row level security;

revoke all on public.agent_commands from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on public.agent_commands from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    -- SELECT apenas. Escrita é só pelas funções acima, que aplicam os
    -- guardrails — um INSERT direto os contornaria inteiros.
    execute 'grant select on public.agent_commands to authenticated';
  end if;
end
$$;

drop policy if exists agent_commands_read on public.agent_commands;
create policy agent_commands_read on public.agent_commands
  for select to authenticated
  using (site_id in (select public.current_user_site_ids()));

-- -----------------------------------------------------------------------------
-- Tipos de evento novos
-- -----------------------------------------------------------------------------
alter table public.events drop constraint if exists events_kind_ck;
alter table public.events add constraint events_kind_ck check (kind in (
  'alert_open', 'alert_recovered', 'alert_notify_failed',
  'machine_provisioned', 'machine_first_seen', 'machine_renamed',
  'token_revoked', 'token_rotated',
  'partition_created', 'partition_dropped', 'retention_purge', 'rollup_run',
  'maintenance_start', 'maintenance_end',
  'agent_error', 'clock_drift', 'ingest_rejected',
  'ingest_config_changed',
  'machine_removed', 'site_removed', 'demo_data_removed',
  'command_queued', 'command_result', 'command_expired', 'command_canceled'
));

-- -----------------------------------------------------------------------------
-- Cancelar
-- -----------------------------------------------------------------------------
create or replace function public.cancelar_comando(p_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_c record;
begin
  if not public.current_user_is_admin() then
    raise exception 'apenas administradores podem cancelar comandos' using errcode = 'MON09';
  end if;

  select c.id, c.kind, c.status, c.site_id, c.machine_id into v_c
  from public.agent_commands c where c.id = p_id;

  if not found then
    raise exception 'comando não encontrado' using errcode = 'MON07';
  end if;

  if not exists (select 1 from public.current_user_site_ids() s where s = v_c.site_id) then
    raise exception 'este comando não é de uma loja sua' using errcode = 'MON09';
  end if;

  -- Já entregue ao agente não dá para cancelar: ele pode estar executando neste
  -- instante. Dizer que cancelou seria mentira.
  if v_c.status <> 'pending' then
    raise exception 'só comando ainda não entregue pode ser cancelado (está %)', v_c.status
      using errcode = 'MON07';
  end if;

  update public.agent_commands
     set status = 'canceled', finished_at = now(), result_text = 'cancelado no painel'
   where id = p_id;

  insert into public.events (machine_id, site_id, kind, severity, message, payload)
  values (v_c.machine_id, v_c.site_id, 'command_canceled', 'info',
          format('comando %s cancelado antes de ser entregue', v_c.kind),
          jsonb_build_object('command_id', v_c.id, 'actor', coalesce(auth.uid()::text, '?')));

  return jsonb_build_object('ok', true, 'command_id', v_c.id);
end
$fn$;

revoke all on function public.cancelar_comando(uuid) from public;
grant execute on function public.cancelar_comando(uuid) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Agendamento da expiração
-- -----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise warning 'pg_cron ausente: expirar_comandos() NAO sera agendada.';
    return;
  end if;

  perform cron.unschedule('expirar-comandos') where exists (
    select 1 from cron.job where jobname = 'expirar-comandos');

  perform cron.schedule('expirar-comandos', '4-59/5 * * * *',
                        'select public.expirar_comandos();');

  raise notice 'expirar_comandos() agendada a cada 5 minutos';
end
$$;
