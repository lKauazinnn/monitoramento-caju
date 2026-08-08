-- =============================================================================
-- 0029 — Saber se o MAC reportado é de Wi-Fi
-- =============================================================================
-- A coleta do MAC mudou: era `Get-NetAdapter -Physical`, que devolve VAZIO em
-- máquina virtualizada — o Windows não marca a placa de VM como hardware
-- físico. O agente reportava nada, o servidor aceitava (nulo é legítimo: existe
-- máquina só com Wi-Fi), e o painel dizia "nunca reportou o endereço da placa"
-- sem nenhuma pista do motivo.
--
-- Agora ele pega o adaptador da ROTA PADRÃO — o que de fato carrega o tráfego —
-- e isso resolve o caso da VM. Mas abre outro: esse adaptador pode ser Wi-Fi.
--
-- Wake-on-LAN sobre Wi-Fi depende do adaptador E do ponto de acesso, e na
-- prática quase nunca funciona. Guardar o MAC sem guardar essa distinção faria
-- o painel oferecer "Ligar o PC" para uma máquina que nunca vai acordar — e a
-- pessoa descobriria isso na loja, não na tela.
-- =============================================================================

alter table public.machines add column if not exists mac_is_wifi boolean;

comment on column public.machines.mac_is_wifi is
  'Se o MAC reportado é de adaptador Wi-Fi. WoL sobre Wi-Fi quase nunca funciona.';

drop function if exists public.agente_sincronizar(text, jsonb, jsonb);

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
  v_wifi    boolean;
begin
  v_maquina := public.verify_agent_token(p_token);
  if v_maquina is null then
    raise exception 'token inválido' using errcode = 'MON01';
  end if;

  -- ------------------------------------------------------------------- rede
  v_mac  := nullif(btrim(coalesce(p_rede ->> 'mac', '')), '');
  v_wifi := case when jsonb_typeof(p_rede -> 'mac_wifi') = 'boolean'
                 then (p_rede ->> 'mac_wifi')::boolean else null end;

  if v_mac is not null then
    begin
      update public.machines
         set mac_address = v_mac::macaddr,
             -- coalesce: agente que manda MAC mas não manda a marca (versão
             -- intermediária) não pode apagar o que já se sabe.
             mac_is_wifi = coalesce(v_wifi, mac_is_wifi)
       where id = v_maquina;
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
-- Uma máquina em Wi-Fi não pode ser oferecida para acordar
-- -----------------------------------------------------------------------------
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
  order by (
    select count(*) from public.agent_commands c
    where c.machine_id = v.machine_id and c.status in ('pending', 'sent', 'acked')
  ), v.last_seen_at desc
  limit 1
$fn$;

-- O ALVO é quem precisa estar cabeado — quem manda o pacote pode estar em
-- Wi-Fi sem problema nenhum, porque enviar é só tráfego normal de rede.
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

  select m.machine_id, m.label, m.site_id, m.site_code, m.status,
         mm.mac_address, mm.mac_is_wifi
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
            hint = 'O MAC chega no primeiro ciclo de um agente ps-1.3.1 ou mais novo.';
  end if;

  if v_alvo.mac_is_wifi then
    raise exception '% está em Wi-Fi, e Wake-on-LAN por Wi-Fi não funciona na prática', v_alvo.label
      using errcode = 'MON07',
            hint = 'Ligue a máquina por cabo para poder acordá-la remotamente.';
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

-- -----------------------------------------------------------------------------
-- E o painel diz qual é o impedimento
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
  v_wifi     boolean;
  v_vizinho  uuid;
  v_nome_v   text;
  v_acordou  boolean;
  v_dias     numeric;
  v_limiar   numeric;
begin
  select m.machine_id, m.label, m.site_id, m.status, m.agent_version,
         mm.mac_address, mm.mac_is_wifi
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
  v_wifi     := coalesce(v_m.mac_is_wifi, false);
  v_dias     := public.dias_ligada(p_machine_id);

  select max(c.created_at) into v_ultimo
  from public.agent_commands c
  where c.machine_id = p_machine_id and c.kind = 'restart_machine'
    and not c.dry_run and c.status <> 'canceled';

  select count(*) into v_pend
  from public.agent_commands c
  where c.machine_id = p_machine_id and c.status in ('pending', 'sent', 'acked');

  if v_m.status <> 'online' and v_mac is not null and not v_wifi then
    v_vizinho := public.vizinho_para_acordar(p_machine_id);
    if v_vizinho is not null then
      select label into v_nome_v from public.machines where id = v_vizinho;
    end if;
  end if;

  select exists (
    select 1 from public.agent_commands c
    where c.kind = 'wake_machine' and not c.dry_run and c.result_ok
      and c.params ->> 'mac' = v_mac::text
  ) into v_acordou;

  select re.threshold into v_limiar
  from public.regras_efetivas re
  where re.machine_id = p_machine_id and re.kind = 'uptime_long'
  limit 1;

  return jsonb_build_object(
    'pode',      public.current_user_is_admin(),
    'servicos',  to_jsonb(coalesce(v_servicos, array[]::text[])),
    'status',    v_m.status,
    'pendentes', v_pend,
    'agente_suporta', public.agente_suporta_comandos(v_m.agent_version),
    'agent_version',  v_m.agent_version,

    'ligar', jsonb_build_object(
      'aplicavel', v_m.status <> 'online',
      'tem_mac',   v_mac is not null,
      'wifi',      v_wifi,
      'vizinho',   v_nome_v),

    'suspender', jsonb_build_object(
      'aplicavel', v_m.status = 'online',
      'tem_mac',   v_mac is not null and not v_wifi,
      'tem_vizinho', v_m.status = 'online'
                     and public.vizinho_para_acordar(p_machine_id) is not null,
      'ja_acordou', v_acordou),

    'uptime', jsonb_build_object(
      'dias',   v_dias,
      'limiar', v_limiar,
      'passou', v_limiar is not null and v_dias is not null and v_dias >= v_limiar),

    'reboot_liberado_em', case
      when v_ultimo is null then null
      when v_ultimo > now() - make_interval(mins => v_cooldown)
        then v_ultimo + make_interval(mins => v_cooldown)
      else null end
  );
end
$fn$;
