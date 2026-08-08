-- =============================================================================
-- Teste 09 — ligar um PC desligado pelo vizinho (Wake-on-LAN)
-- =============================================================================
-- O que precisa ser verdade:
--
--   1. o agente reporta o MAC e ele fica gravado
--   2. MAC malformado NÃO derruba o ciclo de telemetria
--   3. máquina sem MAC não pode ser ligada, e a mensagem diz por quê
--   4. máquina já online não aceita "ligar"
--   5. sem NENHUM vizinho online na loja, recusa — e explica que o pacote tem
--      que sair de dentro da loja
--   6. vizinho com agente ANTIGO não serve (ele não sabe executar o comando)
--   7. vizinho de OUTRA loja nunca é escolhido
--   8. com vizinho válido, o comando vai para o VIZINHO, não para o alvo
--   9. e ele carrega o MAC do ALVO
--
-- O item 8 é a razão deste arquivo. A inversão de alvo é a parte fácil de
-- errar: o operador escolhe a máquina desligada, mas o comando tem que ir para
-- outra. Enfileirar para o alvo seria enfileirar para ninguém, e o comando
-- ficaria esperando até expirar sem nada acontecer.
--
-- O item 7 é o que impede o pior caso: um PC em Brasília tentando acordar um PC
-- em São Paulo com um pacote que não sai da rede local.
-- =============================================================================

\set ON_ERROR_STOP on

do $$
declare
  v_brand   uuid;
  v_site    uuid;
  v_outra   uuid;
  v_alvo    uuid;
  v_viz     uuid;
  v_velho   uuid;
  v_longe   uuid;
  v_cod     text := 'ZZWOL';
  v_cod2    text := 'ZZWOL2';
  v_tok     text;
  v_r       jsonb;
  v_admin   uuid := '66666666-6666-4666-8666-666666666666';
  v_mac     text;
  v_dono    uuid;
