-- =============================================================================
-- 0004 — Séries temporais (particionadas por mês)
-- =============================================================================
-- Modelo LARGO (uma coluna por métrica), deliberadamente. Um modelo genérico
-- (machine_id, time, metric_name, value) produziria ~15x mais linhas, faria de
-- todo gráfico um pivot e encareceria o rollup. O conjunto de métricas de host
-- é conhecido e estável.
--
-- Discos e serviços são N por máquina e por isso ficam em tabelas próprias,
-- também particionadas, indexáveis e agregáveis.
--
-- Regra 12/13: `time` é o relógio do AGENTE em UTC e faz parte da PK, o que dá
-- idempotência natural ao reenvio de spool. `ingested_at` é o relógio do
-- SERVIDOR — a diferença entre os dois é o que permite diagnosticar relógio
-- dessincronizado sem descartar dado real.
-- =============================================================================

create table if not exists public.metrics (
  machine_id          uuid not null references public.machines(id) on delete cascade,
  time                timestamptz not null,
  ingested_at         timestamptz not null default now(),
  agent_version       text not null,
  -- Sensores que falharam ou degradaram NESTE ciclo, ex.:
  -- {temp_unavailable, smart_unavailable, cpu_raw_fallback, gw_unreachable}
  collect_flags       text[] not null default '{}',

  cpu_pct             real,
  cpu_queue_length    real,
  mem_total_mb        integer,
  mem_used_mb         integer,
  mem_pct             real,
  swap_used_mb        integer,
  uptime_seconds      bigint,
  proc_count          integer,
  thread_count        integer,
  cpu_temp_c          real,
  gw_latency_ms       real,
  gw_loss_pct         real,
  central_latency_ms  real,

  primary key (machine_id, time),

  constraint metrics_cpu_pct_ck   check (cpu_pct   is null or cpu_pct   between 0 and 100),
  constraint metrics_mem_pct_ck   check (mem_pct   is null or mem_pct   between 0 and 100),
  constraint metrics_gw_loss_ck   check (gw_loss_pct is null or gw_loss_pct between 0 and 100),
  constraint metrics_uptime_ck    check (uptime_seconds is null or uptime_seconds >= 0),
  -- Faixa larga de propósito: sensor ruim reporta 0 ou 128; a faixa só barra lixo.
  constraint metrics_temp_ck      check (cpu_temp_c is null or cpu_temp_c between -20 and 150),
  constraint metrics_agent_ver_ck check (length(agent_version) between 1 and 32)
) partition by range (time);

-- Varredura global "últimos N minutos de todas as máquinas". O acesso
-- por máquina já é servido pela PK (machine_id, time), inclusive invertida.
create index if not exists metrics_time_idx on public.metrics (time desc);

comment on column public.metrics."time" is
  'Relógio do agente em UTC (regra 12). É a chave da série — nunca substituir por now().';
comment on column public.metrics.ingested_at is
  'Relógio do servidor na gravação. time - ingested_at revela drift e reenvio de spool.';
comment on column public.metrics.agent_version is
  'Regra 25: todo dado carrega a versão do agente que o produziu.';

-- -----------------------------------------------------------------------------
-- Discos
-- -----------------------------------------------------------------------------
-- SMART via WMI (MSStorageDriver_FailurePredictStatus) entrega apenas o booleano
-- de predição de falha, e em muitos NVMe não entrega nada. As colunas
-- smart_* detalhadas só são preenchidas quando smartctl está presente.
create table if not exists public.metrics_disks (
  machine_id            uuid not null references public.machines(id) on delete cascade,
  time                  timestamptz not null,
  drive                 text not null,
  volume_label          text,
  filesystem            text,
  total_gb              numeric(12,2),
  free_gb               numeric(12,2),
  free_pct              real,
  read_latency_ms       real,
  write_latency_ms      real,
  smart_ok              boolean,
  smart_source          text,
  smart_reallocated     integer,
  smart_pending         integer,
  smart_power_on_hours  integer,
  smart_wear_pct        real,
  media_type            text,

  primary key (machine_id, time, drive),

  constraint metrics_disks_free_pct_ck check (free_pct is null or free_pct between 0 and 100),
  constraint metrics_disks_drive_ck check (length(drive) between 1 and 16),
  constraint metrics_disks_smart_source_ck check (
    smart_source is null or smart_source in ('wmi', 'smartctl', 'none')
  )
) partition by range (time);

create index if not exists metrics_disks_time_idx on public.metrics_disks (time desc);
create index if not exists metrics_disks_low_free_idx
  on public.metrics_disks (machine_id, time desc)
  where free_pct is not null and free_pct < 20;

comment on column public.metrics_disks.smart_source is
  'Origem do dado SMART. "wmi" = só predição booleana; "smartctl" = atributos completos.';

-- -----------------------------------------------------------------------------
-- Serviços críticos
-- -----------------------------------------------------------------------------
-- O campo que decide alerta é `is_running` (booleano, derivado de
-- Win32_Service.Started ou de ServiceController.Status). `state_raw` guarda a
-- string que o SO devolveu, apenas para diagnóstico — nunca use em comparação.
--
-- MEDIDO em Windows 11 pt-BR: Win32_Service.State devolve 'Running' (invariante,
-- vem do MOF). Quem É localizado é DisplayName ('Spooler de Impressão'), e por
-- isso machine_roles.critical_services guarda o nome curto do serviço. O
-- booleano é preferido não por causa de tradução, mas para não depender de a
-- tabela de enum permanecer estável nem de o agente acertar a string.
create table if not exists public.metrics_services (
  machine_id    uuid not null references public.machines(id) on delete cascade,
  time          timestamptz not null,
  service_name  text not null,
  is_running    boolean not null,
  start_mode    text,
  state_raw     text,
  pid           integer,

  primary key (machine_id, time, service_name),

  constraint metrics_services_name_ck check (length(service_name) between 1 and 128),
  -- StartMode via CIM é invariante em inglês; a faixa fechada pega erro de agente.
  constraint metrics_services_start_mode_ck check (
    start_mode is null
    or start_mode in ('Boot', 'System', 'Auto', 'Manual', 'Disabled', 'Unknown')
  )
) partition by range (time);

create index if not exists metrics_services_time_idx on public.metrics_services (time desc);
create index if not exists metrics_services_down_idx
  on public.metrics_services (machine_id, time desc)
  where not is_running;

comment on column public.metrics_services.state_raw is
  'String de estado como o SO reportou (localizada em pt-BR). Diagnóstico apenas — não comparar.';
