-- =============================================================================
-- Teste 13 — painel de usuários
-- =============================================================================
-- O que precisa ser verdade:
--
--   1. admin lista usuários, papéis e lojas
--   2. admin aparece com `todas_as_lojas`, não com lista vazia
--   3. mudar papel e escopo grava
--   4. `null` no escopo NÃO apaga o escopo
--   5. array vazio ZERA o escopo — é diferente de null, e é escolha legítima
--   6. loja inexistente é recusada, não ignorada
--   7. papel inválido é recusado
--   8. o ÚLTIMO admin não consegue se rebaixar
--   9. ninguém remove o próprio acesso
--  10. remover outro deixa trilha
--  11. não-admin não lista nem concede
--  12. e-mail inválido é recusado no registro
--
-- Os itens 8 e 9 são os que impedem o sistema de se trancar do lado de fora. Sem
-- eles, um clique deixa o painel sem ninguém que possa conceder acesso, e o
-- conserto passa a exigir SQL Editor com a service_role — exatamente o que este
-- painel existe para evitar.
--
-- O item 4 contra o 5 é o par que impede o formulário de apagar dado bom: um
-- salvar sem tocar no escopo não pode zerar as lojas de ninguém.
--
-- ISOLAMENTO: tudo dentro de uma transação que termina em rollback, e os admins
-- pré-existentes são rebaixados dentro dela. A primeira versão deste arquivo
-- deu falso NEGATIVO no item 8 justamente por isso — a base de desenvolvimento
-- já tinha outros admins, então a trava não devia disparar e eu culpei o código.
-- =============================================================================

\set ON_ERROR_STOP on

begin;

do $$
declare
  a     uuid := 'aaaaaaaa-0000-4000-8000-000000000001';
  b     uuid := 'bbbbbbbb-0000-4000-8000-000000000002';
  loja  uuid;
  r     jsonb;
  n     integer;
