-- =============================================================================
-- 0002 — Marcas e lojas
-- =============================================================================

-- Usada em CHECK constraint. Rejeita fuso inexistente na criação da loja, em
-- vez de estourar meses depois dentro do relatório mensal.
create or replace function public.is_valid_timezone(p_tz text)
returns boolean
language sql
stable
set search_path = pg_catalog, pg_temp
as $fn$
  select exists (select 1 from pg_timezone_names where name = p_tz)
$fn$;

create table if not exists public.brands (
  id                uuid primary key default gen_random_uuid(),
  code              text not null,
  name              text not null,
  telegram_chat_id  text,
  notify_emails     text[] not null default '{}',
  is_active         boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint brands_code_ck check (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{1,31}$')
);

-- Unicidade case-insensitive: evita 'CJP' e 'cjp' coexistindo.
create unique index if not exists brands_code_uq on public.brands (upper(code));

drop trigger if exists brands_touch on public.brands;
create trigger brands_touch
  before update on public.brands
  for each row execute function public.touch_updated_at();

create table if not exists public.sites (
  id           uuid primary key default gen_random_uuid(),
  brand_id     uuid not null references public.brands(id) on delete restrict,
  code         text not null,
  name         text not null,
  city         text,
  state        char(2),
  timezone     text not null default 'America/Sao_Paulo',
  -- Preenchido conforme a VPN IPsec avança. O monitoramento não depende disto.
  vpn_subnet   cidr,
  gateway_ip   inet,
  is_active    boolean not null default true,
  notes        text not null default '',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),

  constraint sites_code_ck check (code ~ '^[A-Za-z0-9][A-Za-z0-9._-]{1,31}$'),
  constraint sites_timezone_ck check (public.is_valid_timezone(timezone)),
  -- Convenção do projeto de VPN: /24 único por loja dentro de 10.0.0.0/8.
  constraint sites_vpn_subnet_ck check (
    vpn_subnet is null
    or (masklen(vpn_subnet) = 24 and vpn_subnet <<= '10.0.0.0/8'::cidr)
  ),
  constraint sites_gateway_ck check (
    gateway_ip is null
    or vpn_subnet is null
    or gateway_ip <<= vpn_subnet
  )
);

create unique index if not exists sites_code_uq on public.sites (upper(code));
create unique index if not exists sites_vpn_subnet_uq on public.sites (vpn_subnet)
  where vpn_subnet is not null;
create index if not exists sites_brand_idx on public.sites (brand_id) where is_active;

drop trigger if exists sites_touch on public.sites;
create trigger sites_touch
  before update on public.sites
  for each row execute function public.touch_updated_at();

comment on column public.sites.code is
  'Código operacional da loja. Vai literalmente para o config.json do agente — mantenha estável.';
comment on column public.sites.vpn_subnet is
  'Subnet /24 da loja na VPN hub-and-spoke. Nullable: o monitoramento funciona sem VPN.';
comment on column public.brands.telegram_chat_id is
  'Chat de destino dos alertas da marca (Fase 5). O TOKEN do bot nunca fica aqui — é env var do servidor.';
