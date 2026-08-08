-- =============================================================================
-- 0026 — Ligar um PC desligado (Wake-on-LAN pelo vizinho)
-- =============================================================================
-- Todo o resto do sistema funciona porque O AGENTE PERGUNTA. PC desligado não
-- tem agente, não faz conexão de saída, e não existe rota do servidor até a
-- loja. Um comando na fila para uma máquina desligada só espera e expira.
--
-- Wake-on-LAN inverte quem manda: a placa de rede fica escutando um "pacote
-- mágico" com o PC desligado. Só que esse pacote não atravessa NAT — mandá-lo
-- do servidor exigiria porta liberada em cada loja, exatamente o que esta
-- arquitetura evita.
--
-- ENTÃO QUEM MANDA É O VIZINHO: outro PC da mesma loja, que já está ligado, já
-- roda o agente, já pergunta por comandos, e está na mesma rede.
--
--   painel -> fila -> PC vizinho (online) -> pacote mágico -> alvo acorda
--
-- O comando é enfileirado para o VIZINHO, não para o alvo. É a única forma:
-- enfileirar para quem está desligado seria enfileirar para ninguém.
--
-- DUAS LIMITAÇÕES QUE NÃO TÊM SOLUÇÃO AQUI, e é melhor saber antes:
--   1. loja com um PC só, desligado, não acorda. Não há quem mande o pacote.
--   2. depois de queda de energia total, a maioria das placas só volta a
--      responder a WoL depois de o PC ligar uma vez na mão — justamente o caso
--      de "a loja apagou inteira".
-- =============================================================================

-- -----------------------------------------------------------------------------
-- O endereço físico
-- -----------------------------------------------------------------------------
-- Sem MAC não há para onde mandar o pacote: o WoL não usa IP, usa o endereço da
-- placa. `macaddr` e não `text` porque o tipo normaliza a formatação — o mesmo
-- adaptador escrito 'AA-BB-CC' e 'aa:bb:cc' vira o mesmo valor, e comparação de
-- MAC como texto erraria por causa de hífen.
alter table public.machines add column if not exists mac_address macaddr;

comment on column public.machines.mac_address is
  'MAC da placa cabeada. Necessário para Wake-on-LAN; sem ele a máquina não pode ser ligada remotamente.';

-- -----------------------------------------------------------------------------
-- O agente passa a reportar a rede
-- -----------------------------------------------------------------------------
-- `drop` e não só `create or replace`: acrescentar parâmetro cria uma SOBRECARGA,
-- e aí uma chamada com dois argumentos nomeados fica ambígua entre as duas
-- versões — o PostgREST responde erro, e a ingestão inteira para.
drop function if exists public.agente_sincronizar(text, jsonb);

