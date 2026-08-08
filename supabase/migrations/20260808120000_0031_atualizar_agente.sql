-- =============================================================================
-- 0031 — Atualizar o agente remotamente
-- =============================================================================
-- O problema concreto: dois servidores estão com o agente travando 90s por
-- coletor, e o conserto existe — mas alcançá-lo exige abrir cada PC. Com vinte
-- lojas isso deixa de ser incômodo e passa a ser motivo para nunca atualizar.
--
-- A fila de comandos já resolve o transporte: o agente pergunta, o servidor
-- nunca conecta. Falta só o tipo de comando.
--
-- O QUE ESTE COMANDO NÃO CONSERTA: as máquinas que já estão instaladas com
-- versão anterior ao ps-1.4.1 não sabem executá-lo, e vão responder "tipo de
-- comando desconhecido". Elas precisam de uma atualização manual, uma última
-- vez. Daí em diante, nunca mais.
--
-- O RISCO, dito em voz alta: um agente que se atualiza sozinho pode se
-- substituir por um arquivo quebrado e a máquina fica muda. As proteções:
--   - o agente verifica tamanho e linha de versão ANTES de sobrescrever
--   - relata o resultado ANTES de reiniciar
--   - a tarefa agendada sobe o agente de volta no próximo boot de qualquer jeito
--   - `versao_minima` impede mandar uma atualização que não avança nada
-- =============================================================================

alter table public.agent_commands drop constraint if exists ac_kind_ck;
alter table public.agent_commands add constraint ac_kind_ck check (kind in (
  'restart_service', 'clear_temp', 'restart_machine', 'run_test_collection',
  'wake_machine', 'sleep_machine', 'update_agent'
));

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
  v_mac     text;
  v_modo    text;
  v_conhecidos text[];
begin
  if p_kind = 'restart_service' then
    v_servico := btrim(coalesce(p_params ->> 'servico', ''));
    if v_servico = '' then
      raise exception 'informe o serviço a reiniciar' using errcode = 'MON07';
    end if;
    if v_servico !~ '^[A-Za-z0-9_.-]{1,64}$' then
      raise exception 'nome de serviço inválido: %', v_servico using errcode = 'MON07';
    end if;
    v_conhecidos := public.effective_critical_services(p_machine_id);
    if v_conhecidos is null or not (v_servico = any(v_conhecidos)) then
      raise exception 'o serviço % não está entre os vigiados desta máquina (%)',
        v_servico, coalesce(array_to_string(v_conhecidos, ', '), 'nenhum')
        using errcode = 'MON07';
    end if;
    return jsonb_build_object('servico', v_servico);

  elsif p_kind = 'clear_temp' then
    v_dias := coalesce((p_params ->> 'dias_minimos')::integer, 7);
    if v_dias < 1 or v_dias > 365 then
      raise exception 'dias_minimos fora da faixa 1..365 (recebido %)', v_dias
        using errcode = 'MON07';
    end if;
    return jsonb_build_object('dias_minimos', v_dias);

  elsif p_kind = 'wake_machine' then
    v_mac := btrim(coalesce(p_params ->> 'mac', ''));
    if v_mac = '' then
      raise exception 'sem MAC não há para onde mandar o pacote' using errcode = 'MON07';
    end if;
    begin
      v_mac := (v_mac::macaddr)::text;
    exception when invalid_text_representation then
      raise exception 'MAC inválido: %', v_mac using errcode = 'MON07';
    end;
    return jsonb_build_object('mac', v_mac, 'alvo', left(coalesce(p_params ->> 'alvo', ''), 80));

  elsif p_kind = 'sleep_machine' then
    v_modo := lower(btrim(coalesce(p_params ->> 'modo', 'suspender')));
    if v_modo not in ('suspender', 'hibernar') then
      raise exception 'modo inválido: % (use suspender ou hibernar)', v_modo
        using errcode = 'MON07';
    end if;
    return jsonb_build_object('modo', v_modo);

  elsif p_kind = 'update_agent' then
    -- SEM URL NO PARÂMETRO, de propósito. O agente baixa do MESMO endereço que
    -- ele já usa para enviar telemetria, que está no config.json dele.
    --
    -- Aceitar uma URL vinda do painel seria dar a quem controlasse o banco o
    -- poder de mandar cada PC da rede baixar e executar um script arbitrário —
    -- execução remota de código em todo o parque, com extra passos.
    return '{}'::jsonb;

  elsif p_kind in ('restart_machine', 'run_test_collection') then
    return '{}'::jsonb;
  end if;

  raise exception 'tipo de comando desconhecido: %', p_kind using errcode = 'MON07';