begin
  select id into loja from public.sites order by code limit 1;
  if loja is null then
    raise exception 'sem loja cadastrada: o teste precisa de uma para exercitar escopo';
  end if;

  -- Ninguém mais é admin dentro desta transação. Ver ISOLAMENTO no cabeçalho.
  update public.user_roles set role = 'viewer' where role = 'admin';

  delete from public.user_site_access where user_id in (a, b);
  delete from public.user_roles where user_id in (a, b);
  insert into public.user_roles (user_id, role, note, email) values
    (a, 'admin', 'teste 13', 'admin.a@cajupar.com'),
    (b, 'admin', 'teste 13', 'admin.b@cajupar.com');

  perform set_config('request.jwt.claim.sub', a::text, true);

  -- ----------------------------------------------------------------------- 1
  r := public.usuarios_do_painel();
  if jsonb_array_length(r -> 'usuarios') < 2 then
    raise exception 'a listagem nao trouxe os dois usuarios';
  end if;
  if jsonb_array_length(r -> 'papeis') <> 3 then
    raise exception 'esperava 3 papeis, veio %', jsonb_array_length(r -> 'papeis');
  end if;
  if jsonb_array_length(r -> 'lojas') < 1 then
    raise exception 'a listagem nao trouxe loja para conceder';
  end if;
  raise notice '1 ok - listou %, com 3 papeis e % loja(s)',
    jsonb_array_length(r -> 'usuarios'), jsonb_array_length(r -> 'lojas');

  -- ----------------------------------------------------------------------- 2
  if not exists (
    select 1 from jsonb_array_elements(r -> 'usuarios') u
    where u ->> 'user_id' = a::text and (u ->> 'todas_as_lojas')::boolean
  ) then
    raise exception 'admin nao veio com todas_as_lojas';
  end if;
  raise notice '2 ok - admin marcado como todas as lojas';

  -- ----------------------------------------------------------------------- 3
  r := public.definir_acesso_usuario(b, 'operator', array[loja], 'Bruno');
  select count(*) into n from public.user_site_access where user_id = b;
  if n <> 1 then raise exception 'o escopo nao gravou (% linha[s])', n; end if;
  if (select nome from public.user_roles where user_id = b) <> 'Bruno' then
    raise exception 'o nome nao gravou';
  end if;
  raise notice '3 ok - %', r::text;

  -- ----------------------------------------------------------------------- 4
  perform public.definir_acesso_usuario(b, 'viewer');
  select count(*) into n from public.user_site_access where user_id = b;
  if n <> 1 then raise exception 'null no escopo APAGOU o escopo'; end if;
  raise notice '4 ok - null preservou o escopo';

  -- ----------------------------------------------------------------------- 5
  perform public.definir_acesso_usuario(b, null, array[]::uuid[]);
  select count(*) into n from public.user_site_access where user_id = b;
  if n <> 0 then raise exception 'array vazio nao zerou o escopo (%)', n; end if;
  raise notice '5 ok - array vazio zerou o escopo';

  -- ----------------------------------------------------------------------- 6
  begin
    perform public.definir_acesso_usuario(
      b, null, array['00000000-0000-4000-8000-0000000000ff'::uuid]);
    raise exception 'aceitou loja inexistente';
  exception when sqlstate 'MON07' then raise notice '6 ok - %', sqlerrm;
  end;

  -- ----------------------------------------------------------------------- 7
  begin
    perform public.definir_acesso_usuario(b, 'superadmin');
    raise exception 'aceitou papel invalido';
  exception when sqlstate 'MON07' then raise notice '7 ok - %', sqlerrm;
  end;

  -- ----------------------------------------------------------------------- 8
  -- Agora `a` e o unico admin: `b` ja foi rebaixado no caso 4.
  select count(*) into n from public.user_roles where role = 'admin';
  if n <> 1 then
    raise exception 'preparacao do caso 8 falhou: % admin(s) em vez de 1', n;
  end if;
  begin
    perform public.definir_acesso_usuario(a, 'viewer');
    raise exception 'o unico administrador conseguiu se rebaixar';
  exception when sqlstate 'MON09' then raise notice '8 ok - %', sqlerrm;
  end;

  -- ----------------------------------------------------------------------- 9
  begin
    perform public.remover_acesso_usuario(a);
    raise exception 'removeu o proprio acesso';
  exception when sqlstate 'MON09' then raise notice '9 ok - %', sqlerrm;
  end;

  -- ---------------------------------------------------------------------- 10
  perform public.remover_acesso_usuario(b);
  select count(*) into n from public.events
  where kind = 'user_access_revoked' and payload ->> 'user_id' = b::text;
  if n < 1 then raise exception 'revogou sem deixar trilha'; end if;
  if exists (select 1 from public.user_roles where user_id = b) then
    raise exception 'o usuario continua no painel depois de revogado';
  end if;
  raise notice '10 ok - revogou e registrou';

  -- ---------------------------------------------------------------------- 11
  insert into public.user_roles (user_id, role, note, email)
  values (b, 'viewer', 'teste 13', 'viewer@cajupar.com');
  perform set_config('request.jwt.claim.sub', b::text, true);
  begin
    perform public.usuarios_do_painel();
    raise exception 'viewer listou os usuarios';
  exception when sqlstate 'MON09' then raise notice '11 ok - %', sqlerrm;
  end;
  begin
    perform public.definir_acesso_usuario(b, 'admin');
    raise exception 'viewer promoveu a si mesmo';
  exception when sqlstate 'MON09' then raise notice '11 ok (promocao) - %', sqlerrm;
  end;

  -- ---------------------------------------------------------------------- 12
  perform set_config('request.jwt.claim.sub', a::text, true);
  begin
    perform public.registrar_usuario_do_painel(
      'cccccccc-0000-4000-8000-000000000003', 'nao-eh-email', 'X', 'viewer');
    raise exception 'aceitou e-mail invalido';
  exception when sqlstate 'MON07' then raise notice '12 ok - %', sqlerrm;
  end;

  raise notice 'teste 13 ok';
end $$;

rollback;
