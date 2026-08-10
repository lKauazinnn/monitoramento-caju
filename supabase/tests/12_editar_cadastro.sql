-- =============================================================================
-- Teste 12 — corrigir o que foi cadastrado errado
-- =============================================================================
-- O que precisa ser verdade:
--
--   1. renomear a máquina muda o nome e NÃO muda o id
--   2. nome repetido dentro da mesma loja é recusado, com mensagem que nomeia
--   3. o MESMO nome em outra loja é aceito (a unicidade é por loja)
--   4. perfil inexistente é recusado
--   5. `null` em um campo não apaga o campo
--   6. mover a máquina exige a loja de DESTINO no escopo
--   7. fuso inválido é recusado antes de chegar ao CHECK da tabela
--   8. código de loja repetido é recusado
--   9. toda edição deixa evento com de/para
--  10. não-admin é recusado
--
-- O item 1 é o motivo do arquivo existir: antes desta migração, corrigir um erro
-- de digitação exigia REMOVER a máquina, e remover leva o histórico inteiro.
-- Se renomear passar a mexer no id, volta a ser destrutivo sem parecer.
--
-- O item 6 é o de segurança: sem ele, quem tem acesso a uma loja arrastaria
-- máquina de outra para dentro do próprio escopo e herdaria o histórico dela.
-- =============================================================================

\set ON_ERROR_STOP on

do $$
declare
  v_marca  uuid;
  v_loja_a uuid;
  v_loja_b uuid;
  v_m1     uuid;
  v_m2     uuid;
  v_admin  uuid := '33333333-3333-4333-8333-333333333333';
  v_viewer uuid := '22222222-2222-4222-8222-222222222222';
  v_cod    text := 'ZZEDT';
  v_r      jsonb;
  v_id_depois uuid;
  v_label  text;
  v_role   text;
  v_ev     integer;
