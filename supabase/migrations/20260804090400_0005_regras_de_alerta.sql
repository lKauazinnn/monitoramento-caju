-- =============================================================================
-- 0005 — Regras de alerta configuráveis (avaliação é Fase 5)
-- =============================================================================

create table if not exists public.alert_rules (
  id                  uuid primary key default gen_random_uuid(),
  name                text not null,
  kind                text not null,
  scope               text not null,
  brand_id            uuid references public.brands(id) on delete cascade,
  site_id             uuid references public.sites(id) on delete cascade,
  machine_id          uuid references public.machines(id) on delete cascade,
  role_code           text references public.machine_roles(code) on delete cascade,

  threshold           numeric,
  comparator          text not null default '>',
  -- Histerese: N ciclos consecutivos violando antes de abrir alerta.
  consecutive_cycles  integer not null default 3,
  -- Janela de silêncio: não reabre o mesmo alerta antes disso (anti-spam).
  cooldown_minutes    integer not null default 60,
  severity            text not null default 'warning',
  channels            text[] not null default '{telegram}',
  is_active           boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),

  constraint alert_rules_kind_ck check (kind in (
    'offline', 'cpu_sustained', 'mem_high', 'disk_low',
    'temp_high', 'service_down', 'clock_drift', 'smart_failing'
  )),
  constraint alert_rules_scope_ck check (scope in ('global', 'brand', 'site', 'machine', 'role')),
  constraint alert_rules_comparator_ck check (comparator in ('>', '>=', '<', '<=')),
  constraint alert_rules_severity_ck check (severity in ('info', 'warning', 'critical')),
  constraint alert_rules_cycles_ck check (consecutive_cycles between 1 and 60),
  constraint alert_rules_cooldown_ck check (cooldown_minutes between 0 and 10080),
  constraint alert_rules_channels_ck check (
    channels <@ array['telegram', 'email']::text[] and cardinality(channels) > 0
  ),

  -- Cada escopo preenche exatamente a sua coluna e nenhuma outra.
  constraint alert_rules_scope_columns_ck check (
    case scope
      when 'global'  then brand_id is null and site_id is null and machine_id is null and role_code is null
      when 'brand'   then brand_id is not null and site_id is null and machine_id is null and role_code is null
      when 'site'    then site_id  is not null and brand_id is null and machine_id is null and role_code is null
      when 'machine' then machine_id is not null and brand_id is null and site_id is null and role_code is null
      when 'role'    then role_code is not null and brand_id is null and site_id is null and machine_id is null
    end
  ),

  -- Regra 23 aplicada pelo SCHEMA: alerta de offline não tem limiar próprio.
  -- O tempo de offline é app_settings.offline_timeout_seconds, e ponto.
  constraint alert_rules_offline_no_threshold_ck check (
    kind <> 'offline' or threshold is null
  ),
  -- Os demais tipos numéricos exigem limiar.
  constraint alert_rules_threshold_required_ck check (
    kind in ('offline', 'service_down', 'smart_failing') or threshold is not null
  )
);

-- Impede duas regras globais ativas do mesmo tipo brigando entre si.
create unique index if not exists alert_rules_global_uq
  on public.alert_rules (kind) where scope = 'global' and is_active;

create index if not exists alert_rules_lookup_idx
  on public.alert_rules (kind, scope) where is_active;

drop trigger if exists alert_rules_touch on public.alert_rules;
create trigger alert_rules_touch
  before update on public.alert_rules
  for each row execute function public.touch_updated_at();

-- Regras globais de partida. Limiares conservadores de propósito: é mais fácil
-- afrouxar depois do primeiro falso positivo do que descobrir que nunca alertou.
insert into public.alert_rules (name, kind, scope, threshold, comparator, consecutive_cycles, cooldown_minutes, severity, channels)
select * from (values
  ('Máquina offline',          'offline',       'global', null::numeric, '>',  1,  30, 'critical', array['telegram']),
  ('CPU sustentada acima de 90%', 'cpu_sustained', 'global', 90,          '>=', 10, 60, 'warning',  array['telegram']),
  ('Memória acima de 92%',     'mem_high',      'global', 92,            '>=', 15, 120, 'warning', array['telegram']),
  ('Disco com menos de 10% livre', 'disk_low',  'global', 10,            '<',  3,  720, 'critical', array['telegram']),
  ('Temperatura acima de 85 C', 'temp_high',    'global', 85,            '>=', 5,  60, 'warning',  array['telegram']),
  ('Serviço crítico parado',   'service_down',  'global', null::numeric, '>',  2,  60, 'critical', array['telegram']),
  ('Relógio dessincronizado',  'clock_drift',   'global', 120,           '>=', 5,  1440, 'warning', array['telegram']),
  ('SMART prevendo falha',     'smart_failing', 'global', null::numeric, '>',  1,  1440, 'critical', array['telegram'])
) as v(name, kind, scope, threshold, comparator, consecutive_cycles, cooldown_minutes, severity, channels)
where not exists (
  select 1 from public.alert_rules ar
  where ar.scope = 'global' and ar.kind = v.kind
);

comment on column public.alert_rules.consecutive_cycles is
  'Histerese em ciclos de coleta (app_settings.agent_interval_seconds), não em minutos.';
comment on constraint alert_rules_offline_no_threshold_ck on public.alert_rules is
  'Regra 23: o tempo de offline tem uma única fonte, app_settings.offline_timeout_seconds.';
