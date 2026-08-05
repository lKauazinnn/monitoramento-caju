-- =============================================================================
-- 0003 — Máquinas, tokens de agente e escopo de acesso de usuário
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Perfis de máquina e serviços críticos esperados
-- -----------------------------------------------------------------------------
-- ATENÇÃO: `critical_services` guarda o NOME CURTO do serviço Windows
-- (ServiceName, ex. 'Spooler'), nunca o DisplayName — o DisplayName é
-- localizado em pt-BR e quebraria a comparação (mesmo problema da regra 10).
create table if not exists public.machine_roles (
  code              text primary key,
  name              text not null,
  critical_services  text[] not null default '{}',
  created_at        timestamptz not null default now()
);

insert into public.machine_roles (code, name, critical_services) values
  ('pdv',    'Ponto de venda', '{Spooler}'),
  ('server', 'Servidor de loja', '{}'),
  ('admin',  'Estação administrativa', '{}')
on conflict (code) do nothing;

comment on column public.machine_roles.critical_services is
  'PLACEHOLDER a confirmar: só o Spooler foi semeado (impressão de cupom no PDV). '
  'Preencher com os nomes curtos dos serviços do ERP/PDV antes da Fase 5.';

-- -----------------------------------------------------------------------------
-- Máquinas
-- -----------------------------------------------------------------------------
-- Regra 11: a identidade é o GUID em `id`, gerado no provisionamento e imutável.
-- `hostname` é ATRIBUTO — a máquina pode ser renomeada sem perder a série.
create table if not exists public.machines (
  id                          uuid primary key default gen_random_uuid(),
  site_id                     uuid not null references public.sites(id) on delete restrict,
  role_code                   text not null references public.machine_roles(code) on delete restrict,
  label                       text not null,
  hostname                    text,
  os_caption                  text,
  os_version                  text,
  os_arch                     text,
  cpu_model                   text,
  cpu_cores                   smallint,
  mem_total_mb                integer,
  agent_version               text,
  ip_lan                      inet,
  last_seen_at                timestamptz,
  last_boot_at                timestamptz,
  -- Diferença observada entre o relógio do agente e o do servidor. Permite
  -- distinguir "link caiu e o spool foi reenviado" de "relógio quebrado".
  clock_drift_seconds         integer,
  is_active                   boolean not null default true,
  maintenance_until           timestamptz,
  maintenance_reason          text,
  critical_services_override  text[],
  notes                       text not null default '',
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now(),

  constraint machines_label_ck check (length(btrim(label)) between 1 and 64),
  unique (site_id, label)
);

create index if not exists machines_site_idx on public.machines (site_id) where is_active;
create index if not exists machines_last_seen_idx on public.machines (last_seen_at desc nulls first);
create index if not exists machines_hostname_idx on public.machines (lower(hostname))
  where hostname is not null;

drop trigger if exists machines_touch on public.machines;
create trigger machines_touch
  before update on public.machines
  for each row execute function public.touch_updated_at();

comment on column public.machines.id is
  'GUID persistido, identidade estável da máquina (regra 11). Nunca use hostname como chave.';
comment on column public.machines.maintenance_until is
  'Janela de manutenção: enquanto no futuro, alertas ficam silenciados (Fase 5).';
comment on column public.machines.critical_services_override is
  'Quando não nulo, substitui integralmente a lista do perfil. Nomes curtos de serviço.';

-- -----------------------------------------------------------------------------
-- Tokens de agente (regra 2)
-- -----------------------------------------------------------------------------
-- Só o SHA-256 é persistido. O texto claro existe uma única vez, no retorno de
-- provision_machine(). Não há caminho de recuperação — perdeu, rotaciona.
--
-- SHA-256 puro (sem salt, sem KDF lento) é adequado AQUI porque o token tem 244
-- bits de entropia gerada pelo servidor: não há dicionário a percorrer. Isto
-- NÃO valeria para senha de usuário.
create table if not exists public.agent_tokens (
  id              uuid primary key default gen_random_uuid(),
  machine_id      uuid not null references public.machines(id) on delete cascade,
  token_prefix    text not null,
  token_hash      bytea not null,
  created_at      timestamptz not null default now(),
  created_by      text not null default current_user,
  expires_at      timestamptz,
  revoked_at      timestamptz,
  revoked_reason  text,
  last_used_at    timestamptz,
  use_count       bigint not null default 0,

  constraint agent_tokens_hash_len_ck check (octet_length(token_hash) = 32),
  constraint agent_tokens_prefix_ck check (length(token_prefix) between 8 and 24)
);

create unique index if not exists agent_tokens_hash_uq on public.agent_tokens (token_hash);
-- Prefixo único: são 12 dígitos hex (2,8e14 combinações), então colisão é
-- desprezível e o operador pode revogar por prefixo sem ambiguidade.
create unique index if not exists agent_tokens_prefix_uq on public.agent_tokens (token_prefix);
-- Índice de trabalho da ingestão: lookup por hash já é coberto pelo unique acima.
create index if not exists agent_tokens_machine_idx on public.agent_tokens (machine_id)
  where revoked_at is null;

-- Deliberadamente NÃO existe unique parcial "um token ativo por máquina":
-- rotação sem downtime exige sobreposição (instala o novo, confirma o
-- heartbeat, só então revoga o antigo). A view agent_tokens_admin expõe a
-- contagem de tokens ativos para que sobra esquecida fique visível.

comment on table public.agent_tokens is
  'Credencial por máquina. Apenas hash SHA-256; revogação individual via revoke_agent_token().';

-- -----------------------------------------------------------------------------
-- Escopo de acesso do dashboard
-- -----------------------------------------------------------------------------
-- Sem FK para auth.users: mantém as migrations executáveis em PostgreSQL puro
-- para o teste de idempotência. A integridade é garantida na concessão.
create table if not exists public.user_roles (
  user_id     uuid primary key,
  role        text not null,
  note        text not null default '',
  created_at  timestamptz not null default now(),
  constraint user_roles_role_ck check (role in ('admin', 'operator', 'viewer'))
);

create table if not exists public.user_site_access (
  user_id     uuid not null,
  site_id     uuid not null references public.sites(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, site_id)
);

create index if not exists user_site_access_site_idx on public.user_site_access (site_id);

comment on table public.user_roles is
  'admin = vê tudo e administra cadastro. operator = vê o escopo e silencia alertas. viewer = só leitura.';
comment on table public.user_site_access is
  'Escopo de lojas do usuário. Ignorado para admin (que vê todas as lojas).';

-- -----------------------------------------------------------------------------
-- Helpers de autorização (usados pelas policies em 0010)
-- -----------------------------------------------------------------------------
create or replace function public.current_user_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select exists (
    select 1 from public.user_roles
    where user_id = auth.uid() and role = 'admin'
  )
$fn$;

create or replace function public.current_user_site_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select s.id from public.sites s where public.current_user_is_admin()
  union
  select a.site_id from public.user_site_access a where a.user_id = auth.uid()
$fn$;

-- Lista efetiva de serviços críticos: override da máquina vence o perfil.
create or replace function public.effective_critical_services(p_machine_id uuid)
returns text[]
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select coalesce(m.critical_services_override, r.critical_services)
  from public.machines m
  join public.machine_roles r on r.code = m.role_code
  where m.id = p_machine_id
$fn$;
