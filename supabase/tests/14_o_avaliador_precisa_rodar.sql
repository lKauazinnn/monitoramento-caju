-- =============================================================================
-- Teste 14 — o avaliador precisa rodar, e as regras são editáveis
-- =============================================================================
-- O que precisa ser verdade:
--
--   1. máquina que para de reportar ABRE alerta crítico ao avaliar
--   2. e o alerta chega em incidentes_abertos com `gritar` > 0 (é o que toca)
--   3. o alerta traz kind='offline' e o rótulo da máquina (o som precisa dizer
--      QUAL máquina caiu)
--   4. a máquina voltando RESOLVE o alerta, e a faixa cala sozinha
--   5. máquina em manutenção declarada NÃO abre alerta
--   6. regras_de_alerta devolve as 8 globais, com unidade e explicação
--   7. a regra de offline vem marcada `sem_limiar`
--   8. admin ajusta limiar, histerese e silêncio
--   9. limiar em regra de offline é RECUSADO
--  10. ciclos fora de 1..60 é recusado
--  11. não-admin não edita
--  12. desativar a regra deixa trilha em events
--  13. o job do pg_cron está agendado (só onde há pg_cron)
--
-- O caso 1 é o motivo deste arquivo existir. Todo o pipeline de alerta estava
-- correto e nunca havia rodado em produção: `avaliar_alertas()` só era chamada
-- por testes. O sintoma era um PC sem contato há sete dias sem faixa vermelha e
-- sem som. Um teste que chama o avaliador à mão -- como o 06 faz -- prova a
-- lógica e NÃO prova que alguém a executa; por isso o caso 13 confere o
-- agendamento, e não só o comportamento.
--
-- ISOLAMENTO: transação com rollback no fim.
-- =============================================================================

\set ON_ERROR_STOP on

begin;

do $$
declare
  v_brand   uuid;
  v_site    uuid;
  v_maq     uuid;
  v_cod     text := 'ZZALERTA';
  v_admin   uuid := '77777777-7777-4777-8777-777777777777';
  v_ze      uuid := '88888888-8888-4888-8888-888888888888';
  v_regra   uuid;
  v_r       jsonb;
  v_item    jsonb;
  v_n       integer;
  v_txt     text;
  v_limite  integer;
