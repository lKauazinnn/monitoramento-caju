-- =============================================================================
-- 0035 — Painel de usuários
-- =============================================================================
-- O RBAC existia desde a 0003: `user_roles` com admin/operator/viewer e
-- `user_site_access` para escopo por loja. O que nunca existiu foi tela. Conceder
-- acesso a alguém era `insert` na mão, pelo SQL Editor — e por isso, na prática,
-- todo mundo virava admin.
--
-- NADA AQUI TOCA O SCHEMA `auth`.
--
-- Isso é deliberado e não é preciosismo: a stack local não tem `auth.users` (ela
-- usa o login próprio da 0014), então uma função que fizesse `join auth.users`
-- funcionaria em produção e explodiria no ambiente onde os testes rodam — o pior
-- lugar possível para colocar essa diferença. `email` e `nome` passam a viver em
-- `user_roles`, preenchidos por quem cria o usuário.
--
-- Criar a conta em si NÃO acontece aqui: exige a `service_role`, que por regra
-- do projeto não pode chegar ao navegador. Isso é da Edge Function
-- `admin-usuarios`, que valida o chamador e usa o segredo do lado servidor.
-- Estas funções cuidam de PAPEL e ESCOPO, que são dados nossos.
-- =============================================================================

alter table public.user_roles add column if not exists email text;
alter table public.user_roles add column if not exists nome  text;

comment on column public.user_roles.email is
  'Copia do e-mail para o painel poder listar sem ler o schema auth (que nao existe na stack local).';

-- Um índice único parcial, e não `unique` puro: os usuários que já existiam
-- entram com email nulo, e `unique` aceitaria vários nulos mas atrapalharia a
-- intenção. Aqui a regra é explícita — dois cadastros com o MESMO e-mail é erro.
create unique index if not exists user_roles_email_uk
  on public.user_roles (lower(email)) where email is not null;

-- -----------------------------------------------------------------------------
-- Quem tem acesso
-- -----------------------------------------------------------------------------
create or replace function public.usuarios_do_painel()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_eu uuid := auth.uid();
begin
  if not public.current_user_is_admin() then
    raise exception 'apenas administradores podem ver os usuários' using errcode = 'MON09';
  end if;

  return jsonb_build_object(
    'eu', v_eu,
    'papeis', jsonb_build_array(
      jsonb_build_object('code', 'admin',
        'nome', 'Administrador',
        'descricao', 'Vê tudo, cadastra, edita e envia comandos.'),
      jsonb_build_object('code', 'operator',
        'nome', 'Operador',
        'descricao', 'Vê as lojas do escopo e reconhece alertas.'),
      jsonb_build_object('code', 'viewer',
        'nome', 'Somente leitura',
        'descricao', 'Vê as lojas do escopo e mais nada.')),
    'lojas', coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id, 'code', s.code, 'name', s.name)
                       order by s.code)
      from public.sites s where s.is_active), '[]'::jsonb),
    'usuarios', coalesce((
      select jsonb_agg(u order by u ->> 'email' nulls last)
      from (
        select jsonb_build_object(
          'user_id', r.user_id,
          'email', r.email,
          'nome', r.nome,
          'role', r.role,
          'note', r.note,
          'criado_em', r.created_at,
          -- Admin ignora `user_site_access` (ele vê todas as lojas). Devolver a
          -- lista dele como vazia faria a tela dizer "nenhuma loja", que é o
          -- oposto da verdade.
          'todas_as_lojas', (r.role = 'admin'),
          'lojas', coalesce((
            select jsonb_agg(jsonb_build_object('id', s.id, 'code', s.code) order by s.code)
            from public.user_site_access a
            join public.sites s on s.id = a.site_id
            where a.user_id = r.user_id), '[]'::jsonb)
        ) as u
        from public.user_roles r
      ) t), '[]'::jsonb)
  );
end
$fn$;

