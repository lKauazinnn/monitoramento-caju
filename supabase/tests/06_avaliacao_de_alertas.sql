-- =============================================================================
-- Teste 06 — avaliação de alertas
-- =============================================================================
-- O que precisa ser verdade, e nada disso se verifica lendo o código:
--
--   1. UMA leitura acima do limiar NÃO abre alerta (é ruído)
--   2. N leituras seguidas ABREM
--   3. avaliar de novo NÃO duplica o evento
--   4. a condição se desfazendo por N ciclos RESOLVE e gera aviso de recuperação
--   5. o cooldown impede reabrir logo em seguida
--   6. a regra MAIS ESPECÍFICA vence (uma regra por máquina e tipo)
--   7. máquina em manutenção não gera alerta
--
-- PADRÃO DE NEGAÇÃO: `raise exception 'FALHA'` dentro de bloco com
-- `exception when others` é engolido pelo próprio handler. Aqui não há handler
-- em volta das asserções, então elas abortam de verdade.
-- =============================================================================

\set ON_ERROR_STOP on

do $$
declare
  v_brand  uuid;
  v_site   uuid;
  v_maq    uuid;
  v_regra  uuid;
  v_ciclos integer;
  v_res    jsonb;
  v_abertos integer;
  v_recup  integer;
  v_cod    text := 'ZZALERTA';
