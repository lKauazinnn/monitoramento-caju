-- =============================================================================
-- 0017 — Endereço e segredo da ingestão, guardados no servidor
-- =============================================================================
-- PROBLEMA QUE ESTA MIGRAÇÃO RESOLVE
--
-- Até aqui o dashboard montava o comando de instalação com `CFG.ingestSecret`,
-- que vinha do `dev-config.json`. Na LAN isso passa. Em produção NÃO: o
-- dashboard é um site estático, e `config.js` / `dev-config.json` são baixados
-- por qualquer um que abra a URL, ANTES de qualquer login. O segredo
-- compartilhado que a regra 6 exige para proteger a Edge Function estaria
-- publicado junto com o site.
--
-- Então o segredo passa a morar aqui, e só sai por uma função SECURITY DEFINER
-- que exige admin. Quem já pode cadastrar máquina e ver um token novo é
-- exatamente quem pode ver o segredo — não há privilégio novo sendo concedido.
--
-- POR QUE UMA TABELA NOVA E NÃO `app_settings`
--
-- `app_settings` tem `for select to authenticated using (true)`: qualquer
-- usuário autenticado lê tudo, inclusive quem só tem acesso a uma loja. Guardar
-- o segredo lá o entregaria a esse usuário. Esta tabela nasce sem policy
-- nenhuma e sem grant nenhum — negada por padrão, alcançável só por função
-- definer. Um segredo futuro herda essa proteção em vez de vazar por omissão.
-- =============================================================================

-- Uma linha só, garantida pelo CHECK. Sem isso a tabela aceitaria duas
-- configurações e nada diria qual delas vale.
create table if not exists public.ingest_config (
  id            boolean primary key default true check (id),
  ingest_url    text   not null,
  shared_secret text   not null,
  updated_at    timestamptz not null default now(),
  updated_by    text   not null default session_user,

  constraint ingest_url_absoluta check (ingest_url ~ '^https?://[^/[:space:]]+'),
  constraint segredo_com_tamanho check (length(shared_secret) >= 24)
);

comment on table public.ingest_config is
  'Endereço e segredo compartilhado da ingestão. Sem policy e sem grant de propósito: só função SECURITY DEFINER lê.';

alter table public.ingest_config enable row level security;

-- Deny-by-default explícito. `enable row level security` sem policy já nega,
-- mas o revoke garante que nem um grant futuro em `public` abra a tabela.
revoke all on public.ingest_config from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on public.ingest_config from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on public.ingest_config from authenticated';
  end if;
end
$$;

-- -----------------------------------------------------------------------------
-- Tipo de evento novo
-- -----------------------------------------------------------------------------
-- `events.kind` tem CHECK fechado, e isso é bom: erro de digitação em nome de
-- evento não passa. O preço é que um tipo novo exige alterar a restrição — e
-- alterar aqui, não editar a migração 0006, que já rodou nos bancos existentes.
alter table public.events drop constraint if exists events_kind_ck;
alter table public.events add constraint events_kind_ck check (kind in (
  'alert_open', 'alert_recovered', 'alert_notify_failed',
  'machine_provisioned', 'machine_first_seen', 'machine_renamed',
  'token_revoked', 'token_rotated',
  'partition_created', 'partition_dropped', 'retention_purge', 'rollup_run',
  'maintenance_start', 'maintenance_end',
  'agent_error', 'clock_drift', 'ingest_rejected',
  'ingest_config_changed'
));

