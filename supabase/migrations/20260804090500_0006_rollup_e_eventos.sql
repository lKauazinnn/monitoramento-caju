-- =============================================================================
-- 0006 — Rollup horário e trilha de eventos
-- =============================================================================
-- O rollup não é particionado: com 600 máquinas e 13 meses são ~5,6M linhas,
-- confortáveis em tabela única. O expurgo aqui é por DELETE, não por DROP.

create table if not exists public.metrics_hourly (
  machine_id          uuid not null references public.machines(id) on delete cascade,
  hour                timestamptz not null,
  samples             integer not null,
  -- Amostras esperadas na hora, derivado de agent_interval_seconds. Guardado
  -- junto porque o intervalo pode mudar e a disponibilidade histórica não deve.
  samples_expected    integer not null,
  cpu_avg             real,
  cpu_max             real,
  cpu_p95             real,
  mem_avg             real,
  mem_max             real,
  temp_avg            real,
  temp_max            real,
  gw_latency_avg      real,
  gw_latency_max      real,
  gw_loss_avg         real,
  uptime_max          bigint,
  disk_min_free_pct   real,
  reboot_count        smallint not null default 0,
  service_down_count  smallint not null default 0,
  computed_at         timestamptz not null default now(),

  primary key (machine_id, hour),
  -- Múltiplo exato de hora. Escrito sobre epoch (imutável e independente de
  -- fuso) e não com date_trunc, que é STABLE e depende do TimeZone da sessão.
  constraint metrics_hourly_hour_ck check (extract(epoch from hour)::bigint % 3600 = 0),
  constraint metrics_hourly_samples_ck check (samples >= 0 and samples_expected > 0)
);

create index if not exists metrics_hourly_hour_idx on public.metrics_hourly (hour desc);

comment on column public.metrics_hourly.samples_expected is
  'Base do cálculo de disponibilidade: samples / samples_expected (limitado a 1).';

-- Projeção de disco cheio (Fase 7) precisa da tendência POR unidade.
create table if not exists public.metrics_disks_hourly (
  machine_id   uuid not null references public.machines(id) on delete cascade,
  hour         timestamptz not null,
  drive        text not null,
  total_gb     numeric(12,2),
  free_gb_avg  numeric(12,2),
  free_gb_min  numeric(12,2),
  free_pct_min real,
  samples      integer not null,
  computed_at  timestamptz not null default now(),

  primary key (machine_id, hour, drive),
  constraint metrics_disks_hourly_hour_ck check (extract(epoch from hour)::bigint % 3600 = 0)
);

create index if not exists metrics_disks_hourly_hour_idx on public.metrics_disks_hourly (hour desc);

-- -----------------------------------------------------------------------------
-- Eventos: trilha única de alertas e de operação
-- -----------------------------------------------------------------------------
create table if not exists public.events (
  id               bigint generated always as identity primary key,
  machine_id       uuid references public.machines(id) on delete cascade,
  site_id          uuid references public.sites(id) on delete cascade,
  rule_id          uuid references public.alert_rules(id) on delete set null,
  kind             text not null,
  severity         text not null default 'info',
  metric           text,
  value            numeric,
  threshold        numeric,
  message          text not null,
  opened_at        timestamptz not null default now(),
  resolved_at      timestamptz,
  notified_at      timestamptz,
  notify_attempts  smallint not null default 0,
  notify_error     text,
  acknowledged_by  uuid,
  acknowledged_at  timestamptz,
  payload          jsonb not null default '{}'::jsonb,

  constraint events_kind_ck check (kind in (
    'alert_open', 'alert_recovered', 'alert_notify_failed',
    'machine_provisioned', 'machine_first_seen', 'machine_renamed',
    'token_revoked', 'token_rotated',
    'partition_created', 'partition_dropped', 'retention_purge', 'rollup_run',
    'maintenance_start', 'maintenance_end',
    'agent_error', 'clock_drift', 'ingest_rejected'
  )),
  constraint events_severity_ck check (severity in ('info', 'warning', 'critical')),
  constraint events_resolved_ck check (resolved_at is null or resolved_at >= opened_at)
);

-- Consulta de "alerta aberto para esta máquina/regra" na avaliação do cron.
create index if not exists events_open_alerts_idx
  on public.events (machine_id, rule_id)
  where kind = 'alert_open' and resolved_at is null;

create index if not exists events_machine_time_idx on public.events (machine_id, opened_at desc);
create index if not exists events_site_time_idx on public.events (site_id, opened_at desc);
create index if not exists events_kind_time_idx on public.events (kind, opened_at desc);
create index if not exists events_pending_notify_idx
  on public.events (opened_at)
  where notified_at is null and kind in ('alert_open', 'alert_recovered');

comment on table public.events is
  'Alertas e operação na mesma trilha. Alerta aberto = kind alert_open com resolved_at nulo.';
comment on column public.events.payload is
  'Contexto adicional livre (partição removida, corpo da notificação, etc). Nunca segredo.';