begin
  -- ------------------------------------------------------------------ alvo
  delete from public.machines where label = 'PC-ALERTA';
  delete from public.sites where code = v_cod;
  delete from public.brands where code = v_cod;
  delete from public.alert_rules where name like 'TESTE-06%';

  insert into public.brands (code, name) values (v_cod, 'teste alerta') returning id into v_brand;
  insert into public.sites (brand_id, code, name) values (v_brand, v_cod, 'loja alerta') returning id into v_site;
  insert into public.machines (site_id, role_code, label, hostname)
  values (v_site, 'pdv', 'PC-ALERTA', 'HOST-ALERTA') returning id into v_maq;

  -- Regra de CPU só para esta máquina, com 3 ciclos e cooldown de 30 min.
  insert into public.alert_rules (name, kind, scope, machine_id, threshold, comparator,
                                  consecutive_cycles, cooldown_minutes, severity)
  values ('TESTE-06 cpu', 'cpu_sustained', 'machine', v_maq, 90, '>', 3, 30, 'warning')
  returning id, consecutive_cycles into v_regra, v_ciclos;

  raise notice 'alvo criado: PC-ALERTA, regra de CPU > 90 por % ciclos', v_ciclos;

  -- ------------------------------------------------- 1. uma leitura nao abre
  insert into public.metrics (machine_id, "time", agent_version, cpu_pct, mem_pct)
  values (v_maq, now(), 'teste', 99, 40);
  update public.machines set last_seen_at = now() where id = v_maq;

  perform public.avaliar_alertas();

  select count(*) into v_abertos from public.events
  where machine_id = v_maq and rule_id = v_regra and kind = 'alert_open' and resolved_at is null;

  if v_abertos <> 0 then
    raise exception 'FALHA: uma unica leitura acima do limiar abriu alerta (histerese nao funciona)';
  end if;
  raise notice '1. uma leitura a 99%% -> nenhum alerta (ok)';

  -- ------------------------------------------------- 2. N leituras abrem
  insert into public.metrics (machine_id, "time", agent_version, cpu_pct, mem_pct)
  values (v_maq, now() + interval '1 minute', 'teste', 97, 41),
         (v_maq, now() + interval '2 minutes', 'teste', 95, 42);

  perform public.avaliar_alertas();

  select count(*) into v_abertos from public.events
  where machine_id = v_maq and rule_id = v_regra and kind = 'alert_open' and resolved_at is null;

  if v_abertos <> 1 then
    raise exception 'FALHA: com % leituras seguidas acima do limiar, esperava 1 alerta aberto, tem %',
      v_ciclos, v_abertos;
  end if;
  raise notice '2. tres leituras seguidas -> 1 alerta aberto (ok)';

  -- ------------------------------------------------- 3. nao duplica
  perform public.avaliar_alertas();
  perform public.avaliar_alertas();

  select count(*) into v_abertos from public.events
  where machine_id = v_maq and rule_id = v_regra and kind = 'alert_open' and resolved_at is null;

  if v_abertos <> 1 then
    raise exception 'FALHA: avaliar de novo duplicou o evento (% abertos)', v_abertos;
  end if;
  raise notice '3. avaliar tres vezes -> continua 1 aberto (ok)';

  -- ------------------------------------------------- 4. resolve e avisa
  insert into public.metrics (machine_id, "time", agent_version, cpu_pct, mem_pct)
  values (v_maq, now() + interval '3 minutes', 'teste', 10, 40),
         (v_maq, now() + interval '4 minutes', 'teste', 11, 40),
         (v_maq, now() + interval '5 minutes', 'teste', 12, 40);

  perform public.avaliar_alertas();

  select count(*) into v_abertos from public.events
  where machine_id = v_maq and rule_id = v_regra and kind = 'alert_open' and resolved_at is null;
  select count(*) into v_recup from public.events
  where machine_id = v_maq and rule_id = v_regra and kind = 'alert_recovered';

  if v_abertos <> 0 then
    raise exception 'FALHA: condicao desfeita e o alerta continua aberto';
  end if;
  if v_recup <> 1 then
    raise exception 'FALHA: nao gerou aviso de recuperacao (tem %)', v_recup;
  end if;
  raise notice '4. tres leituras limpas -> resolvido + aviso de recuperacao (ok)';

  -- ------------------------------------------------- 5. cooldown
  insert into public.metrics (machine_id, "time", agent_version, cpu_pct, mem_pct)
  values (v_maq, now() + interval '6 minutes', 'teste', 99, 40),
         (v_maq, now() + interval '7 minutes', 'teste', 98, 40),
         (v_maq, now() + interval '8 minutes', 'teste', 97, 40);

  perform public.avaliar_alertas();

  select count(*) into v_abertos from public.events
  where machine_id = v_maq and rule_id = v_regra and kind = 'alert_open' and resolved_at is null;

  if v_abertos <> 0 then
    raise exception 'FALHA: reabriu dentro do cooldown de 30 min (% abertos)', v_abertos;
  end if;
  raise notice '5. volta a violar dentro do cooldown -> nao reabre (ok)';

  -- Fora do cooldown, reabre: o cooldown segura, nao silencia para sempre.
  --
  -- Empurra opened_at JUNTO. O CHECK events_resolved_ck exige
  -- `resolved_at >= opened_at`, e mexer so no fechamento criaria um evento que
  -- terminou antes de comecar — a restricao esta certa, e pegou o teste.
  update public.events
     set opened_at   = now() - interval '3 hours',
         resolved_at = now() - interval '2 hours'
   where machine_id = v_maq and rule_id = v_regra and resolved_at is not null;

  perform public.avaliar_alertas();

  select count(*) into v_abertos from public.events
  where machine_id = v_maq and rule_id = v_regra and kind = 'alert_open' and resolved_at is null;

  if v_abertos <> 1 then
    raise exception 'FALHA: passado o cooldown, deveria reabrir (tem % abertos)', v_abertos;
  end if;
  raise notice '5b. passado o cooldown -> reabre (ok)';

  -- ------------------------------------------------- 7. manutencao silencia
  -- `in_maintenance` NAO e coluna: a view a deriva de `maintenance_until > now()`.
  -- Declarar a manutencao e definir ate quando ela vale, e nao marcar um sinal
  -- que alguem teria de lembrar de desligar depois.
  update public.machines set maintenance_until = now() + interval '1 hour',
         maintenance_reason = 'teste 06' where id = v_maq;

  -- Resolve o que estava aberto e limpa, para partir do zero. De novo:
  -- opened_at junto, senao o evento fecharia antes de abrir.
  update public.events
     set opened_at   = now() - interval '4 hours',
         resolved_at = now() - interval '3 hours'
   where machine_id = v_maq and resolved_at is null;

  insert into public.metrics (machine_id, "time", agent_version, cpu_pct, mem_pct)
  values (v_maq, now() + interval '9 minutes', 'teste', 99, 40),
         (v_maq, now() + interval '10 minutes', 'teste', 99, 40),
         (v_maq, now() + interval '11 minutes', 'teste', 99, 40);

  perform public.avaliar_alertas();

  select count(*) into v_abertos from public.events
  where machine_id = v_maq and rule_id = v_regra and kind = 'alert_open' and resolved_at is null;

  if v_abertos <> 0 then
    raise exception 'FALHA: abriu alerta em maquina em MANUTENCAO declarada';
  end if;
  raise notice '7. maquina em manutencao -> nao abre alerta (ok)';

  update public.machines set maintenance_until = null, maintenance_reason = null where id = v_maq;

  -- ------------------------------------------------- limpeza
  delete from public.machines where id = v_maq;
  delete from public.sites where id = v_site;
  delete from public.brands where id = v_brand;
  delete from public.alert_rules where name like 'TESTE-06%';
