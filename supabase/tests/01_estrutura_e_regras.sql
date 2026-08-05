-- =============================================================================
-- Teste 01 — Estrutura e conformidade com as regras inegociáveis
-- =============================================================================
-- Cada bloco falha com RAISE EXCEPTION. Rode com psql -v ON_ERROR_STOP=1:
-- se o script terminar, tudo passou.
--
-- Estes testes são guardas permanentes, não checagens de uma vez: qualquer
-- migration futura que viole uma regra faz este arquivo falhar.
-- =============================================================================

\echo '== 01.1 Tabelas esperadas existem e têm RLS habilitada =='
do $t$
declare
  v_esperadas text[] := array[
    'app_settings', 'brands', 'sites', 'machine_roles', 'machines',
    'agent_tokens', 'user_roles', 'user_site_access',
    'metrics', 'metrics_disks', 'metrics_services',
    'metrics_hourly', 'metrics_disks_hourly',
    'alert_rules', 'events'
  ];
  v_faltando text[];
  v_sem_rls  text[];
begin
  select array_agg(e) into v_faltando
  from unnest(v_esperadas) e
  where to_regclass('public.' || e) is null;

  if v_faltando is not null then
    raise exception 'FALHA: tabelas ausentes: %', v_faltando;
  end if;

  select array_agg(c.relname order by c.relname) into v_sem_rls
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname = any (v_esperadas)
    and not c.relrowsecurity;

  if v_sem_rls is not null then
    raise exception 'FALHA: RLS desabilitada em: %', v_sem_rls;
  end if;

  raise notice 'OK: % tabelas presentes, todas com RLS', cardinality(v_esperadas);
end
$t$;

\echo '== 01.2 Regra 5: toda view leva security_invoker = true =='
do $t$
declare
  v_ruins text[];
begin
  select array_agg(c.relname order by c.relname) into v_ruins
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind = 'v'
    and not (coalesce(c.reloptions, '{}'::text[]) @> array['security_invoker=true']);

  if v_ruins is not null then
    raise exception 'FALHA (regra 5): views sem security_invoker: %', v_ruins;
  end if;

  raise notice 'OK: todas as views com security_invoker';
end
$t$;

\echo '== 01.3 Regra 4: toda função SECURITY DEFINER fixa search_path =='
do $t$
declare
  v_ruins text[];
begin
  select array_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
                   order by p.proname) into v_ruins
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prosecdef
    and not exists (
      select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) cfg
      where cfg like 'search_path=%'
    );

  if v_ruins is not null then
    raise exception 'FALHA (regra 4): SECURITY DEFINER sem search_path: %', v_ruins;
  end if;

  raise notice 'OK: todas as SECURITY DEFINER com search_path fixo';
end
$t$;

\echo '== 01.4 Regra 3: nenhuma policy de escrita para anon/PUBLIC =='
do $t$
declare
  v_ruins text[];
begin
  -- polcmd é do tipo "char" (não text): sem o cast, `text || "char"` é ambíguo.
  select array_agg(
    pol.polrelid::regclass::text || '.' || pol.polname ||
    ' [cmd=' || pol.polcmd::text || ']' order by pol.polname
  ) into v_ruins
  from pg_policy pol
  where pol.polcmd <> 'r'  -- 'r' = SELECT
    and (
      -- polroles = {0} significa PUBLIC
      0 = any (pol.polroles)
      or exists (
        select 1 from pg_roles r
        where r.oid = any (pol.polroles) and r.rolname = 'anon'
      )
    );

  if v_ruins is not null then
    raise exception 'FALHA (regra 3): policy de escrita exposta a anon/PUBLIC: %', v_ruins;
  end if;

  raise notice 'OK: nenhuma policy de escrita para anon/PUBLIC';
end
$t$;

\echo '== 01.5 Regra 3: séries temporais não têm NENHUMA policy de escrita =='
do $t$
declare
  v_series text[] := array[
    'metrics', 'metrics_disks', 'metrics_services',
    'metrics_hourly', 'metrics_disks_hourly', 'agent_tokens'
  ];
  v_ruins text[];
begin
  -- Comparação por OID, não por texto: polrelid::regclass::text abreviaria para
  -- "metrics" quando public está no search_path, e o teste passaria em falso.
  select array_agg(pol.polrelid::regclass::text || '.' || pol.polname) into v_ruins
  from pg_policy pol
  where pol.polrelid = any (
          select ('public.' || s)::regclass from unnest(v_series) s
        )
    and pol.polcmd <> 'r';

  if v_ruins is not null then
    raise exception 'FALHA: policy de escrita em série temporal/token: %', v_ruins;
  end if;

  raise notice 'OK: escrita em série temporal só por função servidor';
end
$t$;

\echo '== 01.6 Role anon não tem privilégio em nenhuma tabela de public =='
do $t$
declare
  v_ruins text[];
begin
  select array_agg(distinct g.table_name || ':' || g.privilege_type) into v_ruins
  from information_schema.role_table_grants g
  where g.grantee = 'anon' and g.table_schema = 'public';

  if v_ruins is not null then
    raise exception 'FALHA: anon tem privilégios em public: %', v_ruins;
  end if;

  raise notice 'OK: anon sem privilégio de tabela em public';