-- -----------------------------------------------------------------------------
-- Quem pode configurar
-- -----------------------------------------------------------------------------
-- Admin pelo dashboard, ou o próprio servidor (service_role) durante o deploy.
-- O papel vem do claim do JWT; `session_user` cobre o caso de psql direto, que
-- é como o dev-up.ps1 e o SQL editor do Supabase rodam.
create or replace function public.chamador_pode_configurar_ingestao()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select public.current_user_is_admin()
      or coalesce(
           (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'),
           ''
         ) = 'service_role'
      -- psql direto (deploy, migração, SQL editor): não há JWT nenhum.
      or nullif(current_setting('request.jwt.claims', true), '') is null
$fn$;

-- -----------------------------------------------------------------------------
-- Gravar a configuração
-- -----------------------------------------------------------------------------
create or replace function public.definir_ingestao(
  p_url    text,
  p_secret text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_url    text := btrim(coalesce(p_url, ''));
  v_secret text := btrim(coalesce(p_secret, ''));
  v_ator   text := coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
                            (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'),
                            session_user);
begin
  if not public.chamador_pode_configurar_ingestao() then
    raise exception 'apenas administradores podem configurar a ingestão'
      using errcode = 'MON09';
  end if;

  -- Barra no fim quebraria a montagem do comando (`.../ingest//instalar.ps1`).
  v_url := rtrim(v_url, '/');

  if v_url !~ '^https?://[^/[:space:]]+' then
    raise exception 'endereço de ingestão inválido: %', v_url using errcode = 'MON07';
  end if;

  -- HTTP só é tolerado para endereço de rede local, e mesmo assim com aviso na
  -- resposta. Regra 9 não abre exceção para "rede interna": o que existe aqui é
  -- a fase de TESTE na LAN, que é temporária por definição.
  if v_url ~ '^http://' and v_url !~ '^http://(127\.|localhost|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' then
    raise exception 'endereço público precisa ser https: %', v_url using errcode = 'MON07';
  end if;

  if length(v_secret) < 24 then
    raise exception 'segredo compartilhado precisa de ao menos 24 caracteres (tem %)', length(v_secret)
      using errcode = 'MON07';
  end if;

  insert into public.ingest_config (id, ingest_url, shared_secret, updated_at, updated_by)
  values (true, v_url, v_secret, now(), v_ator)
  on conflict (id) do update
    set ingest_url    = excluded.ingest_url,
        shared_secret = excluded.shared_secret,
        updated_at    = now(),
        updated_by    = excluded.updated_by;

  -- O segredo NÃO entra no evento. Log que vaza credencial é pior que log
  -- ausente, porque dá a impressão de que há trilha segura.
  insert into public.events (kind, severity, message, payload)
  values ('ingest_config_changed', 'info',
          format('ingestão apontada para %s', v_url),
          jsonb_build_object('ingest_url', v_url, 'actor', v_ator,
                             'secret_len', length(v_secret)));

  return jsonb_build_object(
    'ok', true,
    'ingest_url', v_url,
    'https', v_url ~ '^https://',
    'secret_len', length(v_secret)
  );
end
$fn$;

revoke all on function public.definir_ingestao(text, text) from public;
grant execute on function public.definir_ingestao(text, text) to authenticated, service_role;

comment on function public.definir_ingestao(text, text) is
  'Define endereço e segredo da ingestão. Só admin ou service_role. Exige https fora da rede local.';

-- -----------------------------------------------------------------------------
-- Ler a configuração (só admin)
-- -----------------------------------------------------------------------------
-- Devolve o segredo. É deliberado, e é o mesmo modelo do token de máquina: quem
-- pode cadastrar já pode emitir credencial, então nada de novo se abre. Quem não
-- é admin recebe apenas o endereço, que não é segredo.
create or replace function public.ingestao_atual()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v record;
  v_admin boolean := public.current_user_is_admin();
begin
  select c.ingest_url, c.shared_secret, c.updated_at into v
  from public.ingest_config c where c.id;

  if not found then
    return jsonb_build_object('configurada', false, 'is_admin', v_admin);
  end if;

  return jsonb_build_object(
    'configurada', true,
    'is_admin', v_admin,
    'ingest_url', v.ingest_url,
    'https', v.ingest_url ~ '^https://',
    'atualizada_em', v.updated_at,
    -- Só para admin. Para o resto, ausente — não nulo por acaso, ausente por regra.
    'shared_secret', case when v_admin then v.shared_secret else null end
  );
end
$fn$;

revoke all on function public.ingestao_atual() from public;
grant execute on function public.ingestao_atual() to authenticated, service_role;

comment on function public.ingestao_atual() is
  'Endereço da ingestão para qualquer autenticado; o segredo apenas para admin.';

-- -----------------------------------------------------------------------------
-- provisionar_maquina_ui: devolve também para onde o agente deve falar
-- -----------------------------------------------------------------------------
-- O dashboard deixa de precisar do segredo em arquivo estático. Ele pede a
-- máquina, e a resposta traz token, endereço e segredo — os três de uma vez,
-- todos vindos do servidor, todos só para admin.
create or replace function public.provisionar_maquina_ui(
  p_site_code text,
  p_label     text,
  p_role_code text default 'pdv',
  p_services  text[] default null,
  p_site_name text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_site      record;
  v_brand_id  uuid;
  v_machine   uuid;
  v_token     text;
  v_prefix    text;
  v_nova_loja boolean := false;
  v_ing       record;
  v_ator      text := coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
                               (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'),
                               session_user);
begin
  -- Autorização verificada AQUI. Uma função SECURITY DEFINER que confia no
  -- cliente para decidir quem é admin não é autorização, é decoração.
  if not public.current_user_is_admin() then
    raise exception 'apenas administradores podem cadastrar máquinas'
      using errcode = 'MON09';
  end if;

  if p_label is null or length(btrim(p_label)) = 0 then
    raise exception 'informe o nome da máquina' using errcode = 'MON07';
  end if;

  if p_site_code is null or length(btrim(p_site_code)) = 0 then
    raise exception 'informe a loja' using errcode = 'MON07';
  end if;

  if not exists (select 1 from public.machine_roles r where r.code = p_role_code) then
    raise exception 'perfil inválido: %', p_role_code using errcode = 'MON07';
  end if;

  -- ------------------------------------------------------------------- loja
  select s.id, s.code, s.name into v_site
  from public.sites s
  where upper(s.code) = upper(btrim(p_site_code));

  if not found then
    -- Loja nova entra sob a marca LOCAL, criada se preciso. Sem isso, cadastrar
    -- uma máquina numa loja ainda não registrada exigiria dois passos e o
    -- operador desistiria no meio.
    insert into public.brands (code, name)
    values ('LOCAL', 'Máquinas locais')
    on conflict do nothing;

    select b.id into v_brand_id from public.brands b where upper(b.code) = 'LOCAL';

    insert into public.sites (brand_id, code, name)
    values (v_brand_id, btrim(p_site_code),
            coalesce(nullif(btrim(p_site_name), ''), btrim(p_site_code)))
    returning sites.id, sites.code, sites.name into v_site;

    v_nova_loja := true;
  end if;

  -- ---------------------------------------------------------------- máquina
  select m.id into v_machine
  from public.machines m
  where m.site_id = v_site.id and m.label = btrim(p_label);

  if v_machine is null then
    insert into public.machines (site_id, role_code, label, critical_services_override, notes)
    values (v_site.id, p_role_code, btrim(p_label),
            case when p_services is null or cardinality(p_services) = 0 then null else p_services end,
            'cadastrada pelo dashboard')
    returning machines.id into v_machine;
  else
    -- Máquina já existe: atualiza o que o operador informou e emite token novo.
    -- É o caminho de "reinstalei aquele PDV", que precisa ser simples.
    update public.machines m
       set role_code = p_role_code,
           critical_services_override =
             case when p_services is null or cardinality(p_services) = 0
                  then m.critical_services_override else p_services end,
           is_active = true
     where m.id = v_machine;
  end if;

  -- ------------------------------------------------------------------ token
  v_token  := 'mon_'
              || replace(gen_random_uuid()::text, '-', '')
              || replace(gen_random_uuid()::text, '-', '');
  v_prefix := left(v_token, 16);

  insert into public.agent_tokens (machine_id, token_prefix, token_hash, created_by)
  values (v_machine, v_prefix, sha256(convert_to(v_token, 'UTF8')), v_ator);

  insert into public.events (machine_id, site_id, kind, severity, message, payload)
  values (v_machine, v_site.id, 'machine_provisioned', 'info',
          format('cadastrada pelo dashboard: %s / %s (prefixo %s)',
                 v_site.code, btrim(p_label), v_prefix),
          jsonb_build_object('token_prefix', v_prefix, 'actor', v_ator,
                             'role', p_role_code, 'via', 'dashboard'));

  -- --------------------------------------------------------------- ingestão
  select c.ingest_url, c.shared_secret into v_ing
  from public.ingest_config c where c.id;

  return jsonb_build_object(
    'ok', true,
    'machine_id', v_machine,
    'site_code', v_site.code,
    'site_name', v_site.name,
    'site_criada', v_nova_loja,
    'label', btrim(p_label),
    'role', p_role_code,
    'token', v_token,
    'token_prefix', v_prefix,
    -- Nulos quando a ingestão ainda não foi configurada. O dashboard trata isso
    -- como erro visível em vez de gerar um comando quebrado.
    'ingest_url', v_ing.ingest_url,
    'ingest_secret', v_ing.shared_secret,
    'ingest_https', coalesce(v_ing.ingest_url ~ '^https://', false)
  );
end
$fn$;

revoke all on function public.provisionar_maquina_ui(text, text, text, text[], text) from public;
grant execute on function public.provisionar_maquina_ui(text, text, text, text[], text)
  to authenticated, service_role;

comment on function public.provisionar_maquina_ui(text, text, text, text[], text) is
  'Cadastra máquina, emite token e devolve endereço/segredo da ingestão. Só admin; o token aparece uma única vez.';

-- -----------------------------------------------------------------------------
-- opcoes_cadastro: avisa antes de o operador preencher o formulário
-- -----------------------------------------------------------------------------
-- Descobrir que a ingestão não está configurada DEPOIS de cadastrar a máquina
-- deixaria uma máquina órfã no banco e um operador sem comando para rodar.
create or replace function public.opcoes_cadastro()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select jsonb_build_object(
    'lojas', coalesce((
      select jsonb_agg(jsonb_build_object('code', s.code, 'name', s.name, 'brand', b.code)
                       order by s.code)
      from public.sites s
      join public.brands b on b.id = s.brand_id
      where s.is_active
        and s.id in (select public.current_user_site_ids())
    ), '[]'::jsonb),
    'perfis', coalesce((
      select jsonb_agg(jsonb_build_object('code', r.code, 'name', r.name,
                                          'services', r.critical_services)
                       order by r.code)
      from public.machine_roles r
    ), '[]'::jsonb),
    'is_admin', public.current_user_is_admin(),
    'ingestao', public.ingestao_atual()
  )
$fn$;

revoke all on function public.opcoes_cadastro() from public;
grant execute on function public.opcoes_cadastro() to authenticated, service_role;