end
$fn$;

-- -----------------------------------------------------------------------------
-- Atualizar a frota
-- -----------------------------------------------------------------------------
-- Enfileira a atualização para TODA máquina que sabe executá-la e ainda não
-- está na versão alvo. É a função que transforma "abrir vinte PCs" em um clique.
create or replace function public.atualizar_frota(
  p_versao_alvo text,
  p_site_id     uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_m         record;
  v_enfileiradas integer := 0;
  v_pulos     jsonb := '[]'::jsonb;
begin
  if not public.current_user_is_admin() then
    raise exception 'apenas administradores podem atualizar a frota' using errcode = 'MON09';
  end if;

  for v_m in
    select m.machine_id, m.label, m.agent_version, m.site_id
    from public.machines_status m
    where m.is_active
      and (p_site_id is null or m.site_id = p_site_id)
      and m.site_id in (select public.current_user_site_ids())
    order by m.label
  loop
    -- Já está na versão alvo: nada a fazer.
    if v_m.agent_version = p_versao_alvo then
      continue;
    end if;

    -- O agente precisa SABER executar `update_agent`. Versões anteriores
    -- respondem "tipo desconhecido" e o comando morre como falha — ruído puro
    -- numa tela de auditoria que deveria mostrar só o que importa.
    if not public.agente_suporta_atualizacao(v_m.agent_version) then
      v_pulos := v_pulos || jsonb_build_object(
        'maquina', v_m.label,
        'versao', coalesce(v_m.agent_version, 'nunca reportou'),
        'motivo', 'anterior ao ps-1.4.1: precisa de uma atualização manual, uma última vez');
      continue;
    end if;

    begin
      perform public.enfileirar_comando(
        v_m.machine_id, 'update_agent', '{}'::jsonb, false, false, null, 'painel');
      v_enfileiradas := v_enfileiradas + 1;
    exception when others then
      -- Rajada por loja, duplicata pendente: são guardrails legítimos, e a
      -- atualização de frota não pode contorná-los.
      v_pulos := v_pulos || jsonb_build_object(
        'maquina', v_m.label, 'versao', coalesce(v_m.agent_version, '?'), 'motivo', sqlerrm);
    end;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'enfileiradas', v_enfileiradas,
    'pulos', v_pulos,
    'alvo', p_versao_alvo);
end
$fn$;

-- `update_agent` entrou no ps-1.4.1. Mesma comparação numérica de
-- `agente_suporta_comandos`: como texto, 'ps-1.10.0' viria antes de 'ps-1.4.1'.
create or replace function public.agente_suporta_atualizacao(p_versao text)
returns boolean
language plpgsql
immutable
as $fn$
declare
  v text[];
  v1 integer; v2 integer; v3 integer;
begin
  if p_versao is null then return false; end if;
  v := regexp_match(p_versao, '(\d+)\.(\d+)\.(\d+)');
  if v is null then return false; end if;
  v1 := v[1]::integer; v2 := v[2]::integer; v3 := v[3]::integer;
  return (v1 > 1)
      or (v1 = 1 and v2 > 4)
      or (v1 = 1 and v2 = 4 and v3 >= 1);
end
$fn$;

revoke all on function public.atualizar_frota(text, uuid) from public;
grant execute on function public.atualizar_frota(text, uuid) to authenticated, service_role;

revoke all on function public.agente_suporta_atualizacao(text) from public;
grant execute on function public.agente_suporta_atualizacao(text) to authenticated, service_role;