-- -----------------------------------------------------------------------------
-- Papel e escopo
-- -----------------------------------------------------------------------------
create or replace function public.definir_acesso_usuario(
  p_user_id  uuid,
  p_role     text default null,
  p_site_ids uuid[] default null,
  p_nome     text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_eu     uuid := auth.uid();
  v_antes  record;
  v_role   text;
  v_admins integer;
  v_mudou  jsonb := '{}'::jsonb;
begin
  if not public.current_user_is_admin() then
    raise exception 'apenas administradores podem conceder acesso' using errcode = 'MON09';
  end if;

  select r.user_id, r.role, r.email, r.nome into v_antes
  from public.user_roles r where r.user_id = p_user_id;

  if not found then
    raise exception 'usuário não está no painel' using errcode = 'MON01';
  end if;

  v_role := coalesce(nullif(btrim(p_role), ''), v_antes.role);
  if v_role not in ('admin', 'operator', 'viewer') then
    raise exception 'papel inválido: %', v_role using errcode = 'MON07';
  end if;

  -- O ÚLTIMO ADMIN NÃO PODE SE REBAIXAR.
  --
  -- Sem esta trava, um clique deixa o sistema sem ninguém que possa conceder
  -- acesso — e o conserto passa a exigir SQL Editor e a service_role, que é
  -- exatamente o que este painel existe para evitar. Vale também para o admin
  -- rebaixando outro: o que importa é quantos sobram.
  if v_antes.role = 'admin' and v_role <> 'admin' then
    select count(*) into v_admins from public.user_roles where role = 'admin';
    if v_admins <= 1 then
      raise exception 'este é o único administrador; promova outro antes de rebaixá-lo'
        using errcode = 'MON09';
    end if;
  end if;

  if v_role <> v_antes.role then
    v_mudou := v_mudou || jsonb_build_object('role',
      jsonb_build_object('de', v_antes.role, 'para', v_role));
  end if;

  update public.user_roles
     set role = v_role,
         nome = coalesce(nullif(btrim(p_nome), ''), nome)
   where user_id = p_user_id;

  -- `null` em p_site_ids significa "não mexer no escopo". Array vazio significa
  -- "nenhuma loja", que é diferente e é uma escolha legítima.
  if p_site_ids is not null then
    -- Loja inexistente vira erro em vez de ser ignorada em silêncio: um id
    -- errado que passa batido deixa a pessoa com menos acesso do que o admin
    -- acha que concedeu.
    if exists (
      select 1 from unnest(p_site_ids) sid
      where not exists (select 1 from public.sites s where s.id = sid)
    ) then
      raise exception 'há loja inexistente na lista de acesso' using errcode = 'MON07';
    end if;

    delete from public.user_site_access where user_id = p_user_id;
    insert into public.user_site_access (user_id, site_id)
    select p_user_id, sid from unnest(p_site_ids) sid
    on conflict do nothing;

    v_mudou := v_mudou || jsonb_build_object('lojas', coalesce(array_length(p_site_ids, 1), 0));
  end if;

  if v_mudou <> '{}'::jsonb then
    insert into public.events (machine_id, site_id, kind, severity, message, payload)
    values (null, null, 'user_access_changed', 'info',
            format('acesso de %s alterado por %s',
                   coalesce(v_antes.email, p_user_id::text), coalesce(v_eu::text, 'servidor')),
            v_mudou || jsonb_build_object('user_id', p_user_id, 'por', v_eu));
  end if;

  return jsonb_build_object('ok', true, 'mudou', v_mudou);
end
$fn$;

-- -----------------------------------------------------------------------------
-- Tirar do painel
-- -----------------------------------------------------------------------------
-- NÃO apaga a conta no `auth`: isso é da Edge Function, com a service_role. Aqui
-- o acesso é revogado, que é o que importa na hora — a pessoa perde o painel no
-- próximo pedido, mesmo que a conta continue existindo.
create or replace function public.remover_acesso_usuario(p_user_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_eu    uuid := auth.uid();
  v_antes record;
  v_admins integer;
begin
  if not public.current_user_is_admin() then
    raise exception 'apenas administradores podem revogar acesso' using errcode = 'MON09';
  end if;

  select r.user_id, r.role, r.email into v_antes
  from public.user_roles r where r.user_id = p_user_id;

  if not found then
    raise exception 'usuário não está no painel' using errcode = 'MON01';
  end if;

  -- Tirar a si mesmo é o mesmo acidente do rebaixamento, com um clique a menos.
  if p_user_id = v_eu then
    raise exception 'não é possível remover o próprio acesso' using errcode = 'MON09';
  end if;

  if v_antes.role = 'admin' then
    select count(*) into v_admins from public.user_roles where role = 'admin';
    if v_admins <= 1 then
      raise exception 'este é o único administrador' using errcode = 'MON09';
    end if;
  end if;

  delete from public.user_site_access where user_id = p_user_id;
  delete from public.user_roles where user_id = p_user_id;

  insert into public.events (machine_id, site_id, kind, severity, message, payload)
  -- 'warning', nao 'warn': o CHECK da tabela aceita info/warning/critical.
  -- Revogar acesso e a unica das tres operacoes de usuario que merece destaque
  -- na trilha — as outras duas concedem, esta tira.
  values (null, null, 'user_access_revoked', 'warning',
          format('acesso de %s revogado por %s',
                 coalesce(v_antes.email, p_user_id::text), coalesce(v_eu::text, 'servidor')),
          jsonb_build_object('user_id', p_user_id, 'era', v_antes.role, 'por', v_eu));

  return jsonb_build_object('ok', true, 'email', v_antes.email);
end
$fn$;

-- -----------------------------------------------------------------------------
-- Registrar quem a Edge Function criou
-- -----------------------------------------------------------------------------
-- Chamada pela função com a `service_role`, DEPOIS de a conta existir no auth.
-- Não é exposta a `authenticated`: quem estiver no navegador não pode inventar
-- um par (uuid, e-mail) e se conceder papel.
create or replace function public.registrar_usuario_do_painel(
  p_user_id  uuid,
  p_email    text,
  p_nome     text,
  p_role     text,
  p_site_ids uuid[] default null,
  p_por      uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
begin
  if p_role not in ('admin', 'operator', 'viewer') then
    raise exception 'papel inválido: %', p_role using errcode = 'MON07';
  end if;

  if p_email is null or p_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$' then
    raise exception 'e-mail inválido: %', coalesce(p_email, '<nulo>') using errcode = 'MON07';
  end if;

  insert into public.user_roles (user_id, role, note, email, nome)
  values (p_user_id, p_role, 'criado pelo painel', lower(btrim(p_email)), nullif(btrim(p_nome), ''))
  on conflict (user_id) do update
    set role = excluded.role,
        email = excluded.email,
        nome = coalesce(excluded.nome, public.user_roles.nome);

  if p_site_ids is not null then
    delete from public.user_site_access where user_id = p_user_id;
    insert into public.user_site_access (user_id, site_id)
    select p_user_id, sid from unnest(p_site_ids) sid
    where exists (select 1 from public.sites s where s.id = sid)
    on conflict do nothing;
  end if;

  insert into public.events (machine_id, site_id, kind, severity, message, payload)
  values (null, null, 'user_created', 'info',
          format('usuário %s criado como %s', lower(btrim(p_email)), p_role),
          jsonb_build_object('user_id', p_user_id, 'role', p_role, 'por', p_por));

  return jsonb_build_object('ok', true, 'user_id', p_user_id);
end
$fn$;

-- -----------------------------------------------------------------------------
-- Os kinds novos
-- -----------------------------------------------------------------------------
do $$
declare v_nome text;
begin
  select c.conname into v_nome
  from pg_constraint c
  where c.conrelid = 'public.events'::regclass
    and c.contype = 'c'
    and pg_get_constraintdef(c.oid) ilike '%machine_first_seen%';
  if v_nome is not null then
    execute format('alter table public.events drop constraint %I', v_nome);
  end if;
end $$;

alter table public.events add constraint events_kind_ck check (kind in (
  'alert_open', 'alert_recovered', 'alert_notify_failed',
  'machine_provisioned', 'machine_first_seen', 'machine_renamed',
  'token_revoked', 'token_rotated',
  'partition_created', 'partition_dropped', 'retention_purge', 'rollup_run',
  'maintenance_start', 'maintenance_end',
  'agent_error', 'clock_drift', 'ingest_rejected', 'ingest_config_changed',
  'machine_removed', 'site_removed', 'demo_data_removed',
  'command_queued', 'command_result', 'command_expired', 'command_canceled',
  'machine_edited', 'site_edited',
  -- 0035
  'user_created', 'user_access_changed', 'user_access_revoked'
));

revoke all on function public.usuarios_do_painel()                             from public;
revoke all on function public.definir_acesso_usuario(uuid, text, uuid[], text) from public;
revoke all on function public.remover_acesso_usuario(uuid)                     from public;
revoke all on function public.registrar_usuario_do_painel(uuid, text, text, text, uuid[], uuid) from public;

grant execute on function public.usuarios_do_painel()                             to authenticated, service_role;
grant execute on function public.definir_acesso_usuario(uuid, text, uuid[], text) to authenticated, service_role;
grant execute on function public.remover_acesso_usuario(uuid)                     to authenticated, service_role;

-- SOMENTE service_role. Ver o comentário da função.
grant execute on function public.registrar_usuario_do_painel(uuid, text, text, text, uuid[], uuid) to service_role;