end
$$;

-- ---------------------------------------------------------------------------
-- 6. A regra mais específica vence
-- ---------------------------------------------------------------------------
-- Bloco separado porque precisa de duas regras do MESMO tipo em escopos
-- diferentes, e o que se verifica é que a view entrega UMA.
do $$
declare
  v_brand uuid;
  v_site  uuid;
  v_maq   uuid;
  v_qtd   integer;
  v_lim   numeric;
  v_esc   text;
  v_cod   text := 'ZZESCOPO';
begin
  raise notice '';
  raise notice '--- 6. precedencia de escopo ---';

  delete from public.machines where label = 'PC-ESCOPO';
  delete from public.sites where code = v_cod;
  delete from public.brands where code = v_cod;
  delete from public.alert_rules where name like 'TESTE-06B%';

  insert into public.brands (code, name) values (v_cod, 'escopo') returning id into v_brand;
  insert into public.sites (brand_id, code, name) values (v_brand, v_cod, 'loja escopo') returning id into v_site;
  insert into public.machines (site_id, role_code, label) values (v_site, 'pdv', 'PC-ESCOPO')
  returning id into v_maq;

  -- A regra GLOBAL de disco ja existe (seed), e o esquema so permite uma por
  -- tipo: `alert_rules_global_uq`. E a restricao certa — duas regras globais do
  -- mesmo tipo nao teriam desempate — entao o teste usa a que esta la e so
  -- acrescenta os escopos mais especificos.
  if not exists (select 1 from public.alert_rules where scope = 'global' and kind = 'disk_low') then
    insert into public.alert_rules (name, kind, scope, threshold, comparator, severity)
    values ('TESTE-06B global', 'disk_low', 'global', 10, '<=', 'warning');
  end if;

  insert into public.alert_rules (name, kind, scope, site_id, threshold, comparator, severity)
  values ('TESTE-06B loja', 'disk_low', 'site', v_site, 5, '<=', 'warning');

  insert into public.alert_rules (name, kind, scope, machine_id, threshold, comparator, severity)
  values ('TESTE-06B maquina', 'disk_low', 'machine', v_maq, 2, '<=', 'critical');

  select count(*) into v_qtd from public.regras_efetivas
  where machine_id = v_maq and kind = 'disk_low';

  if v_qtd <> 1 then
    raise exception 'FALHA: % regras de disco valendo para a mesma maquina; deveria ser 1', v_qtd;
  end if;

  select threshold, scope into v_lim, v_esc from public.regras_efetivas
  where machine_id = v_maq and kind = 'disk_low';

  if v_esc <> 'machine' or v_lim <> 2 then
    raise exception 'FALHA: venceu a regra de escopo % com limiar %, esperava machine/2', v_esc, v_lim;
  end if;
  raise notice '    global(10) + loja(5) + maquina(2) -> vence machine/2 (ok)';

  -- Removida a da máquina, a da loja assume.
  delete from public.alert_rules where name = 'TESTE-06B maquina';

  select threshold, scope into v_lim, v_esc from public.regras_efetivas
  where machine_id = v_maq and kind = 'disk_low';

  if v_esc <> 'site' or v_lim <> 5 then
    raise exception 'FALHA: sem a regra de maquina, esperava site/5, veio %/%', v_esc, v_lim;
  end if;
  raise notice '    removida a da maquina -> assume site/5 (ok)';

  delete from public.machines where id = v_maq;
  delete from public.sites where id = v_site;
  delete from public.brands where id = v_brand;
  delete from public.alert_rules where name like 'TESTE-06B%';
end
$$;

select 'TESTE 06: AVALIACAO DE ALERTAS CORRETA' as resultado;
