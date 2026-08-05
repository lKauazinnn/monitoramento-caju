-- =============================================================================
-- 0014 — Login com e-mail e senha para a stack LOCAL
-- =============================================================================
-- ESCOPO: esta migration existe para a stack local (docker compose), onde não há
-- Supabase Auth. Em produção o login é o Supabase Auth e NADA aqui é usado.
--
-- COMO A DESATIVAÇÃO É GARANTIDA: local_sign_in() falha se a tabela
-- local_auth_config estiver vazia. Só o scripts/dev-up.ps1 popula essa tabela.
-- Aplicar estas migrations num projeto Supabase deixa a função presente mas
-- INERTE — não cria um caminho de autenticação paralelo ao Supabase Auth, que
-- seria um risco real.
--
-- A AUTORIZAÇÃO é a mesma nos dois ambientes: user_roles + user_site_access.
-- Só a AUTENTICAÇÃO difere. Isso é o que faz o RLS exercitado localmente ser o
-- mesmo de produção.
-- =============================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- -----------------------------------------------------------------------------
-- Configuração de assinatura do token
-- -----------------------------------------------------------------------------
-- `id boolean primary key check (id)` limita a tabela a UMA linha: dois segredos
-- em produção seriam duas verdades, e a segunda quebraria a validação no
-- PostgREST sem erro compreensível.
create table if not exists public.local_auth_config (
  id              boolean primary key default true,
  jwt_secret      text not null,
  token_ttl_hours integer not null default 12,
  updated_at      timestamptz not null default now(),
  constraint local_auth_config_uma_linha check (id),
  constraint local_auth_config_secret_ck check (length(jwt_secret) >= 32),
  constraint local_auth_config_ttl_ck check (token_ttl_hours between 1 and 720)
);

alter table public.local_auth_config enable row level security;
revoke all on public.local_auth_config from anon, authenticated;
grant all on public.local_auth_config to service_role;

-- Sem policy alguma: nem `authenticated` lê. O segredo só é acessível pelas
-- funções SECURITY DEFINER abaixo.

comment on table public.local_auth_config is
  'Segredo de assinatura do login local. Vazia => login local desligado (é o estado em produção).';