begin
  delete from public.machines where label in ('PC-EDT-1', 'PC-EDT-2', 'PC-EDT-RENOMEADO');
  delete from public.sites  where code in (v_cod || 'A', v_cod || 'B');
  delete from public.brands where code = v_cod;
  delete from public.user_roles where user_id in (v_admin, v_viewer);

  insert into public.user_roles (user_id, role, note) values (v_admin, 'admin', 'teste 12');
  perform set_config('request.jwt.claim.sub', v_admin::text, true);

  insert into public.brands (code, name) values (v_cod, 'editar') returning id into v_marca;
  insert into public.sites (brand_id, code, name, timezone)
  values (v_marca, v_cod || 'A', 'Loja A', 'America/Sao_Paulo') returning id into v_loja_a;
  insert into public.sites (brand_id, code, name, timezone)
  values (v_marca, v_cod || 'B', 'Loja B', 'America/Sao_Paulo') returning id into v_loja_b;

  insert into public.machines (site_id, label, role_code, is_active)
  values (v_loja_a, 'PC-EDT-1', 'pdv', true) returning id into v_m1;
  insert into public.machines (site_id, label, role_code, is_active)
  values (v_loja_a, 'PC-EDT-2', 'pdv', true) returning id into v_m2;

  -- ------------------------------------------------------------------- 1 e 5
  v_r := public.editar_maquina(v_m1, 'PC-EDT-RENOMEADO');

  select m.id, m.label, m.role_code into v_id_depois, v_label, v_role
  from public.machines m where m.label = 'PC-EDT-RENOMEADO';

  if v_id_depois <> v_m1 then
    raise exception 'renomear trocou o id da maquina: % -> %', v_m1, v_id_depois;
  end if;
  if v_label <> 'PC-EDT-RENOMEADO' then
    raise exception 'o nome nao mudou: %', v_label;
  end if;
  -- `null` no perfil não podia apagar o perfil.
  if v_role <> 'pdv' then
    raise exception 'null no perfil apagou o perfil: %', coalesce(v_role, '<nulo>');
  end if;
  raise notice '1+5 ok - renomeou, manteve o id e nao apagou o perfil';

  -- ----------------------------------------------------------------------- 2
  begin
    perform public.editar_maquina(v_m2, 'PC-EDT-RENOMEADO');
    raise exception 'aceitou nome repetido na mesma loja';
  exception when sqlstate 'MON07' then
    if sqlerrm not like '%PC-EDT-RENOMEADO%' then
      raise exception 'a mensagem nao diz qual nome conflitou: %', sqlerrm;
    end if;
    raise notice '2 ok - %', sqlerrm;
  end;

  -- ----------------------------------------------------------------------- 3
  -- Mesmo nome, OUTRA loja: tem de passar. A unicidade e (site_id, label), e
  -- e comum duas lojas terem um "PDV 01".
  declare v_m3 uuid;
  begin
    insert into public.machines (site_id, label, role_code, is_active)
    values (v_loja_b, 'PC-EDT-2', 'pdv', true) returning id into v_m3;
    perform public.editar_maquina(v_m3, 'PC-EDT-RENOMEADO');
    raise notice '3 ok - o mesmo nome em outra loja e aceito';
    delete from public.machines where id = v_m3;
  end;

  -- ----------------------------------------------------------------------- 4
  begin
    perform public.editar_maquina(v_m2, null, 'perfil_que_nao_existe');
    raise exception 'aceitou perfil inexistente';
  exception when sqlstate 'MON07' then raise notice '4 ok - %', sqlerrm;
  end;

  -- ----------------------------------------------------------------------- 6
  -- Admin vê todas as lojas, então para exercitar o bloqueio de destino é
  -- preciso um usuário de escopo limitado: operator com acesso só à loja A.
  declare v_op uuid := '11111111-1111-4111-8111-111111111111';
  begin
    delete from public.user_roles where user_id = v_op;
    insert into public.user_roles (user_id, role, note) values (v_op, 'operator', 'teste 12');
    insert into public.user_site_access (user_id, site_id) values (v_op, v_loja_a)
      on conflict do nothing;
    perform set_config('request.jwt.claim.sub', v_op::text, true);

    -- Ele não é admin, então nem chega ao teste de destino: MON09 pela função.
    -- Isto documenta o estado ATUAL — editar é privilégio de admin. Quando o
    -- operator ganhar poderes (o RBAC pendente), este caso passa a valer como
    -- teste de escopo de destino e a mensagem esperada muda.
    begin
      perform public.editar_maquina(v_m2, null, null, v_loja_b);
      raise exception 'operator conseguiu mover maquina';
    exception when sqlstate 'MON09' then raise notice '6 ok - %', sqlerrm;
    end;

    perform set_config('request.jwt.claim.sub', v_admin::text, true);
    delete from public.user_site_access where user_id = v_op;
    delete from public.user_roles where user_id = v_op;
  end;

  -- ----------------------------------------------------------------------- 7
  begin
    perform public.editar_loja(v_loja_a, null, null, 'Marte/Olympus_Mons');
    raise exception 'aceitou fuso invalido';
  exception when sqlstate 'MON07' then raise notice '7 ok - %', sqlerrm;
  end;

  -- ----------------------------------------------------------------------- 8
  begin
    perform public.editar_loja(v_loja_a, v_cod || 'B');
    raise exception 'aceitou codigo de loja repetido';
  exception when sqlstate 'MON07' then raise notice '8 ok - %', sqlerrm;
  end;

  -- ----------------------------------------------------------------------- 9
  perform public.editar_loja(v_loja_a, null, 'Loja A Corrigida');

  select count(*) into v_ev from public.events
  where kind = 'site_edited' and site_id = v_loja_a
    and payload -> 'name' ->> 'de' = 'Loja A'
    and payload -> 'name' ->> 'para' = 'Loja A Corrigida';
  if v_ev <> 1 then
    raise exception 'a trilha da loja nao registrou de/para (achei % evento(s))', v_ev;
  end if;

  select count(*) into v_ev from public.events
  where kind = 'machine_edited' and machine_id = v_m1
    and payload -> 'label' ->> 'para' = 'PC-EDT-RENOMEADO';
  if v_ev <> 1 then
    raise exception 'a trilha da maquina nao registrou de/para (achei %)', v_ev;
  end if;
  raise notice '9 ok - toda edicao deixou evento com de/para';

  -- ---------------------------------------------------------------------- 10
  insert into public.user_roles (user_id, role, note) values (v_viewer, 'viewer', 'teste 12');
  perform set_config('request.jwt.claim.sub', v_viewer::text, true);
  begin
    perform public.editar_maquina(v_m2, 'INVADIDO');
    raise exception 'viewer conseguiu editar';
  exception when sqlstate 'MON09' then raise notice '10 ok - %', sqlerrm;
  end;
  begin
    perform public.editar_marca(v_marca, null, 'INVADIDO');
    raise exception 'viewer conseguiu editar marca';
  exception when sqlstate 'MON09' then raise notice '10 ok (marca) - %', sqlerrm;
  end;

  -- ------------------------------------------------------------------ limpeza
  perform set_config('request.jwt.claim.sub', v_admin::text, true);
  delete from public.machines where site_id in (v_loja_a, v_loja_b);
  delete from public.events   where site_id in (v_loja_a, v_loja_b);
  delete from public.sites    where id in (v_loja_a, v_loja_b);
  delete from public.brands   where id = v_marca;
  delete from public.user_roles where user_id in (v_admin, v_viewer);

  raise notice 'teste 12 ok';
end $$;
