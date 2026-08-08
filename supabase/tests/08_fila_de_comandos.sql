-- =============================================================================
-- Teste 08 — a fila de comandos, de ponta a ponta
-- =============================================================================
-- O que precisa ser verdade:
--
--    1. um comando válido entra na fila como `pending`
--    2. serviço FORA da lista de críticos da máquina é RECUSADO
--    3. nome de serviço com metacaractere é RECUSADO (nada de shell livre)
--    4. `restart_machine` sem confirmação é RECUSADO
--    5. dois reinícios da mesma máquina dentro do cooldown: o segundo é RECUSADO
--    6. o limite de rajada por LOJA corta o excesso
--    7. o agente retira o comando com o token dela e ele vira `sent`
--    8. a máquina VIZINHA não recebe comando que não é dela
--    9. o resultado do agente fecha o comando e gera evento
--   10. comando não executado EXPIRA e para de ser entregue
--   11. o agente não fecha comando de OUTRA máquina
--
-- Os itens 5, 6 e 10 são o motivo deste arquivo. Sem 5, uma máquina que não
-- volta vira laço de reboot a noite inteira. Sem 6, o próprio monitoramento
-- vira o incidente. Sem 10, um comando de ontem executa hoje, sobre um estado
-- que ninguém mais conhece.
-- =============================================================================

\set ON_ERROR_STOP on

do $$
declare
  v_brand   uuid;
  v_site    uuid;
  v_maq     uuid;
  v_vizinha uuid;
  v_cod     text := 'ZZCMD';
  v_tok     text;
  v_tok_viz text;
  v_r       jsonb;
  v_id      uuid;
  v_status  text;
  v_n       integer;
  v_limite  integer := public.app_setting_int('command_site_burst_limit');
  v_cortou  boolean;
  v_admin   uuid := '44444444-4444-4444-8444-444444444444';