-- -----------------------------------------------------------------------------
-- Usuários locais
-- -----------------------------------------------------------------------------
create table if not exists public.app_users (
  user_id         uuid primary key default gen_random_uuid(),
  email           text not null,
  -- bcrypt (blowfish) via pgcrypto. NUNCA a senha em claro, em nenhuma coluna.
  password_hash   text not null,
  full_name       text not null default '',
  is_active       boolean not null default true,
  -- Trava de força bruta: sem isto, um formulário de login exposto é um oráculo
  -- de senha com quantas tentativas o atacante quiser.
  failed_attempts integer not null default 0,
  locked_until    timestamptz,
  last_login_at   timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  constraint app_users_email_ck check (email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  constraint app_users_hash_ck check (length(password_hash) >= 20)
);

-- Unicidade case-insensitive: e-mail não distingue caixa, e permitir
-- Kaua@x.com e kaua@x.com criaria duas contas para a mesma pessoa.
create unique index if not exists app_users_email_uq on public.app_users (lower(email));

alter table public.app_users enable row level security;
revoke all on public.app_users from anon, authenticated;
grant all on public.app_users to service_role;

drop trigger if exists app_users_touch on public.app_users;
create trigger app_users_touch
  before update on public.app_users
  for each row execute function public.touch_updated_at();

-- NENHUM privilégio de leitura para authenticated, nem para o próprio usuário.
--
-- A versão anterior concedia `grant select on app_users to authenticated` com uma
-- policy permitindo admin ver tudo. O efeito real: um admin logado no dashboard
-- baixava os hashes bcrypt de todos os usuários com
-- `GET /app_users?select=password_hash`. Hash bcrypt custo 12 não é trivial de
-- quebrar, mas entregá-lo ao navegador não tem nenhum ganho — a identidade do
-- usuário já vem nas claims do JWT e o nome vem na resposta do login.
drop policy if exists app_users_self_read on public.app_users;
revoke all on public.app_users from authenticated;

comment on table public.app_users is
  'Usuários do login LOCAL. Em produção quem guarda isso é o auth.users do Supabase.';

-- -----------------------------------------------------------------------------
-- base64url
-- -----------------------------------------------------------------------------
-- JWT usa base64url, que difere do base64 em três pontos: '+' vira '-', '/'
-- vira '_', e o preenchimento '=' é removido. Além disso encode(...,'base64')
-- do PostgreSQL quebra linha a cada 76 caracteres, e uma quebra de linha no
-- meio do token o torna inválido de um jeito difícil de perceber.
create or replace function public.b64url(p_dados bytea)
returns text
language sql
immutable
parallel safe
set search_path = pg_catalog, pg_temp
as $fn$
  select rtrim(translate(replace(encode(p_dados, 'base64'), E'\n', ''), '+/', '-_'), '=')
$fn$;

-- -----------------------------------------------------------------------------
-- local_sign_in
-- -----------------------------------------------------------------------------
-- Verifica a senha e devolve um JWT HS256 com as MESMAS claims que o Supabase
-- Auth emitiria, para que o PostgREST e as policies não saibam a diferença.
--
-- É a ÚNICA função com EXECUTE para anon, e tem de ser: quem vai fazer login
-- ainda não tem token.
--
-- POR QUE ELA DEVOLVE {ok:false} EM VEZ DE LEVANTAR EXCEÇÃO NA FALHA
-- ------------------------------------------------------------------
-- A primeira versão fazia `update ... set failed_attempts = failed_attempts + 1`
-- e em seguida `raise exception`. Não funcionava: no PostgreSQL, a exceção
-- desfaz TODO o trabalho da função, inclusive esse update. O contador voltava a
-- zero a cada tentativa e o bloqueio por força bruta era puramente decorativo —
-- um atacante tinha tentativas infinitas.
--
-- Não existe transação autônoma no PostgreSQL sem extensão (dblink,
-- pg_background). Então a falha de login PRECISA ser um retorno normal para que
-- o contador sobreviva ao commit.
--
-- Consequência: HTTP 200 também na falha. Isso não colide com a regra 14, que
-- trata da INGESTÃO: lá o agente decide apagar o spool com base no status, e um
-- 200 enganoso perderia dado. Aqui quem lê é o formulário de login, e a resposta
-- de falha NÃO CONTÉM `access_token` — um cliente que só verifique a presença do
-- token falha em segurança, não a favor.
create or replace function public.local_sign_in(
  p_email    text,
  p_password text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_cfg      record;
  v_usuario  record;
  v_agora    timestamptz := now();
  v_exp      bigint;
  v_cabecalho text;
  v_corpo    text;
  v_entrada  text;
  v_assin    text;
  -- Mensagem única para credencial inválida. Diferenciar "e-mail não existe" de
  -- "senha errada" transformaria o formulário num verificador de quais e-mails
  -- existem na empresa.
  c_invalido constant text := 'e-mail ou senha inválidos';
begin
  select * into v_cfg from public.local_auth_config where id;

  -- Estado normal em produção: sem configuração, login local não existe.
  -- Aqui a exceção é correta, porque não há contador a preservar e é erro de
  -- ambiente, não credencial errada.
  if not found then
    raise exception 'login local não está habilitado neste ambiente'
      using errcode = 'MON06',
            hint = 'Em produção use o Supabase Auth. Localmente, rode scripts/dev-up.ps1.';
  end if;

  if p_email is null or p_password is null or length(p_password) = 0 then
    return jsonb_build_object('ok', false, 'message', c_invalido);
  end if;

  select * into v_usuario
  from public.app_users u
  where lower(u.email) = lower(btrim(p_email));

  if not found or not v_usuario.is_active then
    return jsonb_build_object('ok', false, 'message', c_invalido);
  end if;

  if v_usuario.locked_until is not null and v_usuario.locked_until > v_agora then
    return jsonb_build_object(
      'ok', false,
      'message', format('conta bloqueada por tentativas repetidas; tente novamente em %s minuto(s)',
                        greatest(1, ceil(extract(epoch from (v_usuario.locked_until - v_agora)) / 60)::int)),
      'locked_until', v_usuario.locked_until
    );
  end if;

  -- crypt() rehasheia a senha recebida com o MESMO salt embutido no hash
  -- armazenado e compara. É assim que bcrypt é verificado — nunca comparando
  -- hashes calculados com salts diferentes.
  if extensions.crypt(p_password, v_usuario.password_hash) <> v_usuario.password_hash then
    update public.app_users
       set failed_attempts = failed_attempts + 1,
           -- 5 erros => 15 minutos de espera.
           locked_until = case
             when failed_attempts + 1 >= 5 then v_agora + interval '15 minutes'
             else locked_until
           end
     where app_users.user_id = v_usuario.user_id;

    return jsonb_build_object('ok', false, 'message', c_invalido);
  end if;

  update public.app_users
     set failed_attempts = 0,
         locked_until = null,
         last_login_at = v_agora
   where app_users.user_id = v_usuario.user_id;

  v_exp := extract(epoch from (v_agora + make_interval(hours => v_cfg.token_ttl_hours)))::bigint;

  v_cabecalho := public.b64url(convert_to('{"alg":"HS256","typ":"JWT"}', 'UTF8'));

  v_corpo := public.b64url(convert_to(jsonb_build_object(
    'aud',   'authenticated',
    'role',  'authenticated',
    'sub',   v_usuario.user_id::text,
    'email', v_usuario.email,
    'iat',   extract(epoch from v_agora)::bigint,
    'exp',   v_exp
  )::text, 'UTF8'));

  v_entrada := v_cabecalho || '.' || v_corpo;
  v_assin := public.b64url(extensions.hmac(v_entrada, v_cfg.jwt_secret, 'sha256'));

  return jsonb_build_object(
    'ok', true,
    'access_token', v_entrada || '.' || v_assin,
    'token_type', 'bearer',
    'expires_at', to_char(v_agora + make_interval(hours => v_cfg.token_ttl_hours),
                          'YYYY-MM-DD"T"HH24:MI:SSOF'),
    'user', jsonb_build_object(
      'id', v_usuario.user_id,
      'email', v_usuario.email,
      'full_name', v_usuario.full_name
    )
  );
end
$fn$;

-- -----------------------------------------------------------------------------
-- upsert_local_user
-- -----------------------------------------------------------------------------
-- Cria ou atualiza usuário local. A senha entra só aqui e sai como bcrypt.
--
-- Custo 12 no gen_salt: ~250 ms por verificação nesta classe de hardware. É
-- lento de propósito — é o que torna força bruta caro. Custo baixo (o padrão 6)
-- deixaria o hash quebrável em horas com GPU.
create or replace function public.upsert_local_user(
  p_email     text,
  p_password  text,
  p_full_name text default '',
  p_role      text default 'admin'
)
returns table (user_id uuid, email text, role text, criado boolean)
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
-- A função devolve uma coluna chamada `user_id`, e as tabelas alvo também têm
-- uma coluna `user_id`. Num `on conflict (user_id)` o PL/pgSQL não sabe qual é —
-- e o alvo do ON CONFLICT não aceita qualificação por alias, então não há como
-- desambiguar escrevendo `t.user_id`. Esta diretiva manda o nome resolver para a
-- COLUNA, que é o que ON CONFLICT precisa.
#variable_conflict use_column
declare
  v_id     uuid;
  v_criado boolean := false;
  v_email  text := lower(btrim(p_email));
begin
  if p_password is null or length(p_password) < 8 then
    raise exception 'senha deve ter ao menos 8 caracteres' using errcode = 'MON07';
  end if;

  if p_role not in ('admin', 'operator', 'viewer') then
    raise exception 'perfil inválido: % (admin, operator ou viewer)', p_role
      using errcode = 'MON07';
  end if;

  select u.user_id into v_id from public.app_users u where lower(u.email) = v_email;

  if v_id is null then
    insert into public.app_users (email, password_hash, full_name)
    values (v_email, extensions.crypt(p_password, extensions.gen_salt('bf', 12)), coalesce(p_full_name, ''))
    returning app_users.user_id into v_id;
    v_criado := true;
  else
    update public.app_users u
       set password_hash = extensions.crypt(p_password, extensions.gen_salt('bf', 12)),
           full_name = coalesce(nullif(p_full_name, ''), u.full_name),
           is_active = true,
           -- Trocar a senha destrava a conta: é o caminho normal de recuperação.
           failed_attempts = 0,
           locked_until = null
     where u.user_id = v_id;
  end if;

  -- A autorização vive em user_roles, a mesma tabela usada em produção.
  insert into public.user_roles (user_id, role, note)
  values (v_id, p_role, 'login local')
  on conflict (user_id) do update set role = excluded.role;

  return query select v_id, v_email, p_role, v_criado;
end
$fn$;

-- -----------------------------------------------------------------------------
-- Privilégios
-- -----------------------------------------------------------------------------
revoke all on function public.local_sign_in(text, text)                 from public;
revoke all on function public.upsert_local_user(text, text, text, text) from public;
revoke all on function public.b64url(bytea)                             from public;

-- anon PRECISA executar o login: quem vai autenticar ainda não tem token.
-- É a única concessão a anon em todo o projeto, e ela não lê nem escreve
-- nenhuma tabela de dados — só verifica credencial e assina um token.
grant execute on function public.local_sign_in(text, text) to anon, authenticated, service_role;

-- Criar usuário e trocar senha: só service_role (isto é, a TI pelo dev-up ou
-- pelo criar-usuario.ps1). Nunca exposto ao navegador.
grant execute on function public.upsert_local_user(text, text, text, text) to service_role;
grant execute on function public.b64url(bytea) to service_role;

comment on function public.local_sign_in(text, text) is
  'Login local. Inerte quando local_auth_config está vazia — que é o caso em produção.';
comment on function public.upsert_local_user(text, text, text, text) is
  'Cria/atualiza usuário local com bcrypt custo 12. A senha nunca é persistida em claro.';
