-- =============================================================================
-- 0018 — Dados do centro de operações
-- =============================================================================
-- A interface nova (barra lateral com pulso de ingestão, faixa de KPIs com
-- sparkline, gráfico de carga da frota) pede três coisas que nenhuma consulta
-- atual entrega: série temporal AGREGADA da frota, contagem de amostras por
-- minuto, e histórico de quantas máquinas estavam online.
--
-- PRINCÍPIO QUE GUIA ESTA MIGRAÇÃO: só entra o que é medido.
--
-- O desenho original trazia "SLO do mês: 38% do budget queimado" e "p95 de
-- ingestão 340ms". Não existe SLO definido neste projeto e não medimos latência
-- de ingestão ponta a ponta. Número inventado em painel de monitoramento é pior
-- que campo ausente: a equipe passa a decidir em cima dele. Esses dois campos
-- não existem aqui, e a interface não os desenha.
--
-- O que ficou, ficou porque é medição real:
--   amostras/min      -> contagem em public.metrics
--   máquinas online   -> mesmo critério de machines_status, aplicado ao passado
--   carga da frota    -> média de cpu/mem das amostras, por balde de tempo
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Tamanho do balde por faixa
-- -----------------------------------------------------------------------------
-- Mantém a série entre ~40 e ~120 pontos em qualquer faixa. Menos que isso vira
-- gráfico grosseiro; mais que isso é dado que o traçado não consegue mostrar e
-- que só custa banda e tempo de consulta.
create or replace function public.balde_da_faixa(p_faixa text)
returns interval
language sql
immutable
as $fn$
  select case p_faixa
    when '1h'  then interval '1 minute'
    when '24h' then interval '15 minutes'
    when '7d'  then interval '2 hours'
    when '30d' then interval '8 hours'
    else interval '15 minutes'
  end
$fn$;

create or replace function public.janela_da_faixa(p_faixa text)
returns interval
language sql
immutable
as $fn$
  select case p_faixa
    when '1h'  then interval '1 hour'
    when '24h' then interval '24 hours'
    when '7d'  then interval '7 days'
    when '30d' then interval '30 days'
    else interval '24 hours'
  end
$fn$;

-- -----------------------------------------------------------------------------
-- Carga da frota + pulso de ingestão
-- -----------------------------------------------------------------------------
create or replace function public.painel_operacao(p_faixa text default '24h')
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_balde   interval := public.balde_da_faixa(p_faixa);
  v_janela  interval := public.janela_da_faixa(p_faixa);
  v_desde   timestamptz := now() - v_janela;
  v_corte   timestamptz := public.offline_cutoff();
  v_carga   jsonb;
  v_pulso   jsonb;
  v_visiveis uuid[];
begin
  -- Escopo do usuário, aplicado UMA vez e reaproveitado. Sem isto a agregação
  -- somaria máquinas de lojas que o usuário não pode ver — e o RLS não protege
  -- de dentro de uma função SECURITY DEFINER.
  select coalesce(array_agg(m.machine_id), '{}')
    into v_visiveis
  from public.machines_status m;

  -- ------------------------------------------------------------------ carga
  -- date_bin em vez de date_trunc: o balde de 15 minutos e o de 8 horas não são
  -- unidades que o date_trunc conheça, e emular com aritmética de epoch daria
  -- uma expressão ilegível para o mesmo resultado.
  select coalesce(jsonb_agg(x order by x.t), '[]'::jsonb)
    into v_carga
  from (
    select
      date_bin(v_balde, s."time", v_desde)              as t,
      round(avg(s.cpu_pct)::numeric, 1)             as cpu,
      round(avg(s.mem_pct)::numeric, 1)             as mem,
      count(distinct s.machine_id)                  as maquinas
    from public.metrics s
    where s."time" >= v_desde
      and s.machine_id = any(v_visiveis)
    group by 1
  ) x;

  -- ------------------------------------------------------------------ pulso
  -- Ritmo real de chegada. É o número que responde "a ingestão está viva?" sem
  -- depender de nenhum agente específico estar reportando.
  select jsonb_build_object(
    'amostras_min', (
      select count(*) from public.metrics
      where "time" >= now() - interval '1 minute' and machine_id = any(v_visiveis)
    ),
    'amostras_hora', (
      select count(*) from public.metrics
      where "time" >= now() - interval '1 hour' and machine_id = any(v_visiveis)
    ),
    'maquinas_reportando', (
      select count(distinct machine_id) from public.metrics
      where "time" >= v_corte and machine_id = any(v_visiveis)
    ),
    -- Série de amostras por balde, para a sparkline da barra lateral.
    'serie', coalesce((
      select jsonb_agg(y.n order by y.t)
      from (
        select date_bin(v_balde, s."time", v_desde) as t, count(*) as n
        from public.metrics s
        where s."time" >= v_desde and s.machine_id = any(v_visiveis)
        group by 1
      ) y
    ), '[]'::jsonb),
    'latencia_gw_media', (
      select round(avg(m.gw_latency_ms)::numeric, 1)
      from public.machines_status m
      where m.status = 'online' and m.gw_latency_ms is not null
    )
  ) into v_pulso;

  return jsonb_build_object(
    'faixa', p_faixa,
    'desde', v_desde,
    'ate', now(),
    'balde_segundos', extract(epoch from v_balde)::bigint,
    'carga', v_carga,
    'pulso', v_pulso
  );
end
$fn$;

revoke all on function public.painel_operacao(text) from public;
grant execute on function public.painel_operacao(text) to authenticated, service_role;

comment on function public.painel_operacao(text) is
  'Carga média da frota por balde de tempo e pulso da ingestão, no escopo do usuário.';

-- -----------------------------------------------------------------------------
-- Histórico de quantas máquinas estavam online
-- -----------------------------------------------------------------------------
-- Alimenta a sparkline do KPI "hosts online". O critério é o MESMO de
-- machines_status — uma máquina conta como online num balde se mandou amostra
-- dentro do tempo de tolerância. Usar régua diferente aqui produziria um gráfico
-- que discorda do número grande logo acima dele.
create or replace function public.serie_online(p_faixa text default '24h')
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_balde  interval := public.balde_da_faixa(p_faixa);
  v_janela interval := public.janela_da_faixa(p_faixa);
  v_desde  timestamptz := now() - v_janela;
  v_tol    integer := public.app_setting_int('offline_timeout_seconds');
  v_visiveis uuid[];
  v_total  integer;
begin
  select coalesce(array_agg(m.machine_id), '{}'), count(*)
    into v_visiveis, v_total
  from public.machines_status m
  where m.is_active;

  return jsonb_build_object(
    'total', v_total,
    'tolerancia_segundos', v_tol,
    'pontos', coalesce((
      select jsonb_agg(jsonb_build_object('t', b.t, 'online', b.n) order by b.t)
      from (
        -- Uma maquina conta no balde se a amostra dela caiu nele. Com o balde
        -- maior que a tolerancia, isso equivale a "estava reportando".
        select date_bin(v_balde, s."time", v_desde) as t,
               count(distinct s.machine_id)     as n
        from public.metrics s
        where s."time" >= v_desde and s.machine_id = any(v_visiveis)
        group by 1
      ) b
    ), '[]'::jsonb)
  );
end
$fn$;

revoke all on function public.serie_online(text) from public;
grant execute on function public.serie_online(text) to authenticated, service_role;

comment on function public.serie_online(text) is
  'Quantas máquinas reportaram em cada balde de tempo. Mesmo critério de machines_status.';
