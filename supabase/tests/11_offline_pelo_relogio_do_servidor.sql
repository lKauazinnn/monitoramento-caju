-- =============================================================================
-- Teste 11 — quem decide "offline" é o relógio do servidor
-- =============================================================================
-- Este arquivo existe por causa de um chamado real: uma máquina em Asa Sul
-- aparecia offline "do nada" e voltava sozinha, sem queda de rede nenhuma. O
-- relógio dela estava 87 s atrasado, e era o relógio DELA que carimbava o
-- último contato. Sobravam 93 s dos 180 s de margem, com o agente enviando a
-- cada 60 s — um único ciclo mais lento fazia a máquina piscar.
--
-- O que precisa ser verdade:
--
--   1. relógio atrasado + contato agora            => online
--   2. relógio atrasado + UM ciclo perdido         => AINDA online   <= o caso
--   3. silêncio de verdade                         => offline
--   4. logo depois do limite                       => offline
--   5. `last_contact_at` é carimbado na ingestão com o relógio do servidor,
--      mesmo quando a amostra vem com hora atrasada
--   6. o healthcheck conta online pelo MESMO critério do painel
--
-- Os itens 3 e 4 não são detalhe: uma correção de falso-offline que também
-- deixasse de detectar offline de verdade seria pior que o defeito. Eles são o
-- que impede a "correção" de virar um `status = online` disfarçado.
--
-- O item 2 é o arquivo inteiro. Ele falha na definição antiga da view — e é
-- assim que se sabe que este teste testa alguma coisa.
-- =============================================================================

\set ON_ERROR_STOP on

do $$
declare
  v_brand  uuid;
  v_site   uuid;
  v_maq    uuid;
  v_cod    text := 'ZZCLK';
  v_admin  uuid := '66666666-6666-4666-8666-666666666666';
  v_status text;
  v_seg    integer;
  v_antigo text;
  v_online integer;
  v_tok    text;
  v_t      timestamptz;
  v_contato timestamptz;
  c        record;
