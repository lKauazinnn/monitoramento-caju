-- =============================================================================
-- 0007 — Criação e expurgo automático de partições
-- =============================================================================
-- DECISÃO: não existe partição DEFAULT. Uma default arruína o pruning do
-- planejador e trava a criação de partições novas (o PostgreSQL precisa varrer a
-- default para provar que nenhuma linha invade a faixa nova). A proteção contra
-- "sem partição para esta data" é dupla:
--   a) partições são criadas com 3 meses de folga adiante, por cron diário;
--   b) a ingestão (Fase 2) só aceita timestamp dentro de uma janela de sanidade
--      muito mais estreita que essa folga.
-- =============================================================================

-- Lista canônica de tabelas particionadas do domínio. Um único lugar para
-- adicionar a próxima série temporal.
create or replace function public.partitioned_metric_tables()
returns text[]
language sql
immutable
as $fn$
  select array['metrics', 'metrics_disks', 'metrics_services']::text[]
$fn$;

-- -----------------------------------------------------------------------------
-- Garante a partição de um mês para uma tabela pai
-- -----------------------------------------------------------------------------
create or replace function public.ensure_month_partition(
  p_parent text,
  p_month  date
)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_start date := date_trunc('month', p_month)::date;
  v_end   date := (date_trunc('month', p_month) + interval '1 month')::date;
  v_child text;
begin
  if not (p_parent = any (public.partitioned_metric_tables())) then
    raise exception 'tabela % não está na lista de particionadas', p_parent;
  end if;

  v_child := format('%s_%s', p_parent, to_char(v_start, 'YYYYMM'));

  if to_regclass(format('public.%I', v_child)) is not null then
    return 'existente';
  end if;

  begin
    execute format(
      'create table public.%I partition of public.%I for values from (%L) to (%L)',
      v_child, p_parent, v_start, v_end
    );
  exception
    -- Duas execuções concorrentes do cron, ou cron competindo com a ingestão.
    when duplicate_table then
      return 'existente';
  end;

  -- CRÍTICO: o Supabase mantém ALTER DEFAULT PRIVILEGES concedendo acesso a
  -- anon/authenticated em tabelas novas criadas por postgres. Como esta função é
  -- SECURITY DEFINER (dona: postgres), cada partição nova nasceria legível
  -- DIRETAMENTE por anon — e o RLS do pai não protege acesso direto à partição.
  -- O privilégio é revogado no mesmo ato da criação.
  execute format('revoke all on public.%I from anon, authenticated', v_child);

  insert into public.events (kind, severity, message, payload)
  values (
    'partition_created', 'info',
    format('partição %s criada para %s', v_child, to_char(v_start, 'YYYY-MM')),
    jsonb_build_object('parent', p_parent, 'partition', v_child,
                       'range_start', v_start, 'range_end', v_end)
  );

  return 'criada';
end
$fn$;

-- -----------------------------------------------------------------------------
-- Mantém a folga de partições (mês anterior até N meses adiante)
-- -----------------------------------------------------------------------------
create or replace function public.maintain_partitions(p_months_ahead integer default null)
returns table (parent text, partition_name text, action text)
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_ahead  integer := coalesce(p_months_ahead, public.app_setting_int('partition_months_ahead'));
  v_parent text;
  v_month  date;
  v_action text;
begin
  if v_ahead < 1 or v_ahead > 24 then
    raise exception 'partition_months_ahead fora da faixa aceitável (1..24): %', v_ahead;
  end if;

  foreach v_parent in array public.partitioned_metric_tables() loop
    -- Começa em -1 mês para cobrir reenvio de spool virando o mês.
    for i in -1 .. v_ahead loop
      v_month := (date_trunc('month', now()) + make_interval(months => i))::date;
      v_action := public.ensure_month_partition(v_parent, v_month);
      return query
        select v_parent,
               format('%s_%s', v_parent, to_char(date_trunc('month', v_month), 'YYYYMM')),
               v_action;
    end loop;
  end loop;
end
$fn$;

