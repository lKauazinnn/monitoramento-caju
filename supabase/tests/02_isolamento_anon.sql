-- =============================================================================
-- Teste 02 — Isolamento da role anon e escopo do usuário autenticado
-- =============================================================================
-- Critério de aceite da Fase 1: "um select com a role anon em metrics retorna
-- vazio".
--
-- DESVIO DELIBERADO, mais forte que o pedido: além de a RLS não conceder
-- nenhuma linha, o privilégio de SELECT foi REVOGADO de anon. O resultado
-- observável passa a ser "permissão negada" em vez de "zero linhas". Isso é
-- melhor porque deixa de depender exclusivamente de RLS: um erro futuro em
-- policy não abre a tabela, porque nem o GRANT existe.
--
-- O teste aceita as duas formas de negação e falha se QUALQUER linha vazar.
--
-- Padrão usado nos testes de negação: a tentativa marca uma flag e o veredito
-- vem DEPOIS do bloco. Levantar a exceção de falha dentro do próprio bloco
-- protegido faria o handler `when others` engoli-la e o teste passaria em falso.
-- =============================================================================

\echo '== 02.1 anon não obtém linha alguma de nenhuma tabela do domínio =='
begin;
set local role anon;

do $t$
declare
  v_tabelas text[] := array[
    'metrics', 'metrics_disks', 'metrics_services',
    'metrics_hourly', 'metrics_disks_hourly',
    'machines', 'sites', 'brands', 'agent_tokens', 'events',
    'alert_rules', 'user_roles', 'user_site_access'
  ];
  v_tab    text;
  v_count  bigint;
  v_negado integer := 0;
  v_vazio  integer := 0;
  v_vazou  text[];
begin
  foreach v_tab in array v_tabelas loop
    begin
      execute format('select count(*) from public.%I', v_tab) into v_count;
      if v_count <> 0 then
        v_vazou := array_append(v_vazou, v_tab || '=' || v_count);
      else
        v_vazio := v_vazio + 1;
      end if;
    exception
      when insufficient_privilege then
        v_negado := v_negado + 1;
    end;
  end loop;

  if v_vazou is not null then
    raise exception 'FALHA CRÍTICA: anon leu linhas de: %', v_vazou;
  end if;

  raise notice 'OK: % tabela(s) com permissão negada, % com RLS devolvendo vazio',
    v_negado, v_vazio;
end
$t$;

\echo '== 02.2 anon não consegue escrever em metrics =='
do $t$
declare
  v_bloqueado boolean := false;
  v_sqlstate  text;
  v_msg       text;
begin
  begin
    execute $q$
      insert into public.metrics (machine_id, time, agent_version, cpu_pct)
      values (gen_random_uuid(), now(), 'ataque-0.0.0', 50)
    $q$;
  exception
    when others then
      v_bloqueado := true;
      v_sqlstate  := sqlstate;
      v_msg       := sqlerrm;
  end;

  if not v_bloqueado then
    raise exception 'FALHA CRÍTICA: anon inseriu linha em public.metrics';
  end if;

  raise notice 'OK: insert de anon em metrics rejeitado (%: %)', v_sqlstate, v_msg;
end
$t$;

\echo '== 02.3 anon não consegue emitir token =='
do $t$
declare
  v_bloqueado boolean := false;
  v_sqlstate  text;
begin
  begin
    execute $q$ select public.provision_machine('BSB-001', 'MAQUINA-INVASOR') $q$;
  exception
    when others then
      v_bloqueado := true;
      v_sqlstate  := sqlstate;
  end;

  if not v_bloqueado then
    raise exception 'FALHA CRÍTICA: anon executou provision_machine e obteve um token';
  end if;

  raise notice 'OK: provision_machine inacessível a anon (%)', v_sqlstate;
end
$t$;

\echo '== 02.4 anon não lê as views do dashboard =='
do $t$
declare
  v_views text[] := array[
    'machines_status', 'sites_status', 'brands_status',
    'agent_tokens_admin', 'machine_services_expected', 'open_alerts'
  ];
  v_view  text;
  v_count bigint;
  v_vazou text[];
