-- =============================================================================
-- Teste 05 — configuração da ingestão
-- =============================================================================
-- O que precisa ser verdade:
--   1. endereço público em HTTP é RECUSADO (regra 9)
--   2. endereço de rede local em HTTP é aceito (é a fase de teste)
--   3. segredo curto é recusado
--   4. `authenticated` NÃO alcança public.ingest_config nem por SELECT direto
--   5. quem não é admin não recebe o segredo por ingestao_atual()
--
-- PADRÃO DE NEGAÇÃO: `raise exception 'FALHA'` dentro de um bloco protegido por
-- `exception when others` é ENGOLIDO pelo próprio handler, e o teste passaria com
-- a segurança quebrada. Por isso cada negação grava um FLAG e o veredito vem
-- depois, fora do bloco.
-- =============================================================================

\set ON_ERROR_STOP on
\timing off

do $$
declare
  v_recusou boolean;
  v_url_boa text := 'http://192.168.14.222:3010';
begin
  raise notice '--- 1. endereço público em HTTP deve ser recusado ---';

  v_recusou := false;
  begin
    perform public.definir_ingestao('http://monitor.exemplo.com.br', repeat('x', 32));
  exception when others then
    v_recusou := true;
  end;

  if not v_recusou then
    raise exception 'FALHA: aceitou endereço público em HTTP (regra 9)';
  end if;
  raise notice '    ok';

  ---------------------------------------------------------------------------
  raise notice '--- 2. endereço de rede local em HTTP é aceito ---';

  perform public.definir_ingestao(v_url_boa, repeat('a', 32));

  if not exists (select 1 from public.ingest_config where ingest_url = v_url_boa) then
    raise exception 'FALHA: não gravou o endereço de rede local';
  end if;
  raise notice '    ok';

  ---------------------------------------------------------------------------
  raise notice '--- 2b. barra no fim é removida ---';

  perform public.definir_ingestao(v_url_boa || '/', repeat('a', 32));

  if exists (select 1 from public.ingest_config where ingest_url like '%/') then
    raise exception 'FALHA: manteve a barra no fim (geraria .../ /instalar.ps1)';
  end if;
  raise notice '    ok';

  ---------------------------------------------------------------------------
  raise notice '--- 3. segredo curto é recusado ---';

  v_recusou := false;
  begin
    perform public.definir_ingestao(v_url_boa, 'curto');
  exception when others then
    v_recusou := true;
  end;

  if not v_recusou then
    raise exception 'FALHA: aceitou segredo com menos de 24 caracteres';
  end if;
  raise notice '    ok';

  ---------------------------------------------------------------------------
  raise notice '--- 3b. https público é aceito ---';

  perform public.definir_ingestao('https://abc.supabase.co/functions/v1/ingest', repeat('b', 40));

  if not exists (select 1 from public.ingest_config
                 where ingest_url = 'https://abc.supabase.co/functions/v1/ingest') then
    raise exception 'FALHA: recusou https público';
  end if;
  raise notice '    ok';

  -- Volta para o endereço de teste local, para não deixar o banco de dev
  -- apontando para um projeto que não existe.
  perform public.definir_ingestao(v_url_boa, repeat('a', 32));
end
$$;

-- ---------------------------------------------------------------------------
-- 4. authenticated não alcança a tabela
-- ---------------------------------------------------------------------------
-- Verificado por PRIVILÉGIO, não por tentativa: `has_table_privilege` responde
-- sobre o grant, e é isso que precisa estar ausente. Uma tentativa de SELECT
-- poderia falhar por RLS e mascarar um grant existente.
do $$
begin
  raise notice '--- 4. authenticated sem privilégio em ingest_config ---';

  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise notice '    (papel authenticated ausente nesta instalação, pulando)';
    return;
  end if;

  if has_table_privilege('authenticated', 'public.ingest_config', 'SELECT') then
    raise exception 'FALHA: authenticated tem SELECT em ingest_config';
  end if;

  if has_table_privilege('authenticated', 'public.ingest_config', 'INSERT')
     or has_table_privilege('authenticated', 'public.ingest_config', 'UPDATE') then
    raise exception 'FALHA: authenticated escreve em ingest_config';
  end if;

  if exists (select 1 from pg_roles where rolname = 'anon')
     and has_table_privilege('anon', 'public.ingest_config', 'SELECT') then
    raise exception 'FALHA: anon tem SELECT em ingest_config';
  end if;

  raise notice '    ok';
end
$$;

-- ---------------------------------------------------------------------------
-- 5. RLS ligada e sem policy
-- ---------------------------------------------------------------------------
do $$
declare
  v_rls boolean;
  v_policies int;
begin
  raise notice '--- 5. RLS ligada e nenhuma policy ---';

  select c.relrowsecurity into v_rls
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname = 'ingest_config';

  if not coalesce(v_rls, false) then
    raise exception 'FALHA: RLS desligada em ingest_config';
  end if;

  select count(*) into v_policies from pg_policies
  where schemaname = 'public' and tablename = 'ingest_config';

  if v_policies <> 0 then
    raise exception 'FALHA: ingest_config tem % policy(ies); deve ser negada por padrão', v_policies;
  end if;

  raise notice '    ok';
end
$$;

-- ---------------------------------------------------------------------------
-- 6. ingestao_atual() não entrega o segredo para quem não é admin
-- ---------------------------------------------------------------------------
-- Em psql não há JWT, então auth.uid() é NULL e current_user_is_admin() é falso:
-- este é exatamente o caso "não admin".
do $$
declare
  v jsonb;
begin
  raise notice '--- 6. ingestao_atual() omite o segredo para não-admin ---';

  v := public.ingestao_atual();

  if (v ->> 'configurada') <> 'true' then
    raise exception 'FALHA: deveria estar configurada neste ponto do teste';
  end if;

  if (v ->> 'is_admin') = 'true' then
    raise exception 'FALHA: psql sem JWT não deveria ser admin';
  end if;

  if v ->> 'shared_secret' is not null then
    raise exception 'FALHA: entregou o segredo para quem não é admin';
  end if;

  if v ->> 'ingest_url' is null then
    raise exception 'FALHA: omitiu o endereço, que não é segredo';
  end if;

  raise notice '    ok';
end
$$;

-- ---------------------------------------------------------------------------
-- 7. provisionar_maquina_ui exige admin (e não vaza a ingestão pelo caminho)
-- ---------------------------------------------------------------------------
do $$
declare
  v_recusou boolean := false;
begin
  raise notice '--- 7. provisionar_maquina_ui recusa não-admin ---';

  begin
    perform public.provisionar_maquina_ui('BSB-001', 'TESTE-05-NAO-DEVE-EXISTIR');
  exception when others then
    v_recusou := true;
  end;

  if not v_recusou then
    raise exception 'FALHA: cadastrou máquina sem ser admin';
  end if;

  if exists (select 1 from public.machines where label = 'TESTE-05-NAO-DEVE-EXISTIR') then
    raise exception 'FALHA: máquina foi criada apesar da recusa';
  end if;

  raise notice '    ok';
end
$$;

select 'TESTE 05: TODAS AS VERIFICACOES DE CONFIG DE INGESTAO PASSARAM' as resultado;