begin
  delete from public.machines where label like 'PC-WOL%';
  delete from public.sites  where code in (v_cod, v_cod2);
  delete from public.brands where code = v_cod;
  delete from public.user_roles where user_id = v_admin;

  insert into public.user_roles (user_id, role, note) values (v_admin, 'admin', 'teste 09');
  perform set_config('request.jwt.claim.sub', v_admin::text, true);

  insert into public.brands (code, name) values (v_cod, 'wol') returning id into v_brand;
  insert into public.sites (brand_id, code, name) values (v_brand, v_cod, 'loja wol')
  returning id into v_site;
  insert into public.sites (brand_id, code, name) values (v_brand, v_cod2, 'loja distante')
  returning id into v_outra;

  -- O alvo: DESLIGADO (sem last_seen recente).
  insert into public.machines (site_id, role_code, label, last_seen_at, agent_version)
  values (v_site, 'pdv', 'PC-WOL-ALVO', now() - interval '2 hours', 'ps-1.3.0')
  returning id into v_alvo;

  -- ------------------------------------------------- 1. o MAC chega e grava
  insert into public.machines (site_id, role_code, label, last_seen_at, agent_version)
  values (v_site, 'pdv', 'PC-WOL-VIZINHO', now(), 'ps-1.3.0')
  returning id into v_viz;

  select t.token into v_tok from public.issue_agent_token(v_viz, 'teste 09') t;

  perform public.agente_sincronizar(v_tok, '[]'::jsonb, '{"mac":"AA:BB:CC:11:22:33"}'::jsonb);

  select mac_address::text into v_mac from public.machines where id = v_viz;
  if v_mac is distinct from 'aa:bb:cc:11:22:33' then
    raise exception 'FALHA 1: o MAC nao foi gravado (esta %)', coalesce(v_mac, '(nulo)');
  end if;

  -- ------------------------------------ 2. MAC podre nao derruba o ciclo
  -- A telemetria e a funcao que o sistema nao pode perder. Um adaptador exotico
  -- devolvendo lixo nao pode cegar a loja.
  begin
    v_r := public.agente_sincronizar(v_tok, '[]'::jsonb, '{"mac":"nao-e-um-mac"}'::jsonb);
  exception when others then
    raise exception 'FALHA 2: MAC malformado derrubou o ciclo: %', sqlerrm;
  end;

  if (v_r ->> 'ok')::boolean is not true then
    raise exception 'FALHA 2: o ciclo nao respondeu ok com MAC malformado';
  end if;

  select mac_address::text into v_mac from public.machines where id = v_viz;
  if v_mac is distinct from 'aa:bb:cc:11:22:33' then
    raise exception 'FALHA 2: o MAC bom foi sobrescrito por lixo (esta %)', v_mac;
  end if;

  -- ------------------------------------------- 3. alvo sem MAC nao liga
  begin
    perform public.ligar_maquina(v_alvo);
    raise exception 'FALHA 3: aceitou ligar maquina sem MAC conhecido';
  exception when sqlstate 'MON07' then
    null;
  end;

  -- Agora o alvo tem MAC (como se ja tivesse reportado quando estava ligado).
  update public.machines set mac_address = 'de:ad:be:ef:00:01' where id = v_alvo;

  -- ------------------------------------------- 4. maquina online nao liga
  begin
    perform public.ligar_maquina(v_viz);
    raise exception 'FALHA 4: aceitou ligar uma maquina que ja esta online';
  exception when sqlstate 'MON07' then
    null;
  end;

  -- ------------------------------------ 5/6/7. quem NAO serve de vizinho
  -- Derruba o unico vizinho bom e monta os candidatos ruins.
  update public.machines set last_seen_at = now() - interval '3 hours' where id = v_viz;

  -- agente antigo, online, mesma loja: nao sabe executar comando
  insert into public.machines (site_id, role_code, label, last_seen_at, agent_version)
  values (v_site, 'pdv', 'PC-WOL-VELHO', now(), 'ps-1.1.0')
  returning id into v_velho;

  -- agente novo e online, mas de OUTRA loja: o pacote nao sai da rede local
  insert into public.machines (site_id, role_code, label, last_seen_at, agent_version)
  values (v_outra, 'pdv', 'PC-WOL-LONGE', now(), 'ps-1.3.0')
  returning id into v_longe;

  if public.vizinho_para_acordar(v_alvo) is not null then
    raise exception 'FALHA 6/7: escolheu vizinho invalido (agente antigo ou de outra loja)';
  end if;

  begin
    perform public.ligar_maquina(v_alvo);
    raise exception 'FALHA 5: aceitou ligar sem nenhum vizinho capaz na loja';
  exception when sqlstate 'MON02' then
    null;
  end;

  -- ------------------------------------ 8/9. com vizinho bom, funciona
  update public.machines set last_seen_at = now() where id = v_viz;

  if public.vizinho_para_acordar(v_alvo) is distinct from v_viz then
    raise exception 'FALHA 8: nao escolheu o vizinho valido';
  end if;

  v_r := public.ligar_maquina(v_alvo);

  select machine_id into v_dono from public.agent_commands
  where kind = 'wake_machine' and site_id = v_site;

  if v_dono is distinct from v_viz then
    raise exception 'FALHA 8: o comando foi para a maquina errada (esperava o vizinho)';
  end if;

  if v_dono = v_alvo then
    raise exception 'FALHA 8: o comando foi para a maquina DESLIGADA';
  end if;

  select params ->> 'mac' into v_mac from public.agent_commands
  where kind = 'wake_machine' and site_id = v_site;

  if v_mac is distinct from 'de:ad:be:ef:00:01' then
    raise exception 'FALHA 9: o comando nao leva o MAC do ALVO (leva %)', coalesce(v_mac,'(nulo)');
  end if;

  if (v_r ->> 'alvo') is distinct from 'PC-WOL-ALVO'
     or (v_r ->> 'vizinho') is distinct from 'PC-WOL-VIZINHO' then
    raise exception 'FALHA 9: a resposta nao diz corretamente quem acorda quem: %', v_r;
  end if;

  -- ------------------------------- 9b. Wi-Fi não pode ser acordado
  -- WoL sobre Wi-Fi depende do adaptador E do ponto de acesso, e quase nunca
  -- funciona. Oferecer "Ligar o PC" para uma máquina em Wi-Fi é uma promessa
  -- que só se descobre falsa dentro da loja.
  update public.machines set mac_is_wifi = true where id = v_alvo;

  begin
    perform public.ligar_maquina(v_alvo);
    raise exception 'FALHA 9b: aceitou acordar uma maquina em Wi-Fi';
  exception when sqlstate 'MON07' then
    null;
  end;

  if (public.acoes_da_maquina(v_alvo) -> 'ligar' ->> 'wifi')::boolean is not true then
    raise exception 'FALHA 9b: o painel nao informa que o impedimento e o Wi-Fi';
  end if;

  -- De volta ao cabo, para o resto do teste.
  update public.machines set mac_is_wifi = false where id = v_alvo;

  -- ------------------- 10. suspender só quando existe caminho de volta
  -- Suspender uma máquina que não se sabe acordar é transformar um PC
  -- funcionando num PC apagado a 900 km. O painel só pode oferecer isso quando
  -- as duas pontas existem: MAC conhecido E vizinho capaz na loja.
  declare
    v_a jsonb;
  begin
    -- O vizinho está online; o alvo está offline. Para o VIZINHO, suspender
    -- deveria ser possível: ele tem MAC e tem quem o acorde? Não — o único
    -- outro capaz seria o alvo, que está desligado.
    v_a := public.acoes_da_maquina(v_viz);

    if (v_a -> 'suspender' ->> 'aplicavel')::boolean is not true then
      raise exception 'FALHA 10: suspender nao foi oferecido para maquina online';
    end if;

    if (v_a -> 'suspender' ->> 'tem_vizinho')::boolean is not false then
      raise exception 'FALHA 10: ofereceu suspender sem NINGUEM para acordar depois';
    end if;

    -- Agora sobe o alvo: passa a existir caminho de volta para o vizinho.
    update public.machines set last_seen_at = now(), mac_address = 'de:ad:be:ef:00:02'
     where id = v_alvo;

    v_a := public.acoes_da_maquina(v_viz);

    if (v_a -> 'suspender' ->> 'tem_vizinho')::boolean is not true then
      raise exception 'FALHA 10: com vizinho online, suspender continuou bloqueado';
    end if;

    -- E para maquina OFFLINE nao se oferece suspender: ela ja esta apagada.
    v_a := public.acoes_da_maquina(v_viz);
    update public.machines set last_seen_at = now() - interval '3 hours' where id = v_viz;
    v_a := public.acoes_da_maquina(v_viz);

    if (v_a -> 'suspender' ->> 'aplicavel')::boolean is not false then
      raise exception 'FALHA 10: ofereceu suspender para maquina que ja esta offline';
    end if;
  end;

  -- ------------------------------------------------------------------ limpa
  delete from public.events where site_id in (v_site, v_outra);
  delete from public.machines where id in (v_alvo, v_viz, v_velho, v_longe);
  delete from public.sites where id in (v_site, v_outra);
  delete from public.brands where id = v_brand;
  delete from public.user_roles where user_id = v_admin;

  raise notice 'TESTE 09 OK — ligar pelo vizinho, com os limites certos';
end
$$;
