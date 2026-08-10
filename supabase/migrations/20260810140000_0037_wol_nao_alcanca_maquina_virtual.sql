-- =============================================================================
-- 0037 — Wake-on-LAN não alcança máquina virtual
-- =============================================================================
-- Quatro máquinas da loja CBO-S receberam "pacote mágico enviado em 2 destino(s)"
-- e não ligaram. O painel não mentiu: o pacote saiu de verdade. Ele só não tinha
-- para onde chegar.
--
-- Os MACs delas:
--
--   92:17:90:fb:50:6a    CBO CAMINITO
--   0a:e0:af:c2:04:7b    CBO FOSTERS
--   92:6a:77:ec:04:e7    CBO-CAJU
--   0a:e0:af:a2:00:ed    NAZO-CBO
--
-- O bit 0x02 do primeiro octeto está ligado em todos. Esse é o bit
-- "locally administered": endereço atribuído por software, não gravado em placa
-- pela fábrica. Toda máquina física da frota tem OUI de fabricante e esse bit em
-- zero (00:e0:1e Realtek, d8:cb:8a Intel, c8:1f:66 Dell, 68:1d:ef, 64:1c:67).
--
-- POR QUE WoL NÃO PODE FUNCIONAR NELAS: com a VM desligada, a placa de rede
-- virtual não existe — o hipervisor a desalocou junto com a máquina. Não há
-- hardware num estado de baixo consumo esperando um quadro Ethernet. WoL depende
-- de uma placa física alimentada com a máquina desligada, e isso é exatamente o
-- que uma VM não tem. Elas se ligam pela API do provedor.
--
-- Oferecer o botão aqui é pior que não ter botão: a pessoa clica, recebe uma
-- confirmação verdadeira ("enviado"), espera dois minutos, e não entende. Foi o
-- que aconteceu — três vezes, em três máquinas.
--
-- A recusa entra em `validar_comando`, e não na tela: é o ponto único por onde
-- TODO wake_machine passa, venha do painel, da automação ou de um script futuro.
-- Guardar a regra na interface deixaria os outros caminhos sem ela.
--
-- FALSO POSITIVO CONHECIDO, dito em voz alta: máquina física cujo MAC foi trocado
-- à mão, e placa de rede agregada (teaming) também usam endereço localmente
-- administrado. Se aparecer uma dessas, o WoL dela vai ser recusado e a mensagem
-- vai explicar o motivo — melhor que a situação atual, em que a pessoa recebe
-- "enviado" e fica esperando.
-- =============================================================================

create or replace function public.mac_e_virtual(p_mac macaddr)
returns boolean
language sql
immutable
as $fn$
  -- Primeiro octeto do MAC, bit 0x02. `trunc()` do tipo macaddr zera os últimos
  -- três octetos e deixa o OUI, mas nao da acesso ao byte; o caminho honesto e
  -- ler o texto, que é estável para macaddr (sempre 'xx:xx:xx:xx:xx:xx').
  select case
           when p_mac is null then false
           else (('x' || substr(p_mac::text, 1, 2))::bit(8) & b'00000010') <> b'00000000'
         end
$fn$;

comment on function public.mac_e_virtual(macaddr) is
  'MAC atribuido por software (bit locally administered). Maquina virtual, VPS ou '
  'placa agregada. Wake-on-LAN nao alcanca: sem placa fisica, nao ha quem escute.';

revoke all on function public.mac_e_virtual(macaddr) from public;
grant execute on function public.mac_e_virtual(macaddr) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- validar_comando — idêntica à 0031, com a recusa de MAC virtual
-- -----------------------------------------------------------------------------
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

    -- 0037: recusa antes de enfileirar. Ver o cabeçalho.
    if public.mac_e_virtual(v_mac::macaddr) then
      raise exception
        'esta máquina é virtual (MAC % atribuído por software): Wake-on-LAN não '
        'alcança. Com a VM desligada a placa de rede não existe, então não há o '
        'que receber o pacote. Ligue pelo painel do provedor ou pelo hipervisor.',
        v_mac
        using errcode = 'MON07',
              hint = 'Máquina física tem MAC de fabricante; virtual tem o bit 0x02 no primeiro octeto.';
    end if;

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
-- O painel precisa poder DESABILITAR o botão, não só receber o erro
-- -----------------------------------------------------------------------------
-- `mac_is_wifi` já existia na view por essa mesma razão: dizer QUAL é o
-- impedimento em vez de só recusar. `mac_is_virtual` entra ao lado.
alter table public.machines add column if not exists mac_is_virtual boolean;

comment on column public.machines.mac_is_virtual is
  'Derivado de mac_address na ingestao: MAC atribuido por software. Wake-on-LAN nao alcanca.';

update public.machines
   set mac_is_virtual = public.mac_e_virtual(mac_address)
 where mac_address is not null
   and (mac_is_virtual is null or mac_is_virtual <> public.mac_e_virtual(mac_address));