end
$t$;

\echo '== 01.7 anon não pode executar provisionamento nem revogação =='
do $t$
declare
  v_ruins text[];
begin
  select array_agg(f) into v_ruins
  from unnest(array[
    'public.provision_machine(text,text,text,text,boolean)',
    'public.revoke_agent_token(text,text)',
    'public.verify_agent_token(text)',
    'public.touch_agent_token(bytea)',
    'public.run_maintenance()',
    'public.drop_old_partitions(integer)'
  ]) f
  where has_function_privilege('anon', f, 'EXECUTE');

  if v_ruins is not null then
    raise exception 'FALHA: anon pode executar: %', v_ruins;
  end if;

  raise notice 'OK: anon sem EXECUTE nas funções sensíveis';
end
$t$;

\echo '== 01.8 Partições existem para o mês atual e para a folga futura =='
do $t$
declare
  v_parent  text;
  v_esperado integer := public.app_setting_int('partition_months_ahead') + 2; -- -1 .. +N
  v_qtd     integer;
  v_mes_atual text;
begin
  foreach v_parent in array public.partitioned_metric_tables() loop
    select count(*) into v_qtd
    from pg_inherits i
    join pg_class c on c.oid = i.inhrelid
    join pg_class p on p.oid = i.inhparent
    where p.relname = v_parent;

    if v_qtd < v_esperado then
      raise exception 'FALHA: % tem % partições, esperado ao menos %',
        v_parent, v_qtd, v_esperado;
    end if;

    v_mes_atual := format('%s_%s', v_parent, to_char(now(), 'YYYYMM'));
    if to_regclass('public.' || v_mes_atual) is null then
      raise exception 'FALHA: partição do mês atual ausente: %', v_mes_atual;
    end if;
  end loop;

  raise notice 'OK: partições do mês atual e folga futura presentes';
end
$t$;

\echo '== 01.9 Partições não são acessíveis diretamente por anon/authenticated =='
do $t$
declare
  v_ruins text[];
begin
  select array_agg(c.relname || ':' || r.rolname order by c.relname) into v_ruins
  from pg_inherits i
  join pg_class c on c.oid = i.inhrelid
  join pg_class p on p.oid = i.inhparent
  cross join (select rolname from pg_roles where rolname in ('anon', 'authenticated')) r
  where p.relname = any (public.partitioned_metric_tables())
    and has_table_privilege(r.rolname, c.oid, 'SELECT');

  if v_ruins is not null then
    raise exception
      'FALHA: partição legível diretamente (contorna as policies do pai): %', v_ruins;
  end if;

  raise notice 'OK: partições inacessíveis fora do pai';
end
$t$;

\echo '== 01.10 Regra 23: offline_timeout tem fonte única e é usado pela view =='
do $t$
declare
  v_def text;
begin
  if public.app_setting_int('offline_timeout_seconds') is null then
    raise exception 'FALHA: offline_timeout_seconds ausente em app_settings';
  end if;

  select pg_get_viewdef('public.machines_status'::regclass) into v_def;

  if v_def not like '%offline_cutoff%' then
    raise exception
      'FALHA (regra 23): machines_status não usa offline_cutoff() — há um segundo timeout escondido na view';
  end if;

  -- Nenhum literal de minuto/segundo cravado na definição da view.
  if v_def ~* 'interval\s+''\s*\d+\s*(min|sec)' then
    raise exception
      'FALHA (regra 23): machines_status contém intervalo literal em vez de ler app_settings';
  end if;

  raise notice 'OK: timeout de offline com fonte única';
end
$t$;

\echo '== 01.11 Regra 12: metrics tem time do agente E ingested_at do servidor =='
do $t$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'metrics'
      and column_name = 'ingested_at' and column_default like '%now()%'
  ) then
    raise exception 'FALHA: metrics.ingested_at ausente ou sem default now()';
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'metrics'
      and column_name = 'time' and column_default is not null
  ) then
    raise exception
      'FALHA (regra 12): metrics.time tem default — o timestamp deve vir sempre do agente';
  end if;

  -- Regra 13: idempotência depende da PK (machine_id, time).
  if not exists (
    select 1
    from pg_constraint c
    where c.conrelid = 'public.metrics'::regclass
      and c.contype = 'p'
      and (
        -- attname é do tipo `name`: sem o cast, name[] = text[] não existe.
        select array_agg(a.attname::text order by a.attname::text)
        from unnest(c.conkey) k
        join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k
      ) = array['machine_id', 'time']
  ) then
    raise exception 'FALHA (regra 13): PK de metrics não é (machine_id, time)';
  end if;

  raise notice 'OK: modelo temporal e chave de idempotência corretos';
end
$t$;

\echo '== 01.12 Regra 25: agent_version é obrigatório em metrics =='
do $t$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'metrics'
      and column_name = 'agent_version' and is_nullable = 'YES'
  ) then
    raise exception 'FALHA (regra 25): metrics.agent_version aceita null';
  end if;
  raise notice 'OK: toda amostra carrega a versão do agente';
end
$t$;

\echo '== 01 CONCLUÍDO: estrutura conforme =='
