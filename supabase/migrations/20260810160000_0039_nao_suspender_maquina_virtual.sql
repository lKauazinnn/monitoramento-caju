-- =============================================================================
-- 0039 — Não suspender o que não se consegue acordar
-- =============================================================================
-- A 0037 recusou Wake-on-LAN para máquina virtual: com a VM desligada a placa de
-- rede não existe, e não há o que receber o pacote mágico.
--
-- E eu deixei SUSPENDER liberado nas mesmas máquinas.
--
-- Isso é pior que os dois problemas separados. O painel oferece um botão que
-- desliga a VM, e logo em seguida recusa o único botão que a traria de volta. Uma
-- pessoa suspende o servidor de uma loja pelo painel, à noite, e descobre na
-- manhã seguinte que precisa do console do hipervisor para levantá-lo — sendo que
-- o painel foi quem a colocou nessa situação.
--
-- Guardrail bom não é o que impede a ação perigosa; é o que impede a combinação
-- perigosa. Suspender é reversível numa máquina física, porque WoL a acorda. Na
-- virtual, suspender é um caminho de mão única disfarçado de operação reversível.
--
-- REINICIAR CONTINUA LIBERADO, e a diferença é o que importa: reiniciar é
-- executado pelo agente de dentro do Windows e a máquina volta sozinha. Não
-- depende de ninguém acordá-la de fora.
-- =============================================================================

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
  v_mac_maquina macaddr;
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

    -- 0039: o MAC vem da MÁQUINA, não dos parâmetros. Suspender não recebe MAC
    -- (não precisa dele para agir), então a checagem tem que buscá-lo — e é
    -- justamente por não receber que essa combinação passou batido na 0037.
    select m.mac_address into v_mac_maquina
    from public.machines m where m.id = p_machine_id;

    if v_mac_maquina is not null and public.mac_e_virtual(v_mac_maquina) then
      raise exception
        'esta máquina é virtual: suspender é caminho sem volta aqui. Wake-on-LAN '
        'não acorda VM (a placa de rede não existe com ela desligada), então ela '
        'só voltaria pelo console do hipervisor. Para aplicar atualização ou '
        'liberar memória, use REINICIAR: o agente executa de dentro e a máquina '
        'volta sozinha.'
        using errcode = 'MON07',
              hint = 'Reiniciar não depende de ninguém acordar a máquina de fora.';
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
    -- REINICIAR NÃO É BLOQUEADO EM VM, e isso é deliberado. O agente executa de
    -- dentro do Windows e a máquina volta sozinha; não há dependência de acordar
    -- nada de fora. É a operação certa para VM.
    return '{}'::jsonb;
  end if;

  raise exception 'tipo de comando desconhecido: %', p_kind using errcode = 'MON07';
end
$fn$;