-- -----------------------------------------------------------------------------
-- Expurgo da série bruta por DROP de partição
-- -----------------------------------------------------------------------------
-- Granularidade mensal implica retenção efetiva entre N e N+31 dias: uma
-- partição só cai quando o MÊS INTEIRO está fora da janela. Nunca retém menos
-- que o configurado — apenas, às vezes, mais.
create or replace function public.drop_old_partitions(p_retention_days integer default null)
returns table (partition_name text, action text)
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_retention integer := coalesce(p_retention_days, public.app_setting_int('metrics_retention_days'));
  v_cutoff    date;
  r           record;
begin
  -- Trava de segurança: erro de digitação em app_settings não pode apagar tudo.
  if v_retention < 7 then
    raise exception 'retenção mínima é 7 dias (recebido %). Ajuste app_settings.metrics_retention_days.', v_retention;
  end if;

  v_cutoff := date_trunc('month', now() - make_interval(days => v_retention))::date;

  for r in
    -- Cast obrigatório: pg_class.relname é do tipo `name`, e RETURN QUERY
    -- rejeita name onde a assinatura declara text.
    select c.relname::text as child, p.relname::text as parent
    from pg_inherits i
    join pg_class c on c.oid = i.inhrelid
    join pg_class p on p.oid = i.inhparent
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and p.relname = any (public.partitioned_metric_tables())
      and c.relname ~ '_[0-9]{6}$'
      and to_date(right(c.relname, 6), 'YYYYMM') < v_cutoff
    order by c.relname
  loop
    execute format('drop table public.%I', r.child);

    insert into public.events (kind, severity, message, payload)
    values (
      'partition_dropped', 'info',
      format('partição %s removida (retenção de %s dias)', r.child, v_retention),
      jsonb_build_object('parent', r.parent, 'partition', r.child, 'retention_days', v_retention)
    );

    return query select r.child, 'removida'::text;
  end loop;
end
$fn$;

-- -----------------------------------------------------------------------------
-- Expurgo das tabelas não particionadas
-- -----------------------------------------------------------------------------
create or replace function public.purge_aggregates()
returns table (target text, rows_deleted bigint)
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_hourly_days integer := public.app_setting_int('metrics_hourly_retention_days');
  v_events_days integer := public.app_setting_int('events_retention_days');
  v_count       bigint;
begin
  if v_hourly_days < 31 then
    raise exception 'retenção do rollup horário mínima é 31 dias (recebido %)', v_hourly_days;
  end if;

  delete from public.metrics_hourly where hour < now() - make_interval(days => v_hourly_days);
  get diagnostics v_count = row_count;
  return query select 'metrics_hourly'::text, v_count;

  delete from public.metrics_disks_hourly where hour < now() - make_interval(days => v_hourly_days);
  get diagnostics v_count = row_count;
  return query select 'metrics_disks_hourly'::text, v_count;

  -- Alerta ainda aberto nunca é expurgado, por antigo que seja.
  delete from public.events
  where opened_at < now() - make_interval(days => v_events_days)
    and (resolved_at is not null or kind <> 'alert_open');
  get diagnostics v_count = row_count;
  return query select 'events'::text, v_count;
end
$fn$;

-- -----------------------------------------------------------------------------
-- Ponto único chamado pelo cron
-- -----------------------------------------------------------------------------
create or replace function public.run_maintenance()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_created  integer;
  v_dropped  integer;
  v_purged   jsonb;
begin
  select count(*) into v_created
  from public.maintain_partitions() where action = 'criada';

  select count(*) into v_dropped
  from public.drop_old_partitions();

  select jsonb_object_agg(target, rows_deleted) into v_purged
  from public.purge_aggregates();

  return jsonb_build_object(
    'ran_at', now(),
    'partitions_created', v_created,
    'partitions_dropped', v_dropped,
    'purged', coalesce(v_purged, '{}'::jsonb)
  );
end
$fn$;

comment on function public.run_maintenance() is
  'Chamada pelo pg_cron: cria partições futuras, remove expiradas e expurga agregados.';

-- Cria as partições necessárias já nesta migration, para que a ingestão
-- funcione antes do primeiro disparo do cron.
select public.maintain_partitions();