begin
  delete from public.machines where label = 'PC-QUEDA';
  delete from public.sites  where code = v_cod;
  delete from public.brands where code = v_cod;
  delete from public.user_roles where user_id in (v_admin, v_ze);

  insert into public.user_roles (user_id, role, note) values (v_admin, 'admin', 'teste 14');
  insert into public.user_roles (user_id, role, note) values (v_ze, 'viewer', 'teste 14');
  perform set_config('request.jwt.claim.sub', v_admin::text, true);

  insert into public.brands (code, name) values (v_cod, 'alerta') returning id into v_brand;
  insert into public.sites (brand_id, code, name, timezone)
  values (v_brand, v_cod, 'Loja do alerta', 'America/Sao_Paulo')
  returning id into v_site;

  insert into public.machines (site_id, label, role_code, is_active)
  values (v_site, 'PC-QUEDA', 'server', true)
  returning id into v_maq;

  select coalesce((select value::integer from public.app_settings
                   where key = 'offline_timeout_seconds'), 180)
  into v_limite;

  -- =========================================================== 1, 2, 3
  -- A máquina falou, e depois calou por bem mais que o limite. É o caso do
  -- servidor que desligou.
  update public.machines
  set last_seen_at = now() - make_interval(secs => v_limite + 300),
      last_contact_at = now() - make_interval(secs => v_limite + 300)
  where id = v_maq;

  perform public.avaliar_alertas();

  -- Nao existe tabela 'alerts': o alerta ABERTO e uma linha de public.events com
  -- kind='alert_open', e public.open_alerts e a view que mostra os que ainda nao
  -- fecharam. Eu supus uma tabela e o teste quebrou na cara -- que e o lugar certo
  -- para essa suposicao morrer.
  select count(*) into v_n
  from public.open_alerts a
  where a.machine_id = v_maq and a.rule_kind = 'offline'
    and a.severity = 'critical';

  if v_n <> 1 then
    raise exception 'FALHOU 1: esperava 1 alerta critico de offline aberto, achei %', v_n;
  end if;
  raise notice 'ok  1  maquina sem contato abre alerta critico';

  v_r := public.incidentes_abertos();

  if (v_r->>'gritar')::integer < 1 then
    raise exception 'FALHOU 2: gritar=% -- e este numero que faz o painel tocar',
      v_r->>'gritar';
  end if;
  raise notice 'ok  2  incidentes_abertos manda gritar (%)', v_r->>'gritar';

  select x into v_item
  from jsonb_array_elements(v_r->'lista') x
  where x->>'machine_id' = v_maq::text;

  if v_item is null then
    raise exception 'FALHOU 3: a maquina nao esta na lista de incidentes';
  end if;
  if v_item->>'kind' <> 'offline' then
    raise exception 'FALHOU 3: kind=% (o painel filtra o som por kind)', v_item->>'kind';
  end if;
  if v_item->>'label' <> 'PC-QUEDA' then
    raise exception 'FALHOU 3: label=% -- sem isso o aviso nao diz qual maquina caiu',
      v_item->>'label';
  end if;
  raise notice 'ok  3  o incidente diz o tipo e QUAL maquina (% / %)',
    v_item->>'kind', v_item->>'label';

  -- =========================================================== 4
  -- Voltou a reportar: o alerta tem de fechar sozinho.
  update public.machines
  set last_seen_at = now(), last_contact_at = now()
  where id = v_maq;

  perform public.avaliar_alertas();

  select count(*) into v_n
  from public.open_alerts a
  where a.machine_id = v_maq and a.rule_kind = 'offline';

  if v_n <> 0 then
    raise exception 'FALHOU 4: a maquina voltou e ainda ha % alerta(s) aberto(s)', v_n;
  end if;
  raise notice 'ok  4  a maquina voltando resolve o alerta';

  -- =========================================================== 5
  -- Manutenção declarada: cai de propósito, e avisar sobre isso é o caminho mais
  -- curto para o alerta ser ignorado.
  update public.machines
  set last_seen_at = now() - make_interval(secs => v_limite + 300),
      last_contact_at = now() - make_interval(secs => v_limite + 300),
      maintenance_until = now() + interval '1 hour'
  where id = v_maq;

  perform public.avaliar_alertas();

  select count(*) into v_n
  from public.open_alerts a
  where a.machine_id = v_maq and a.rule_kind = 'offline';

  if v_n <> 0 then
    raise exception 'FALHOU 5: maquina em manutencao abriu % alerta(s)', v_n;
  end if;
  raise notice 'ok  5  manutencao declarada nao gera alerta';

  update public.machines set maintenance_until = null where id = v_maq;

  -- =========================================================== 6, 7
  v_r := public.regras_de_alerta();

  if jsonb_array_length(v_r) < 8 then
    raise exception 'FALHOU 6: esperava 8 regras globais, veio %',
      jsonb_array_length(v_r);
  end if;

  select x into v_item from jsonb_array_elements(v_r) x where x->>'kind' = 'cpu_sustained';
  if v_item->>'unidade' <> '%' then
    raise exception 'FALHOU 6: cpu_sustained sem unidade (veio %)', v_item->>'unidade';
  end if;
  if coalesce(v_item->>'explicacao', '') = '' then
    raise exception 'FALHOU 6: regra sem explicacao';
  end if;
  raise notice 'ok  6  % regras com unidade e explicacao', jsonb_array_length(v_r);

  select x into v_item from jsonb_array_elements(v_r) x where x->>'kind' = 'offline';
  if (v_item->>'sem_limiar')::boolean is not true then
    raise exception 'FALHOU 7: offline devia vir sem_limiar';
  end if;
  if v_item->>'explicacao' not like '%offline_timeout_seconds%' then
    raise exception 'FALHOU 7: a explicacao de offline tem de dizer de onde vem o tempo';
  end if;
  v_regra := (v_item->>'rule_id')::uuid;
  raise notice 'ok  7  offline vem sem limiar e explica de onde vem o tempo';

  -- =========================================================== 8
  select id into v_regra from public.alert_rules
  where scope = 'global' and kind = 'cpu_sustained';

  v_r := public.editar_regra_de_alerta(v_regra, 85, 12, 45, null);

  -- Os tres campos conferidos de uma vez, num record proprio: a primeira versao
  -- deste caso reusava v_limite para o limite de offline E para o cooldown, e um
  -- 'select into' com tres destinos iguais silenciosamente conferia sempre a
  -- mesma coluna.
  declare
    v_dep record;
  begin
    select threshold, consecutive_cycles, cooldown_minutes into v_dep
    from public.alert_rules where id = v_regra;

    if v_dep.threshold <> 85 then
      raise exception 'FALHOU 8: limiar ficou %', v_dep.threshold;
    end if;
    if v_dep.consecutive_cycles <> 12 then
      raise exception 'FALHOU 8: ciclos ficaram %', v_dep.consecutive_cycles;
    end if;
    if v_dep.cooldown_minutes <> 45 then
      raise exception 'FALHOU 8: silencio ficou %', v_dep.cooldown_minutes;
    end if;
  end;

  if v_r->'mudou' = '{}'::jsonb then
    raise exception 'FALHOU 8: mudou veio vazio depois de tres alteracoes';
  end if;
  raise notice 'ok  8  admin ajusta limiar, historese e silencio';

  -- =========================================================== 9
  select id into v_regra from public.alert_rules
  where scope = 'global' and kind = 'offline';

  begin
    perform public.editar_regra_de_alerta(v_regra, 300, null, null, null);
    raise exception 'FALHOU 9: aceitou limiar numa regra de offline';
  exception when sqlstate 'MON07' then
    raise notice 'ok  9  limiar em regra de offline e recusado';
  end;

  -- =========================================================== 10
  begin
    perform public.editar_regra_de_alerta(v_regra, null, 99, null, null);
    raise exception 'FALHOU 10: aceitou 99 ciclos';
  exception when sqlstate 'MON07' then
    raise notice 'ok 10  ciclos fora de 1..60 e recusado';
  end;

  -- =========================================================== 11
  perform set_config('request.jwt.claim.sub', v_ze::text, true);
  begin
    perform public.editar_regra_de_alerta(v_regra, null, 5, null, null);
    raise exception 'FALHOU 11: viewer editou regra de alerta';
  exception when sqlstate 'MON09' then
    raise notice 'ok 11  nao-admin nao edita regra';
  end;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);

  -- =========================================================== 12
  select count(*) into v_n from public.events where kind = 'rule_edited';

  perform public.editar_regra_de_alerta(v_regra, null, null, null, false);

  select count(*) into v_limite from public.events where kind = 'rule_edited';
  if v_limite <= v_n then
    raise exception 'FALHOU 12: desativar a regra nao deixou trilha (% -> %)',
      v_n, v_limite;
  end if;

  select payload->>'mudou' into v_txt from public.events
  where kind = 'rule_edited' order by id desc limit 1;
  if v_txt not like '%ativa%' then
    raise exception 'FALHOU 12: a trilha nao registra que a regra foi desativada (%)',
      v_txt;
  end if;
  raise notice 'ok 12  desativar a regra deixa trilha';

  -- =========================================================== 13
  -- O que realmente faltava. Sem este caso, todos os anteriores passam num
  -- sistema que nunca avalia nada -- foi assim por semanas.
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    -- O job certo se chama 'avaliar-alertas' e quem o cria e a 0020.
    --
    -- Esta guarda ja apontou para o job ERRADO. A primeira versao exigia
    -- 'monitor_avaliar_alertas' a cada minuto -- o duplicado que a 0043 apagou
    -- justamente por rodar 5x mais sobre machines_status e entrar na conta do
    -- limite que estourou. Como a stack local nao tem pg_cron, o bloco inteiro
    -- era pulado e ninguem via: o teste so falharia em producao, que e onde ele
    -- precisava passar.
    if not exists (
      select 1 from cron.job where jobname = 'avaliar-alertas' and active
    ) then
      raise exception 'FALHOU 13: o job avaliar-alertas NAO esta agendado. '
        'A logica de alerta funciona e ninguem a executa. Reaplique a 0020.';
    end if;

    select schedule into v_txt from cron.job where jobname = 'avaliar-alertas';
    if v_txt <> '* * * * *' then
      raise exception 'FALHOU 13: agendado em "%" -- esperava * * * * * (1 min). '
        'O pior caso do alerta e offline_timeout_seconds + este intervalo.', v_txt;
    end if;
    raise notice 'ok 13  o avaliador esta agendado (%)', v_txt;

    -- 13b. O duplicado tem de continuar morto. Sem esta guarda, rodar de novo o
    -- ligar-avaliacao-de-alertas.ps1 antigo recriaria os dois jobs em paralelo e
    -- o sintoma voltaria sem nenhum teste reclamando.
    if exists (select 1 from cron.job where jobname = 'monitor_avaliar_alertas') then
      raise exception 'FALHOU 13b: o job duplicado monitor_avaliar_alertas voltou. '
        'Dois avaliadores em paralelo queimam CPU e conexao -- reaplique a 0043.';
    end if;
    raise notice 'ok 13b o duplicado monitor_avaliar_alertas continua ausente';
  else
    raise notice '--  13  sem pg_cron nesta base: o agendamento NAO foi conferido '
      '(em producao ele e obrigatorio)';
  end if;

  raise notice '';
  raise notice 'Teste 14: os alertas sao avaliados e as regras sao editaveis.';
end $$;

rollback;
