-- =============================================================================
-- Teste 10 — dias sem reiniciar, e o reinício agendado
-- =============================================================================
-- O que precisa ser verdade:
--
--   1. os dias são contados desde o último boot
--   2. passando do limiar, o alerta abre
--   3. REINICIAR zera a conta e o alerta fecha
--   4. SUSPENDER **não** zera nada — é o ponto todo deste arquivo
--   5. o agendamento marca para a hora pedida, no futuro
--   6. e a janela de entrega alcança a hora marcada
--   7. hora fora de 0..23 é recusada
--
-- O item 4 é a razão deste arquivo existir. Se suspender contasse como
-- reinício, o alerta fecharia toda noite quando a loja fechasse, e uma máquina
-- que passou seis meses sem reiniciar de verdade nunca apareceria — o
-- monitoramento estaria escondendo exatamente o problema que ele deveria achar.
--
-- O item 6 protege um defeito silencioso: o TTL padrão do comando é 30 min. Um
-- reinício marcado para daqui a 8 h expiraria antes de ser entregue, e ninguém
-- entenderia por que a máquina não reiniciou.
-- =============================================================================

\set ON_ERROR_STOP on

do $$
declare
  v_brand  uuid;
  v_site   uuid;
  v_maq    uuid;
  v_cod    text := 'ZZUPT';
  v_admin  uuid := '77777777-7777-4777-8777-777777777777';
  v_dias   numeric;
  v_r      jsonb;
  v_ab     integer;
  v_quando timestamptz;
  v_exp    timestamptz;
begin
  delete from public.machines where label = 'PC-UPTIME';
  delete from public.sites  where code = v_cod;
  delete from public.brands where code = v_cod;
  delete from public.user_roles where user_id = v_admin;

  insert into public.user_roles (user_id, role, note) values (v_admin, 'admin', 'teste 10');
  perform set_config('request.jwt.claim.sub', v_admin::text, true);

  insert into public.brands (code, name) values (v_cod, 'uptime') returning id into v_brand;
  insert into public.sites (brand_id, code, name, timezone)
  values (v_brand, v_cod, 'loja uptime', 'America/Sao_Paulo') returning id into v_site;

  -- Ligada há 30 dias, online agora.
  insert into public.machines (site_id, role_code, label, last_seen_at, last_boot_at, agent_version)
  values (v_site, 'pdv', 'PC-UPTIME', now(), now() - interval '30 days', 'ps-1.3.0')
  returning id into v_maq;

  -- ------------------------------------------------------ 1. a contagem
  v_dias := public.dias_ligada(v_maq);
  if v_dias is null or v_dias < 29.9 or v_dias > 30.1 then
    raise exception 'FALHA 1: contou % dias, esperava ~30', coalesce(v_dias::text, '(nulo)');
  end if;

  -- ------------------------------------------------------ 2. o alerta abre
  perform public.avaliar_alertas();

  select count(*) into v_ab from public.events
  where machine_id = v_maq and kind = 'alert_open' and resolved_at is null
    and message like '%dias sem reiniciar%';

  if v_ab < 1 then
    raise exception 'FALHA 2: 30 dias sem reiniciar nao abriu alerta';
  end if;

  -- ------------------------------------- 4. SUSPENDER nao zera nada
  -- Feito ANTES do reinicio: se estivesse depois, o alerta ja estaria fechado e
  -- a verificacao passaria sem provar coisa alguma.
  --
  -- Suspender e voltar mexe em `last_seen_at` (a maquina reaparece), mas NAO em
  -- `last_boot_at` — o sistema volta do mesmo lugar, com a mesma memoria suja.
  update public.machines set last_seen_at = now() where id = v_maq;

  perform public.avaliar_alertas();

  v_dias := public.dias_ligada(v_maq);
  if v_dias < 29.9 then
    raise exception 'FALHA 4: suspender zerou a contagem (agora %)', v_dias;
  end if;

  select count(*) into v_ab from public.events
  where machine_id = v_maq and kind = 'alert_open' and resolved_at is null
    and message like '%dias sem reiniciar%';

  if v_ab < 1 then
    raise exception 'FALHA 4: suspender FECHOU o alerta de dias sem reiniciar';
  end if;

  -- ---------------------------------------- 3. reiniciar zera e fecha
  update public.machines set last_boot_at = now() where id = v_maq;

  v_dias := public.dias_ligada(v_maq);
  if v_dias > 0.1 then
    raise exception 'FALHA 3: reiniciar nao zerou a contagem (esta %)', v_dias;
  end if;

  perform public.avaliar_alertas();

  select count(*) into v_ab from public.events
  where machine_id = v_maq and kind = 'alert_open' and resolved_at is null
    and message like '%dias sem reiniciar%';

  if v_ab > 0 then
    raise exception 'FALHA 3: o alerta continuou aberto depois do reinicio';
  end if;

  -- --------------------------------------------- 5/6. o agendamento
  v_r := public.agendar_reinicio(v_maq, 4);
  v_quando := (v_r ->> 'quando')::timestamptz;

  if v_quando <= now() then
    raise exception 'FALHA 5: agendou para o passado (%)', v_quando;
  end if;

  if v_quando > now() + interval '25 hours' then
    raise exception 'FALHA 5: agendou para depois de amanha (%)', v_quando;
  end if;

  if extract(hour from (v_quando at time zone 'America/Sao_Paulo')) <> 4 then
    raise exception 'FALHA 5: agendou para %h no fuso da loja, esperava 4h',
      extract(hour from (v_quando at time zone 'America/Sao_Paulo'));
  end if;

  select not_before, expires_at into v_quando, v_exp
  from public.agent_commands where id = (v_r ->> 'command_id')::uuid;

  if v_exp <= v_quando then
    raise exception 'FALHA 6: o comando expira (%) ANTES da hora marcada (%)', v_exp, v_quando;
  end if;

  -- E nao pode ser entregue antes da hora.
  if v_quando <= now() then
    raise exception 'FALHA 6: o comando ja esta liberado para entrega';
  end if;

  -- ---------------------------------------------- 7. hora impossivel
  begin
    perform public.agendar_reinicio(v_maq, 99);
    raise exception 'FALHA 7: aceitou agendar para as 99h';
  exception when sqlstate 'MON07' then
    null;
  end;

  -- ------------------------------------------------------------------ limpa
  delete from public.agent_commands where machine_id = v_maq;
  delete from public.events where site_id = v_site;
  delete from public.machines where id = v_maq;
  delete from public.sites where id = v_site;
  delete from public.brands where id = v_brand;
  delete from public.user_roles where user_id = v_admin;

  raise notice 'TESTE 10 OK — dias sem reiniciar, e suspender nao conta';
end
$$;
