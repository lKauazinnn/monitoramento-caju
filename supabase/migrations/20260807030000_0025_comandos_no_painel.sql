-- =============================================================================
-- 0025 — O que o painel precisa para mostrar e disparar comandos
-- =============================================================================
-- A view `comandos_da_maquina` nasceu na 0024 sem grant: existia no banco e era
-- invisível para o painel. Criar view exposta sem conceder SELECT é um erro
-- silencioso — nada falha na migração, e o defeito só aparece na tela.
--
-- O grant é seguro porque a view é `security_invoker = true`: quem decide o que
-- cada pessoa vê continua sendo a RLS de `agent_commands`, escopada por loja.
-- =============================================================================

grant select on public.comandos_da_maquina to authenticated;

-- Comparar versão como TEXTO daria 'ps-1.10.0' < 'ps-1.2.0', que é falso e só
-- apareceria quando a numeração passasse de 9 — muito depois de alguém lembrar
-- do porquê. Compara em número, por parte.
create or replace function public.agente_suporta_comandos(p_versao text)
returns boolean
language plpgsql
immutable
as $fn$
declare
  v_partes text[];
  v_maior  integer;
  v_menor  integer;
begin
  if p_versao is null then return false; end if;

  v_partes := regexp_match(p_versao, '(\d+)\.(\d+)\.(\d+)');
  if v_partes is null then return false; end if;

  v_maior := v_partes[1]::integer;
  v_menor := v_partes[2]::integer;

  -- Comandos entraram no ps-1.2.0.
  return (v_maior > 1) or (v_maior = 1 and v_menor >= 2);
end
$fn$;

-- -----------------------------------------------------------------------------
-- O que o painel pode oferecer para ESTA máquina
-- -----------------------------------------------------------------------------
-- Sem isto, a tela teria que deduzir quais botões mostrar a partir de regras
-- espalhadas pelo JavaScript — e regra de autorização que mora no navegador não
-- é regra, é sugestão. O servidor responde, e a tela obedece.
--
-- Não substitui a validação de `enfileirar_comando`: aquela é a que protege. Esta
-- só evita oferecer um botão que vai responder "não pode".
create or replace function public.acoes_da_maquina(p_machine_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_m        record;
  v_servicos text[];
  v_ultimo   timestamptz;
  v_cooldown integer := public.app_setting_int('command_reboot_cooldown_minutes');
  v_pend     integer;
begin
  select m.machine_id, m.label, m.site_id, m.status, m.agent_version
    into v_m
  from public.machines_status m
  where m.machine_id = p_machine_id;

  if not found then
    raise exception 'máquina não encontrada' using errcode = 'MON07';
  end if;

  if not exists (select 1 from public.current_user_site_ids() s where s = v_m.site_id) then
    raise exception 'esta máquina não é de uma loja sua' using errcode = 'MON09';
  end if;

  v_servicos := public.effective_critical_services(p_machine_id);

  select max(c.created_at) into v_ultimo
  from public.agent_commands c
  where c.machine_id = p_machine_id and c.kind = 'restart_machine'
    and not c.dry_run and c.status <> 'canceled';

  select count(*) into v_pend
  from public.agent_commands c
  where c.machine_id = p_machine_id and c.status in ('pending', 'sent', 'acked');

  return jsonb_build_object(
    'pode',      public.current_user_is_admin(),
    'servicos',  to_jsonb(coalesce(v_servicos, array[]::text[])),
    'status',    v_m.status,
    'pendentes', v_pend,

    -- O agente antigo não sabe executar comando. Enfileirar para ele não dá
    -- erro: o comando espera e expira em 30 min, e o painel diria "expirou sem
    -- ser executado" — verdade que não ajuda ninguém. Melhor avisar antes.
    'agente_suporta', public.agente_suporta_comandos(v_m.agent_version),
    'agent_version',  v_m.agent_version,

    'reboot_liberado_em', case
      when v_ultimo is null then null
      when v_ultimo > now() - make_interval(mins => v_cooldown)
        then v_ultimo + make_interval(mins => v_cooldown)
      else null end
  );
end
$fn$;

revoke all on function public.acoes_da_maquina(uuid) from public;
grant execute on function public.acoes_da_maquina(uuid) to authenticated, service_role;

revoke all on function public.agente_suporta_comandos(text) from public;
grant execute on function public.agente_suporta_comandos(text) to authenticated, service_role;