begin
  delete from public.machines where label = 'PC-RELOGIO';
  delete from public.sites  where code = v_cod;
  delete from public.brands where code = v_cod;
  delete from public.user_roles where user_id = v_admin;

  insert into public.user_roles (user_id, role, note) values (v_admin, 'admin', 'teste 11');
  perform set_config('request.jwt.claim.sub', v_admin::text, true);

  insert into public.brands (code, name) values (v_cod, 'relogio') returning id into v_brand;
  insert into public.sites (brand_id, code, name, timezone)
  values (v_brand, v_cod, 'Loja do relógio torto', 'America/Sao_Paulo')
  returning id into v_site;

  insert into public.machines (site_id, label, role_code, is_active)
  values (v_site, 'PC-RELOGIO', 'pdv', true)
  returning id into v_maq;

  -- ---------------------------------------------------------------- casos 1..4
  -- `seen` é o que o relógio da MÁQUINA alega; `contato` é o silêncio real
  -- medido pelo servidor. O limite de offline é 180 s.
  for c in
    select * from (values
      (1, interval '100 seconds', interval '0 seconds',   'online',
          'relógio 100 s atrasado, acabou de falar'),
      (2, interval '230 seconds', interval '130 seconds', 'online',
          'relógio torto E um ciclo perdido — o caso de Asa Sul'),
      (3, interval '600 seconds', interval '600 seconds', 'offline',
          'silêncio de dez minutos'),
      (4, interval '181 seconds', interval '181 seconds', 'offline',
          'um segundo passado do limite')
    ) t(n, seen, contato, esperado, descricao)
    order by 1
  loop
    update public.machines
       set last_seen_at    = now() - c.seen,
           last_contact_at = now() - c.contato
     where id = v_maq;

    select status, seconds_since_seen into v_status, v_seg
      from public.machines_status where machine_id = v_maq;

    if v_status is distinct from c.esperado then
      raise exception 'caso % (%): status % — esperado %',
        c.n, c.descricao, v_status, c.esperado;
    end if;

    -- A contagem mostrada tem que ser o silêncio REAL, não o do relógio torto.
    if abs(v_seg - extract(epoch from c.contato)::integer) > 2 then
      raise exception 'caso %: seconds_since_seen=% deveria refletir % s de silêncio real',
        c.n, v_seg, extract(epoch from c.contato)::integer;
    end if;

    raise notice 'caso % ok — % (servidor: % s)', c.n, c.descricao, v_seg;
  end loop;

  -- O critério antigo, calculado aqui do lado, para provar que o caso 2
  -- realmente distingue as duas definições. Sem esta conferência, o teste
  -- passaria igual se a correção nunca tivesse sido feita.
  update public.machines
     set last_seen_at    = now() - interval '230 seconds',
         last_contact_at = now() - interval '130 seconds'
   where id = v_maq;

  select case when m.last_seen_at > public.offline_cutoff() then 'online' else 'offline' end
    into v_antigo
  from public.machines m where m.id = v_maq;

  if v_antigo <> 'offline' then
    raise exception 'o critério antigo deveria dizer offline no caso 2; disse % — '
                    'o teste parou de distinguir as duas definições', v_antigo;
  end if;
  raise notice 'caso 2 confirmado: critério antigo dizia offline, o novo diz online';

  -- ------------------------------------------------------------------- caso 5
  -- Ingestão de verdade, com a amostra carimbada 90 s no passado (é o que um
  -- relógio atrasado produz). `last_seen_at` tem de guardar a hora da MEDIÇÃO,
  -- e `last_contact_at` a hora da CHEGADA.
  v_tok := 'tok-teste-11-' || replace(v_maq::text, '-', '');
  insert into public.agent_tokens (machine_id, token_prefix, token_hash, created_by)
  values (v_maq, left(v_tok, 16), sha256(convert_to(v_tok, 'UTF8')), v_admin::text);

  v_t := date_trunc('second', now()) - interval '90 seconds';

  perform public.ingest_batch(v_tok, jsonb_build_object(
    'agent_version', 'ps-teste',
    'sent_at', to_char(v_t, 'YYYY-MM-DD"T"HH24:MI:SSOF'),
    'machine', jsonb_build_object('hostname', 'PC-RELOGIO'),
    'samples', jsonb_build_array(jsonb_build_object(
      't', to_char(v_t, 'YYYY-MM-DD"T"HH24:MI:SSOF'),
      'cpu_pct', 10,
      'uptime_seconds', 3600
    ))
  ));

  select m.last_seen_at, m.last_contact_at into v_t, v_contato
  from public.machines m where m.id = v_maq;

  if abs(extract(epoch from (now() - v_contato))) > 5 then
    raise exception 'last_contact_at ficou % s no passado; deveria ser ~agora',
      extract(epoch from (now() - v_contato))::integer;
  end if;

  if abs(extract(epoch from (now() - v_t)) - 90) > 5 then
    raise exception 'last_seen_at deveria guardar a hora da medição (~90 s atrás); ficou % s',
      extract(epoch from (now() - v_t))::integer;
  end if;

  select status into v_status from public.machines_status where machine_id = v_maq;
  if v_status <> 'online' then
    raise exception 'depois de uma ingestão real com relógio atrasado, status=%', v_status;
  end if;
  raise notice 'caso 5 ok — amostra 90 s atrasada, contato agora, status online';

  -- ------------------------------------------------------------------- caso 6
  -- O healthcheck tem de concordar com o painel. Enquanto ele contava pelo
  -- critério antigo, "monitorar o monitoramento" dava um número e a tela dava
  -- outro — e alguém perderia uma hora decidindo em qual acreditar.
  update public.machines
     set last_seen_at    = now() - interval '230 seconds',
         last_contact_at = now() - interval '130 seconds'
   where id = v_maq;

  if (select status from public.machines_status where machine_id = v_maq) <> 'online' then
    raise exception 'preparação do caso 6 falhou: a máquina não está online na view';
  end if;

  -- Igualdade, e não ">= 1": com ">= 1" o teste passaria por causa de qualquer
  -- outra máquina online, inclusive se o healthcheck tivesse ficado no critério
  -- antigo e simplesmente não contasse esta.
  v_online := (public.ingest_health() ->> 'machines_online')::integer;

  if v_online <> (select count(*) from public.machines_status
                  where status = 'online' and is_active) then
    raise exception 'healthcheck diz % online; a view diz % — critérios divergentes',
      v_online, (select count(*) from public.machines_status
                 where status = 'online' and is_active);
  end if;
  raise notice 'caso 6 ok — healthcheck e painel contam os mesmos % online', v_online;

  -- ------------------------------------------------------------------- limpeza
  delete from public.machines where id = v_maq;
  delete from public.sites  where id = v_site;
  delete from public.brands where id = v_brand;
  delete from public.user_roles where user_id = v_admin;

  raise notice 'teste 11 ok';
end $$;
