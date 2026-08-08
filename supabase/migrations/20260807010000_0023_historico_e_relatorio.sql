-- =============================================================================
-- 0023 — Histórico pelo rollup, e o relatório mensal (fase 7, parte 2)
-- =============================================================================
-- DUAS COISAS QUE FALTAVAM PARA O ROLLUP VALER NA PRÁTICA.
--
-- 1. `machine_history` lia SÓ a métrica crua. Com a retenção de 30 dias, o
--    gráfico de "30 d" ia ficar vazio em pouco tempo — o rollup cheio e a tela
--    mostrando nada. Agora 7 d e 30 d leem `metrics_hourly`, que é o que aquela
--    tabela existe para fazer, e de quebra a consulta deixa de varrer milhões de
--    linhas cruas para desenhar 120 pontos.
--
--    24 h continua no cru: ali a granularidade de 10 minutos é o valor, e uma
--    hora agregada esconderia justamente o pico que se está procurando.
--
-- 2. Não havia relatório. O painel responde "o que está quebrado AGORA"; ninguém
--    conseguia responder "como foi o mês passado" — que é a pergunta da reunião,
--    e a única que justifica guardar 400 dias de histórico.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Histórico: cru para 24 h, rollup para 7 d e 30 d
-- -----------------------------------------------------------------------------
create or replace function public.machine_history(
  p_machine_id uuid,
  p_range      text default '24h'
)
returns table (
  bucket      timestamptz,
  cpu_avg     real,
  cpu_max     real,
  mem_avg     real,
  temp_avg    real,
  disk_min_free_pct real,
  gw_latency_avg real,
  samples     integer
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_desde timestamptz;
  v_passo interval;
  v_horas boolean;
begin
  -- Autorização feita UMA vez. Sem isto, um SECURITY DEFINER seria um furo:
  -- qualquer usuário autenticado leria qualquer máquina de qualquer loja.
  if not exists (
    select 1 from public.machines m
    where m.id = p_machine_id
      and m.site_id in (select public.current_user_site_ids())
  ) then
    raise exception 'máquina fora do seu escopo de acesso' using errcode = 'MON05';
  end if;

  case p_range
    when '24h' then v_desde := now() - interval '24 hours'; v_passo := interval '10 minutes'; v_horas := false;
    when '7d'  then v_desde := now() - interval '7 days';   v_passo := interval '1 hour';     v_horas := true;
    when '30d' then v_desde := now() - interval '30 days';  v_passo := interval '6 hours';    v_horas := true;
    else raise exception 'faixa inválida: % (use 24h, 7d ou 30d)', p_range using errcode = 'MON03';
  end case;

  if not v_horas then
    -- ------------------------------------------------------------- 24 h, cru
    return query
    with balde as (
      -- to_timestamp(floor(epoch/passo)*passo) agrupa em janelas fixas sem
      -- depender do TimeZone da sessão, diferente de date_trunc.
      select to_timestamp(floor(extract(epoch from x."time") / extract(epoch from v_passo))
                          * extract(epoch from v_passo)) as b,
             x.cpu_pct, x.mem_pct, x.cpu_temp_c, x.gw_latency_ms
      from public.metrics x
      where x.machine_id = p_machine_id and x."time" >= v_desde
    ),
    discos as (
      select to_timestamp(floor(extract(epoch from d."time") / extract(epoch from v_passo))
                          * extract(epoch from v_passo)) as b,
             min(d.free_pct) as free_pct
      from public.metrics_disks d
      where d.machine_id = p_machine_id and d."time" >= v_desde
      group by 1
    )
    select b.b,
           avg(b.cpu_pct)::real, max(b.cpu_pct)::real, avg(b.mem_pct)::real,
           avg(b.cpu_temp_c)::real, min(dd.free_pct)::real, avg(b.gw_latency_ms)::real,
           count(*)::integer
    from balde b
    left join discos dd on dd.b = b.b
    group by b.b
    order by b.b;

  else
    -- -------------------------------------------------- 7 d e 30 d, pelo rollup
    -- Médias de médias ponderadas por `samples`: sem o peso, uma hora com três
    -- amostras influiria tanto quanto uma hora cheia, e o traçado mentiria
    -- justamente nos períodos de coleta ruim.
    return query
    select to_timestamp(floor(extract(epoch from h.hour) / extract(epoch from v_passo))
                        * extract(epoch from v_passo)) as b,
           (sum(h.cpu_avg * h.samples) / nullif(sum(h.samples), 0))::real,
           max(h.cpu_max)::real,
           (sum(h.mem_avg * h.samples) / nullif(sum(h.samples), 0))::real,
           (sum(h.temp_avg * h.samples) / nullif(sum(h.samples), 0))::real,
           min(h.disk_min_free_pct)::real,
           (sum(h.gw_latency_avg * h.samples) / nullif(sum(h.samples), 0))::real,
           sum(h.samples)::integer
    from public.metrics_hourly h
    where h.machine_id = p_machine_id and h.hour >= v_desde
    group by 1
    order by 1;
  end if;
end
$fn$;

comment on function public.machine_history(uuid, text) is
  'Série do gráfico. 24 h vem do cru; 7 d e 30 d vêm de metrics_hourly, ponderadas por samples.';

-- -----------------------------------------------------------------------------
-- Relatório mensal
-- -----------------------------------------------------------------------------
-- A pergunta da reunião: "como foi o mês passado".
--
-- DISPONIBILIDADE é o número que a operação vai olhar, e ele merece uma
-- definição explícita: amostras recebidas ÷ amostras esperadas, no mês. Não é
-- "uptime do Windows" — é quanto do tempo a máquina esteve reportando. Uma
-- máquina ligada mas sem rede conta como indisponível, e está certo: para o
-- monitoramento, ela estava muda.
--
-- O denominador vem de `samples_expected`, gravado hora a hora pelo rollup a
-- partir do intervalo de coleta. Calcular aqui, com o intervalo de hoje,
-- distorceria meses em que o intervalo era outro.
create or replace function public.relatorio_mensal(p_mes date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_ini  date;
  v_fim  date;
  v_linhas jsonb;
  v_tot  jsonb;
begin
  v_ini := date_trunc('month', coalesce(p_mes, (now() - interval '1 month')::date))::date;
  v_fim := (v_ini + interval '1 month')::date;

  with escopo as (
    select m.machine_id, m.label, m.site_code, m.site_name, m.brand_name
    from public.machines_status m
    where m.site_id in (select public.current_user_site_ids())
  ),
  horas as (
    select h.machine_id,
           sum(h.samples)                                              as amostras,
           sum(h.samples_expected)                                     as esperadas,
           -- ::numeric aqui, e nao no round() la embaixo: as colunas do rollup
           -- sao `real`, e round(double precision, int) nao existe no Postgres.
           -- Converter na origem deixa a CTE inteira num tipo so.
           (sum(h.cpu_avg::numeric * h.samples) / nullif(sum(h.samples), 0)) as cpu_media,
           max(h.cpu_p95)::numeric                                     as cpu_p95,
           (sum(h.mem_avg::numeric * h.samples) / nullif(sum(h.samples), 0)) as mem_media,
           max(h.temp_max)::numeric                                    as temp_max,
           min(h.disk_min_free_pct)::numeric                           as disco_min,
           sum(h.reboot_count)                                         as reinicios,
           count(*) filter (where h.service_down_count > 0)            as horas_com_servico_parado,
           count(*)                                                    as horas_com_dado
    from public.metrics_hourly h
    where h.hour >= v_ini and h.hour < v_fim
    group by h.machine_id
  ),
  incidentes as (
    select e.machine_id,
           count(*) filter (where e.kind = 'alert_open')                        as alertas,
           count(*) filter (where e.kind = 'alert_open' and e.severity = 'critical') as criticos,
           count(*) filter (where e.kind = 'alert_open' and e.metric = 'offline')    as quedas,
           -- Tempo somado em que houve alerta aberto. Alerta ainda em aberto no
           -- fim do mês conta até o fim do mês, não até agora: senão o relatório
           -- de janeiro mudaria toda vez que fosse aberto.
           -- `filter` vem logo depois da agregação, ANTES de qualquer cast: o
           -- Postgres recusa `sum(...)::numeric filter (...)`, porque a essa
           -- altura já não há mais agregação a filtrar.
           coalesce(sum(
             extract(epoch from (least(coalesce(e.resolved_at, v_fim::timestamptz), v_fim::timestamptz)
                                 - greatest(e.opened_at, v_ini::timestamptz)))
           ) filter (where e.kind = 'alert_open'), 0)::numeric               as segundos_em_alerta
    from public.events e
    where e.opened_at < v_fim
      and coalesce(e.resolved_at, v_fim::timestamptz) >= v_ini
    group by e.machine_id
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'machine_id', es.machine_id,
      'maquina', es.label,
      'loja', es.site_code,
      'loja_nome', es.site_name,
      'marca', es.brand_name,
      'disponibilidade_pct', case
        when coalesce(h.esperadas, 0) = 0 then null
        else round(least(100, (h.amostras::numeric * 100) / h.esperadas), 2) end,
      'amostras', coalesce(h.amostras, 0),
      'esperadas', coalesce(h.esperadas, 0),
      'cpu_media', round(coalesce(h.cpu_media, 0), 1),
      'cpu_p95', round(coalesce(h.cpu_p95, 0), 1),
      'mem_media', round(coalesce(h.mem_media, 0), 1),
      'temp_max', h.temp_max,
      'disco_min_pct', h.disco_min,
      'reinicios', coalesce(h.reinicios, 0),
      'horas_com_servico_parado', coalesce(h.horas_com_servico_parado, 0),
      'alertas', coalesce(i.alertas, 0),
      'criticos', coalesce(i.criticos, 0),
      'quedas', coalesce(i.quedas, 0),
      'horas_em_alerta', round(coalesce(i.segundos_em_alerta, 0) / 3600.0, 1)
    ) order by es.site_code, es.label), '[]'::jsonb)
  into v_linhas
  from escopo es
  left join horas h on h.machine_id = es.machine_id
  left join incidentes i on i.machine_id = es.machine_id;

  -- Totais calculados sobre a MESMA lista, e não numa consulta separada: dois
  -- caminhos para o mesmo número acabam discordando no dia em que um deles muda.
  select jsonb_build_object(
    'maquinas', jsonb_array_length(v_linhas),
    'com_dado', (select count(*) from jsonb_array_elements(v_linhas) x
                 where (x ->> 'amostras')::bigint > 0),
    'disponibilidade_media', (
      select round(avg((x ->> 'disponibilidade_pct')::numeric), 2)
      from jsonb_array_elements(v_linhas) x
      where x ->> 'disponibilidade_pct' is not null),
    'alertas', (select coalesce(sum((x ->> 'alertas')::bigint), 0)
                from jsonb_array_elements(v_linhas) x),
    'criticos', (select coalesce(sum((x ->> 'criticos')::bigint), 0)
                 from jsonb_array_elements(v_linhas) x),
    'quedas', (select coalesce(sum((x ->> 'quedas')::bigint), 0)
               from jsonb_array_elements(v_linhas) x),
    'reinicios', (select coalesce(sum((x ->> 'reinicios')::bigint), 0)
                  from jsonb_array_elements(v_linhas) x)
  ) into v_tot;

  return jsonb_build_object(
    'mes', to_char(v_ini, 'YYYY-MM'),
    'de', v_ini,
    'ate', v_fim,
    'gerado_em', now(),
    'resumo', v_tot,
    'maquinas', v_linhas
  );
end
$fn$;

revoke all on function public.relatorio_mensal(date) from public;
grant execute on function public.relatorio_mensal(date) to authenticated, service_role;

comment on function public.relatorio_mensal(date) is
  'Relatório do mês por máquina: disponibilidade (amostras/esperadas), carga, incidentes e reinícios.';

-- -----------------------------------------------------------------------------
-- Quais meses têm dado
-- -----------------------------------------------------------------------------
-- Para o seletor do painel não oferecer mês vazio.
create or replace function public.meses_com_relatorio()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select coalesce(jsonb_agg(to_char(m, 'YYYY-MM') order by m desc), '[]'::jsonb)
  from (
    select distinct date_trunc('month', h.hour)::date as m
    from public.metrics_hourly h
    join public.machines_status s on s.machine_id = h.machine_id
    where s.site_id in (select public.current_user_site_ids())
  ) x
$fn$;

revoke all on function public.meses_com_relatorio() from public;
grant execute on function public.meses_com_relatorio() to authenticated, service_role;