begin
  foreach v_view in array v_views loop
    begin
      execute format('select count(*) from public.%I', v_view) into v_count;
      if v_count <> 0 then
        v_vazou := array_append(v_vazou, v_view || '=' || v_count);
      end if;
    exception
      when insufficient_privilege then
        null;
    end;
  end loop;

  if v_vazou is not null then
    raise exception 'FALHA CRÍTICA: views vazaram para anon: %', v_vazou;
  end if;

  raise notice 'OK: nenhuma view do dashboard vaza para anon';
end
$t$;

reset role;
rollback;

\echo '== 02.5 authenticated SEM escopo de loja também não vê nada =='
-- Usuário autenticado existe, mas não é admin nem tem loja em user_site_access:
-- as policies devem devolver vazio, não a base inteira.
begin;
set local role authenticated;
set local request.jwt.claim.sub = '99999999-9999-4999-8999-999999999999';

do $t$
declare
  v_maquinas bigint;
  v_metricas bigint;
  v_lojas    bigint;
begin
  select count(*) into v_maquinas from public.machines;
  select count(*) into v_metricas from public.metrics;
  select count(*) into v_lojas    from public.sites;

  if v_maquinas <> 0 or v_metricas <> 0 or v_lojas <> 0 then
    raise exception
      'FALHA: usuário sem escopo viu % loja(s), % máquina(s) e % métrica(s)',
      v_lojas, v_maquinas, v_metricas;
  end if;

  raise notice 'OK: usuário autenticado sem escopo não vê loja, máquina nem métrica';
end
$t$;

reset role;
rollback;

\echo '== 02.6 authenticated COM escopo vê só a própria loja =='
begin;

do $t$
begin
  if not exists (select 1 from public.sites where code = 'BSB-001') then
    raise exception
      'PRÉ-REQUISITO AUSENTE: rode supabase/seed/seed_demo.sql antes deste teste';
  end if;
end
$t$;

-- Escopo apenas da BSB-001 para um usuário de teste (desfeito no rollback).
insert into public.user_roles (user_id, role, note)
values ('88888888-8888-4888-8888-888888888888', 'viewer', 'fixture do teste 02.6')
on conflict (user_id) do nothing;

insert into public.user_site_access (user_id, site_id)
select '88888888-8888-4888-8888-888888888888', s.id
from public.sites s where s.code = 'BSB-001'
on conflict do nothing;

set local role authenticated;
set local request.jwt.claim.sub = '88888888-8888-4888-8888-888888888888';

do $t$
declare
  v_codigos    text[];
  v_maquinas   bigint;
  v_fora_maq   bigint;
  v_fora_met   bigint;
  -- Máquinas do seed que ficam FORA do escopo: BSB-002/PDV 01 e SP-001/gerência.
  -- Nomear o alvo explicitamente evita o teste tautológico "toda linha visível
  -- pertence a algo visível", que passa mesmo com o RLS desligado.
  v_alvo_bsb002 uuid := 'bbbbbbbb-0004-4004-8004-000000000004';
  v_alvo_sp001  uuid := 'bbbbbbbb-0005-4005-8005-000000000005';
begin
  select array_agg(s.code order by s.code) into v_codigos from public.sites s;

  if v_codigos is distinct from array['BSB-001'] then
    raise exception 'FALHA: viewer escopado viu as lojas % (esperado apenas {BSB-001})', v_codigos;
  end if;

  select count(*) into v_maquinas from public.machines;
  if v_maquinas = 0 then
    raise exception 'FALHA: viewer escopado não viu nenhuma máquina da própria loja';
  end if;

  select count(*) into v_fora_maq
  from public.machines m
  where m.id in (v_alvo_bsb002, v_alvo_sp001);

  if v_fora_maq <> 0 then
    raise exception 'FALHA: viewer da BSB-001 viu % máquina(s) de outra loja', v_fora_maq;
  end if;

  select count(*) into v_fora_met
  from public.metrics x
  where x.machine_id in (v_alvo_bsb002, v_alvo_sp001);

  if v_fora_met <> 0 then
    raise exception 'FALHA: viewer da BSB-001 viu % métrica(s) de outra loja', v_fora_met;
  end if;

  raise notice 'OK: escopo por loja funcionando (% máquina(s) visível(is), 0 vazamento)',
    v_maquinas;
end
$t$;

reset role;
rollback;

\echo '== 02 CONCLUÍDO: isolamento verificado =='