begin
  -- Em psql não há JWT, então auth.uid() é nulo e nada que exija admin passa.
  -- Simula a sessão do painel: é por ela que os comandos entram de verdade, e
  -- testar por um atalho deixaria a autorização sem cobertura nenhuma.
  delete from public.user_roles where user_id = v_admin;
  insert into public.user_roles (user_id, role, note) values (v_admin, 'admin', 'teste 08');
  perform set_config('request.jwt.claim.sub', v_admin::text, true);

  -- ------------------------------------------------------------------ cenário
  delete from public.machines where label in ('PC-CMD', 'PC-CMD-VIZINHA');
  delete from public.sites  where code = v_cod;
  delete from public.brands where code = v_cod;

  insert into public.brands (code, name) values (v_cod, 'comandos') returning id into v_brand;
  insert into public.sites (brand_id, code, name) values (v_brand, v_cod, 'loja comandos')
  returning id into v_site;

  -- O perfil 'pdv' já declara os serviços críticos; um override torna o teste
  -- independente de qual seja o padrão do perfil.
  insert into public.machines (site_id, role_code, label, critical_services_override, last_seen_at)
  values (v_site, 'pdv', 'PC-CMD', array['Spooler', 'MSSQLSERVER'], now())
  returning id into v_maq;

  insert into public.machines (site_id, role_code, label, critical_services_override, last_seen_at)
  values (v_site, 'pdv', 'PC-CMD-VIZINHA', array['Spooler'], now())
  returning id into v_vizinha;

  select t.token into v_tok     from public.issue_agent_token(v_maq, 'teste 08') t;
  select t.token into v_tok_viz from public.issue_agent_token(v_vizinha, 'teste 08') t;

  -- ------------------------------------------------ 1. comando válido entra
  v_r := public.enfileirar_comando(v_maq, 'restart_service',
                                   '{"servico":"Spooler"}'::jsonb,
                                   false, false, null, 'painel');
  v_id := (v_r ->> 'command_id')::uuid;

  select status into v_status from public.agent_commands where id = v_id;
  if v_status is distinct from 'pending' then
    raise exception 'FALHA 1: comando valido nao ficou pending (esta %)', v_status;
  end if;

  if not exists (select 1 from public.events
                 where kind = 'command_queued' and payload ->> 'command_id' = v_id::text) then
    raise exception 'FALHA 1: enfileirar nao gerou evento de auditoria';
  end if;

  -- ------------------------------- 2. serviço fora da lista da máquina: não
  begin
    perform public.enfileirar_comando(v_maq, 'restart_service',
                                      '{"servico":"Fax"}'::jsonb,
                                      false, false, null, 'painel');
    raise exception 'FALHA 2: aceitou reiniciar servico que a maquina nao vigia';
  exception when sqlstate 'MON07' then
    null;  -- esperado
  end;

  -- ------------------------------------- 3. metacaractere de shell: recusado
  -- Se isto passar, o painel vira execução remota arbitrária.
  begin
    perform public.enfileirar_comando(v_maq, 'restart_service',
                                      '{"servico":"Spooler & shutdown /r"}'::jsonb,
                                      false, false, null, 'painel');
    raise exception 'FALHA 3: aceitou nome de servico com metacaractere de shell';
  exception when sqlstate 'MON07' then
    null;
  end;

  -- ----------------------------- 4. destrutivo sem confirmação: recusado
  begin
    perform public.enfileirar_comando(v_maq, 'restart_machine', '{}'::jsonb,
                                      false, false, null, 'painel');
    raise exception 'FALHA 4: reiniciou a maquina sem confirmacao explicita';
  exception when sqlstate 'MON08' then
    null;
  end;

  -- ---------------- 4b. e automação NÃO reinicia máquina nem com confirmação
  -- A confirmação é um gesto humano. Um playbook passar `p_confirmado = true`
  -- não torna o gesto humano; se isso passasse, a exigência do item 4 seria
  -- contornável por qualquer automação.
  begin
    perform public.enfileirar_comando(v_maq, 'restart_machine', '{}'::jsonb,
                                      false, true, null, 'playbook');
    raise exception 'FALHA 4b: automacao reiniciou maquina sem autorizacao explicita';
  exception when sqlstate 'MON09' then
    null;
  end;

  -- ------------------------------------ 5. GUARDRAIL: cooldown de reinício
  perform public.enfileirar_comando(v_maq, 'restart_machine', '{}'::jsonb,
                                    false, true, null, 'painel');

  -- Fecha o primeiro, senão o que barra o segundo é a trava de duplicata (item
  -- do enfileirar) e não o cooldown — e o teste passaria pelo motivo errado.
  update public.agent_commands
     set status = 'succeeded', finished_at = now(), result_ok = true
   where machine_id = v_maq and kind = 'restart_machine';

  begin
    perform public.enfileirar_comando(v_maq, 'restart_machine', '{}'::jsonb,
                                      false, true, null, 'painel');
    raise exception 'FALHA 5: aceitou dois reinicios da mesma maquina dentro do cooldown';
  exception when sqlstate 'MON02' then
    null;
  end;

  -- --------------------------------------- 6. GUARDRAIL: rajada por loja
  -- Já existem 2 comandos nesta loja. O limite é 10; enche até bater.
  -- `run_test_collection` não tem cooldown nem parâmetro, então o único
  -- guardrail que pode barrar é a rajada.
  -- Tenta MUITO mais que o limite configurado. Comparar o resultado com o
  -- próprio setting tornaria a asserção vazia: ela passaria com o limite em
  -- 9999, que é o mesmo que não ter limite.
  v_cortou := false;
  for v_n in 1..(v_limite * 3) loop
    begin
      perform public.enfileirar_comando(v_maq, 'run_test_collection', '{}'::jsonb,
                                        false, false, null, 'painel');
      -- libera a trava de duplicata para o próximo da rajada
      update public.agent_commands set status = 'succeeded', finished_at = now(), result_ok = true
       where machine_id = v_maq and kind = 'run_test_collection' and status = 'pending';
    exception when sqlstate 'MON02' then
      v_cortou := true;
      exit;
    end;
  end loop;

  if not v_cortou then
    raise exception 'FALHA 6: a loja enfileirou % comandos sem a rajada cortar', v_limite * 3;
  end if;

  select count(*) into v_n from public.agent_commands
  where site_id = v_site and created_at > now() - interval '10 minutes';

  if v_n > v_limite then
    raise exception 'FALHA 6: a loja ficou com % comandos, acima do limite de %', v_n, v_limite;
  end if;

  -- ------------------------------------------ 7. o agente retira o comando
  -- Limpa a loja para sair da rajada e poder enfileirar o caso de estudo.
  delete from public.agent_commands where site_id = v_site;

  v_r := public.enfileirar_comando(v_maq, 'restart_service',
                                   '{"servico":"MSSQLSERVER"}'::jsonb,
                                   false, false, null, 'painel');
  v_id := (v_r ->> 'command_id')::uuid;

  v_r := public.agente_sincronizar(v_tok, '[]'::jsonb);

  if jsonb_array_length(v_r -> 'comandos') <> 1 then
    raise exception 'FALHA 7: o agente recebeu % comandos, esperava 1',
      jsonb_array_length(v_r -> 'comandos');
  end if;

  if (v_r -> 'comandos' -> 0 ->> 'command_id') is distinct from v_id::text then
    raise exception 'FALHA 7: o agente recebeu um comando que nao e o enfileirado';
  end if;

  select status into v_status from public.agent_commands where id = v_id;
  if v_status is distinct from 'sent' then
    raise exception 'FALHA 7: comando retirado nao virou sent (esta %)', v_status;
  end if;

  -- Retirar de novo não pode entregar o mesmo comando duas vezes.
  v_r := public.agente_sincronizar(v_tok, '[]'::jsonb);
  if jsonb_array_length(v_r -> 'comandos') <> 0 then
    raise exception 'FALHA 7: o mesmo comando foi entregue duas vezes';
  end if;

  -- ------------------------------------------- 8. a vizinha não recebe nada
  v_r := public.agente_sincronizar(v_tok_viz, '[]'::jsonb);
  if jsonb_array_length(v_r -> 'comandos') <> 0 then
    raise exception 'FALHA 8: a maquina vizinha recebeu comando que nao e dela';
  end if;

  -- ------------------------------- 11. e não fecha comando de outra máquina
  perform public.agente_sincronizar(v_tok_viz,
    jsonb_build_array(jsonb_build_object('command_id', v_id, 'ok', true, 'texto', 'nao fui eu')));

  select status into v_status from public.agent_commands where id = v_id;
  if v_status is distinct from 'sent' then
    raise exception 'FALHA 11: a vizinha fechou comando de outra maquina (virou %)', v_status;
  end if;

  -- ------------------------------------------------- 9. o resultado fecha
  v_r := public.agente_sincronizar(v_tok, jsonb_build_array(
    jsonb_build_object('command_id', v_id, 'ok', true,
                       'texto', 'servico MSSQLSERVER reiniciado')));

  select status into v_status from public.agent_commands where id = v_id;
  if v_status is distinct from 'succeeded' then
    raise exception 'FALHA 9: resultado ok nao fechou o comando (esta %)', v_status;
  end if;

  if not exists (select 1 from public.events
                 where kind = 'command_result' and payload ->> 'command_id' = v_id::text) then
    raise exception 'FALHA 9: o resultado nao gerou evento';
  end if;

  -- ------------------------------------------------ 10. GUARDRAIL: expira
  -- Um comando que a loja nunca retirou porque estava offline.
  delete from public.agent_commands where site_id = v_site;

  v_r := public.enfileirar_comando(v_maq, 'clear_temp', '{"dias_minimos":30}'::jsonb,
                                   false, false, null, 'painel');
  v_id := (v_r ->> 'command_id')::uuid;

  -- Envelhece: é o equivalente a a loja ter passado a noite desligada.
  update public.agent_commands
     set not_before = now() - interval '2 hours',
         expires_at = now() - interval '1 hour'
   where id = v_id;

  perform public.expirar_comandos();

  select status into v_status from public.agent_commands where id = v_id;
  if v_status is distinct from 'expired' then
    raise exception 'FALHA 10: comando vencido nao expirou (esta %)', v_status;
  end if;

  -- E o principal: expirado NÃO pode ser entregue.
  v_r := public.agente_sincronizar(v_tok, '[]'::jsonb);
  if jsonb_array_length(v_r -> 'comandos') <> 0 then
    raise exception 'FALHA 10: comando EXPIRADO foi entregue ao agente';
  end if;

  if not exists (select 1 from public.events
                 where kind = 'command_expired' and payload ->> 'command_id' = v_id::text) then
    raise exception 'FALHA 10: a expiracao nao gerou evento';
  end if;

  -- ------------------------------------------------------------------ limpa
  delete from public.events where site_id = v_site;
  delete from public.machines where id in (v_maq, v_vizinha);
  delete from public.sites where id = v_site;
  delete from public.brands where id = v_brand;
  delete from public.user_roles where user_id = v_admin;

  raise notice 'TESTE 08 OK — fila de comandos, guardrails e expiracao';
end
$$;
