-- =============================================================================
-- 0027 — Suspender a máquina (para poder acordá-la sem ir ao BIOS)
-- =============================================================================
-- POR QUE ISTO EXISTE, e é a parte que importa:
--
-- Wake-on-LAN de DESLIGAMENTO TOTAL (S5) costuma depender do firmware — "Power
-- On By PCI-E", "ErP Ready" — e placa de varejo não expõe isso ao Windows.
-- Numa loja distante, isso significa mandar alguém até lá.
--
-- Wake-on-LAN de SUSPENSÃO (S3) e de HIBERNAÇÃO (S4) é outra história: quem
-- arma a placa é o sistema operacional, e o sistema operacional se configura
-- por código, de longe. `powercfg -devicequery wake_armed` responde, de forma
-- verificável, se a placa está armada.
--
-- Ou seja: trocando "desligar" por "suspender", o ciclo inteiro
--
--     suspender  ->  acordar  ->  suspender  ->  ...
--
-- acontece sem ninguém encostar na máquina, e sem depender de firmware.
--
-- A troca não é de graça, e é honesto dizer: máquina suspensa continua
-- consumindo (pouco) e não faz o desligamento "limpo" que resolve certos
-- problemas de driver. Para uma loja que fecha à noite e abre de manhã, é o
-- negócio certo. Para uma máquina com problema que só reinício resolve,
-- `restart_machine` continua existindo.
-- =============================================================================

alter table public.agent_commands drop constraint if exists ac_kind_ck;
alter table public.agent_commands add constraint ac_kind_ck check (kind in (
  'restart_service', 'clear_temp', 'restart_machine', 'run_test_collection',
  'wake_machine', 'sleep_machine'
));

-- Suspender É destrutivo no sentido que importa aqui: derruba a máquina para
-- quem está usando. Exige confirmação, como o reinício.
create or replace function public.comando_e_destrutivo(p_kind text)
returns boolean
language sql
immutable
as $fn$
  select p_kind in ('restart_machine', 'sleep_machine')
$fn$;

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

    begin
      v_mac := (v_mac::macaddr)::text;
    exception when invalid_text_representation then
      raise exception 'MAC inválido: %', v_mac using errcode = 'MON07';
    end;

    return jsonb_build_object(
      'mac',  v_mac,
      'alvo', left(coalesce(p_params ->> 'alvo', ''), 80));

  elsif p_kind = 'sleep_machine' then
    v_modo := lower(btrim(coalesce(p_params ->> 'modo', 'suspender')));

    -- Lista fechada. 'desligar' NÃO está aqui de propósito: desligar uma
    -- máquina remota sem WoL de S5 confirmado é criar uma visita à loja.
    if v_modo not in ('suspender', 'hibernar') then
      raise exception 'modo inválido: % (use suspender ou hibernar)', v_modo
        using errcode = 'MON07';
    end if;

    return jsonb_build_object('modo', v_modo);

  elsif p_kind in ('restart_machine', 'run_test_collection') then
    return '{}'::jsonb;
  end if;

  raise exception 'tipo de comando desconhecido: %', p_kind using errcode = 'MON07';
end
$fn$;

-- -----------------------------------------------------------------------------
-- Suspender não gasta a cota de reinício
-- -----------------------------------------------------------------------------
-- O cooldown de 30 min existe para impedir laço de reboot numa máquina que não
-- volta. Suspender é a operação NORMAL de fim de expediente numa loja, e
-- amarrá-la ao mesmo limite impediria o uso legítimo. O que a protege é a
-- confirmação e o limite de rajada por loja.
--
-- `enfileirar_comando` já separa os dois: o cooldown só olha
-- kind = 'restart_machine'. Este comentário existe porque a ausência de um
-- guardrail merece justificativa tanto quanto a presença dele.

-- -----------------------------------------------------------------------------
-- O painel precisa saber se acordar é viável antes de oferecer suspender
-- -----------------------------------------------------------------------------
-- Suspender uma máquina que não se sabe acordar é transformar um PC funcionando
-- num PC apagado a 900 km de distância. O painel só deve oferecer isto quando o
-- caminho de volta existe.
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
  v_acordou  boolean;
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

  if v_m.status <> 'online' and v_mac is not null then
    v_vizinho := public.vizinho_para_acordar(p_machine_id);
    if v_vizinho is not null then
      select label into v_nome_v from public.machines where id = v_vizinho;
    end if;
  end if;

  -- Já foi acordada alguma vez com sucesso? É a única evidência REAL de que o
  -- caminho de volta funciona nesta máquina — melhor que qualquer verificação
  -- de configuração, porque WoL só se prova acordando.
  select exists (
    select 1 from public.agent_commands c
    where c.kind = 'wake_machine'
      and not c.dry_run
      and c.result_ok
      and c.params ->> 'mac' = v_mac::text
  ) into v_acordou;

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
      'vizinho',   v_nome_v),

    -- Suspender só faz sentido com a máquina online, e só é seguro se houver
    -- como acordá-la: MAC conhecido e pelo menos um vizinho na loja.
    'suspender', jsonb_build_object(
      'aplicavel', v_m.status = 'online',
      'tem_mac',   v_mac is not null,
      'tem_vizinho', v_m.status = 'online'
                     and public.vizinho_para_acordar(p_machine_id) is not null,
      'ja_acordou', v_acordou),

    'reboot_liberado_em', case
      when v_ultimo is null then null
      when v_ultimo > now() - make_interval(mins => v_cooldown)
        then v_ultimo + make_interval(mins => v_cooldown)
      else null end
  );
end
$fn$;