create or replace function public.agente_sincronizar(
  p_token      text,
  p_resultados jsonb default '[]'::jsonb,
  p_rede       jsonb default '{}'::jsonb
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
  v_mac     text;
begin
  v_maquina := public.verify_agent_token(p_token);
  if v_maquina is null then
    raise exception 'token inválido' using errcode = 'MON01';
  end if;

  -- ------------------------------------------------------------------- rede
  -- Vem por aqui e não pelo `ingest_batch` porque aquela função é o caminho que
  -- não pode quebrar, e os testes dela valem como estão. Este é o mesmo POST,
  -- o mesmo token, a mesma transação lógica.
  v_mac := nullif(btrim(coalesce(p_rede ->> 'mac', '')), '');
  if v_mac is not null then
    begin
      update public.machines set mac_address = v_mac::macaddr where id = v_maquina;
    exception when invalid_text_representation then
      -- MAC malformado não pode derrubar o ciclo de telemetria da loja.
      null;
    end;
  end if;

  -- ----------------------------------------------------- resultados do ciclo
  for v_r in select * from jsonb_array_elements(coalesce(p_resultados, '[]'::jsonb))
  loop
    update public.agent_commands c
       set status      = case when (v_r ->> 'ok')::boolean then 'succeeded' else 'failed' end,
           finished_at = now(),
           result_ok   = (v_r ->> 'ok')::boolean,
           result_text = left(coalesce(v_r ->> 'texto', ''), 4000),
           result_payload = case when jsonb_typeof(v_r -> 'payload') = 'object'
                                 then v_r -> 'payload' else null end
     where c.id = (v_r ->> 'command_id')::uuid
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

revoke all on function public.agente_sincronizar(text, jsonb, jsonb) from public;
grant execute on function public.agente_sincronizar(text, jsonb, jsonb) to service_role;

-- -----------------------------------------------------------------------------
-- O tipo novo
-- -----------------------------------------------------------------------------
alter table public.agent_commands drop constraint if exists ac_kind_ck;
alter table public.agent_commands add constraint ac_kind_ck check (kind in (
  'restart_service', 'clear_temp', 'restart_machine', 'run_test_collection',
  'wake_machine'
));

-- `wake_machine` NÃO é destrutivo: ligar um PC não derruba nada. O que ele exige
-- é outra coisa — um vizinho capaz de mandar o pacote.
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
        using errcode = 'MON07',
              hint = 'Só é possível reiniciar serviço que o perfil da máquina declara como crítico.';
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

    -- Normaliza pelo tipo: o agente recebe sempre no mesmo formato, e um MAC
    -- inventado é recusado aqui e não vira string solta no PowerShell.
    begin
      v_mac := (v_mac::macaddr)::text;
    exception when invalid_text_representation then
      raise exception 'MAC inválido: %', v_mac using errcode = 'MON07';
    end;

    return jsonb_build_object(
      'mac',   v_mac,
      -- Só para o log do agente e para a tela. Não influencia a ação.
      'alvo',  left(coalesce(p_params ->> 'alvo', ''), 80));

  elsif p_kind in ('restart_machine', 'run_test_collection') then
    return '{}'::jsonb;
  end if;

  raise exception 'tipo de comando desconhecido: %', p_kind using errcode = 'MON07';
end
$fn$;

-- -----------------------------------------------------------------------------
-- Quem pode acordar quem
-- -----------------------------------------------------------------------------
-- O vizinho precisa: ser da MESMA loja (o pacote não sai da rede local), estar
-- online, rodar agente que executa comandos, e não ser o próprio alvo.
create or replace function public.vizinho_para_acordar(p_alvo uuid)
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select v.machine_id
  from public.machines_status v
  where v.site_id = (select site_id from public.machines where id = p_alvo)
    and v.machine_id <> p_alvo
    and v.status = 'online'
    and v.is_active
    and public.agente_suporta_comandos(v.agent_version)
  -- O menos ocupado primeiro: espalha o trabalho, e evita que a mesma máquina
  -- carregue a fila da loja inteira.
  order by (
    select count(*) from public.agent_commands c
    where c.machine_id = v.machine_id and c.status in ('pending', 'sent', 'acked')
  ), v.last_seen_at desc
  limit 1
$fn$;

revoke all on function public.vizinho_para_acordar(uuid) from public;
grant execute on function public.vizinho_para_acordar(uuid) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Ligar
-- -----------------------------------------------------------------------------
-- Função própria em vez de `enfileirar_comando` direto porque a inversão de
-- alvo é a parte fácil de errar: o comando vai para o VIZINHO, mas quem o
-- operador escolheu foi o ALVO. Deixar essa troca a cargo de quem chama é
-- garantir que um dia alguém enfileire para a máquina desligada.
create or replace function public.ligar_maquina(p_alvo uuid, p_dry_run boolean default false)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_alvo    record;
  v_vizinho uuid;
  v_nome_v  text;
  v_r       jsonb;
begin
  if not public.current_user_is_admin() then
    raise exception 'apenas administradores podem ligar máquinas' using errcode = 'MON09';
  end if;

  select m.machine_id, m.label, m.site_id, m.site_code, m.status, mm.mac_address
    into v_alvo
  from public.machines_status m
  join public.machines mm on mm.id = m.machine_id
  where m.machine_id = p_alvo;

  if not found then
    raise exception 'máquina não encontrada' using errcode = 'MON07';
  end if;

  if not exists (select 1 from public.current_user_site_ids() s where s = v_alvo.site_id) then
    raise exception 'esta máquina não é de uma loja sua' using errcode = 'MON09';
  end if;

  if v_alvo.mac_address is null then
    raise exception '% ainda não reportou o endereço da placa de rede', v_alvo.label
      using errcode = 'MON07',
            hint = 'O MAC chega no primeiro ciclo de um agente ps-1.3.0 ou mais novo. '
                   'Uma máquina que nunca ficou online com o agente novo não pode ser ligada.';
  end if;

  if v_alvo.status = 'online' then
    raise exception '% já está online', v_alvo.label using errcode = 'MON07';
  end if;

  v_vizinho := public.vizinho_para_acordar(p_alvo);

  if v_vizinho is null then
    raise exception 'nenhuma máquina online em % para mandar o pacote', v_alvo.site_code
      using errcode = 'MON02',
            hint = 'O pacote mágico não atravessa a internet: ele tem que sair de dentro '
                   'da própria loja. Com todos os PCs da loja desligados, não há quem o envie.';
  end if;

  select label into v_nome_v from public.machines where id = v_vizinho;

  -- origem 'painel', mas o alvo do comando é o vizinho.
  v_r := public.enfileirar_comando(
    v_vizinho, 'wake_machine',
    jsonb_build_object('mac', v_alvo.mac_address::text, 'alvo', v_alvo.label),
    p_dry_run, false, null, 'painel');

  return jsonb_build_object(
    'ok', true,
    'command_id', v_r ->> 'command_id',
    'alvo', v_alvo.label,
    'vizinho', v_nome_v,
    'dry_run', p_dry_run,
    'nota', format('%s vai mandar o pacote para %s no próximo ciclo dele',
                   v_nome_v, v_alvo.label));
end
$fn$;

revoke all on function public.ligar_maquina(uuid, boolean) from public;
grant execute on function public.ligar_maquina(uuid, boolean) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- O painel precisa saber se dá para oferecer o botão
-- -----------------------------------------------------------------------------
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
  v_mac      macaddr;
  v_vizinho  uuid;
  v_nome_v   text;
begin
  select m.machine_id, m.label, m.site_id, m.status, m.agent_version, mm.mac_address
    into v_m
  from public.machines_status m
  join public.machines mm on mm.id = m.machine_id
  where m.machine_id = p_machine_id;

  if not found then
    raise exception 'máquina não encontrada' using errcode = 'MON07';
  end if;

  if not exists (select 1 from public.current_user_site_ids() s where s = v_m.site_id) then
    raise exception 'esta máquina não é de uma loja sua' using errcode = 'MON09';
  end if;

  v_servicos := public.effective_critical_services(p_machine_id);
  v_mac      := v_m.mac_address;

  select max(c.created_at) into v_ultimo
  from public.agent_commands c
  where c.machine_id = p_machine_id and c.kind = 'restart_machine'
    and not c.dry_run and c.status <> 'canceled';

  select count(*) into v_pend
  from public.agent_commands c
  where c.machine_id = p_machine_id and c.status in ('pending', 'sent', 'acked');

  -- Só procura vizinho quando faz sentido: para máquina online o botão nem
  -- aparece, e a consulta seria trabalho jogado fora em toda abertura de painel.
  if v_m.status <> 'online' and v_mac is not null then
    v_vizinho := public.vizinho_para_acordar(p_machine_id);
    if v_vizinho is not null then
      select label into v_nome_v from public.machines where id = v_vizinho;
    end if;
  end if;

  return jsonb_build_object(
    'pode',      public.current_user_is_admin(),
    'servicos',  to_jsonb(coalesce(v_servicos, array[]::text[])),
    'status',    v_m.status,
    'pendentes', v_pend,
    'agente_suporta', public.agente_suporta_comandos(v_m.agent_version),
    'agent_version',  v_m.agent_version,

    -- Ligar remotamente. Três coisas têm que ser verdade ao mesmo tempo, e o
    -- painel precisa saber QUAL falta para dizer algo útil em vez de só
    -- desabilitar o botão.
    'ligar', jsonb_build_object(
      'aplicavel', v_m.status <> 'online',
      'tem_mac',   v_mac is not null,
      'vizinho',   v_nome_v),

    'reboot_liberado_em', case
      when v_ultimo is null then null
      when v_ultimo > now() - make_interval(mins => v_cooldown)
        then v_ultimo + make_interval(mins => v_cooldown)
      else null end
  );
end
$fn$;
