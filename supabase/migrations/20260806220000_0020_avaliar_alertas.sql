-- =============================================================================
-- 0020 — Avaliação de alertas (fase 5)
-- =============================================================================
-- Até aqui o dashboard MOSTRAVA problema. Ninguém era avisado, e `open_alerts`
-- vivia vazia porque nada nunca escrevia nela. Esta migração fecha isso: uma
-- função que roda pelo pg_cron, compara o estado contra alert_rules e abre ou
-- resolve eventos.
--
-- TRÊS DECISÕES QUE DEFINEM O COMPORTAMENTO
--
-- 1. A REGRA MAIS ESPECÍFICA VENCE.
--    O esquema permite regra global de disco a 10% e regra de loja a 5% ao mesmo
--    tempo. Se as duas valessem, um PDV daquela loja abriria DOIS alertas para o
--    mesmo disco. Precedência: machine > site > brand > role > global. Uma regra
--    por (máquina, tipo), sempre.
--
-- 2. HISTERESE SIMÉTRICA, via consecutive_cycles.
--    Abre só quando a condição se sustenta por N amostras, e resolve só quando
--    ela se desfaz por N amostras. Assimétrico — abrir devagar e fechar rápido —
--    produz o alerta que pisca: a máquina oscila em volta do limiar e cada
--    oscilação gera um par abre/resolve. Alerta que pisca é ignorado, e alerta
--    ignorado é pior que alerta ausente, porque dá a sensação de cobertura.
--    O preço é o aviso de recuperação chegar N ciclos depois. É o preço certo.
--
-- 3. COOLDOWN CONTA DO FECHAMENTO.
--    Depois de resolver, a mesma regra na mesma máquina não reabre por
--    cooldown_minutes. Sem isso, uma máquina no limiar avisa a noite inteira.
--
-- O QUE ESTA MIGRAÇÃO NÃO FAZ: enviar. Ela só decide. O envio é a 0021, e a
-- separação é deliberada — decidir é determinístico e testável sem rede.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Qual regra vale para cada máquina, por tipo
-- -----------------------------------------------------------------------------
-- Colunas explícitas, e não `r.*`: `alert_rules` TAMBÉM tem `machine_id` (o
-- escopo da regra), e ele colidiria com o da máquina. Duas coisas diferentes com
-- o mesmo nome é justamente o tipo de ambiguidade que o Postgres recusa — e bem.
create or replace view public.regras_efetivas with (security_invoker = true) as
with candidatas as (
  select
    m.machine_id            as machine_id,
    r.kind                  as kind,
    r.id                    as rule_id,
    r.name                  as name,
    r.threshold             as threshold,
    r.comparator            as comparator,
    r.consecutive_cycles    as consecutive_cycles,
    r.cooldown_minutes      as cooldown_minutes,
    r.severity              as severity,
    r.channels              as channels,
    r.scope                 as scope,
    case r.scope
      when 'machine' then 4
      when 'site'    then 3
      when 'brand'   then 2
      when 'role'    then 1
      else 0
    end                     as precedencia
  from public.alert_rules r
  join public.machines_status m
    on  r.is_active
    and m.is_active
    and (
      r.scope = 'global'
      or (r.scope = 'machine' and r.machine_id = m.machine_id)
      or (r.scope = 'site'    and r.site_id   = m.site_id)
      or (r.scope = 'brand'   and r.brand_id  = m.brand_id)
      or (r.scope = 'role'    and r.role_code = m.role_code)
    )
)
select distinct on (machine_id, kind)
  machine_id, kind, rule_id, name, threshold, comparator,
  consecutive_cycles, cooldown_minutes, severity, channels, scope, precedencia
from candidatas
order by machine_id, kind, precedencia desc, rule_id;

comment on view public.regras_efetivas is
  'Uma regra por (máquina, tipo): a de escopo mais específico vence.';

-- -----------------------------------------------------------------------------
-- A métrica de cada tipo de regra
-- -----------------------------------------------------------------------------
-- Traduz o `kind` para a coluna de public.metrics, num lugar só. Espalhar este
-- `case` pela função de avaliação garantiria que um dia os dois discordassem.
create or replace function public.valor_da_regra(p_kind text, p_m public.metrics)
returns numeric
language sql
immutable
as $fn$
  select case p_kind
    when 'cpu_sustained' then p_m.cpu_pct
    when 'mem_high'      then p_m.mem_pct
    when 'temp_high'     then p_m.cpu_temp_c
    -- clock_drift NAO esta aqui: o desvio e calculado na ingestao e guardado em
    -- machines.clock_drift_seconds, nao por amostra. Tratado como estado atual.
    else null
  end
$fn$;

-- -----------------------------------------------------------------------------
-- O avaliador
-- -----------------------------------------------------------------------------
create or replace function public.avaliar_alertas()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_r          record;
  v_abertos    integer := 0;
  v_resolvidos integer := 0;
  v_avaliadas  integer := 0;
  v_evento     bigint;
  v_viola      boolean;
  v_limpa      boolean;
  v_valor      numeric;
  v_amostras   integer;
  v_ultimo_fim timestamptz;
begin
  for v_r in
    select re.*, ms.label, ms.site_id, ms.site_code, ms.status,
           ms.services_down, ms.services_down_names,
           ms.disk_min_free_pct, ms.disk_worst_drive, ms.collect_flags,
           ms.clock_drift_seconds,
           ms.seconds_since_seen, ms.in_maintenance
    from public.regras_efetivas re
    join public.machines_status ms on ms.machine_id = re.machine_id
  loop
    v_avaliadas := v_avaliadas + 1;

    -- Máquina em manutenção declarada não gera alerta. Avisar sobre o que a
    -- própria equipe desligou é o caminho mais curto para o alerta ser ignorado.
    if v_r.in_maintenance then
      continue;
    end if;

    v_viola := false;
    v_limpa := false;
    v_valor := null;

    -- ------------------------------------------------------- estado atual
    if v_r.kind = 'offline' then
      -- Não usa amostra: a ausência dela É a condição.
      v_viola := v_r.status = 'offline';
      v_limpa := v_r.status = 'online';

    elsif v_r.kind = 'service_down' then
      v_viola := coalesce(v_r.services_down, 0) > 0;
      v_limpa := coalesce(v_r.services_down, 0) = 0 and v_r.status = 'online';

    elsif v_r.kind = 'smart_failing' then
      v_viola := 'smart_failing' = any(coalesce(v_r.collect_flags, '{}'));
      v_limpa := not v_viola and v_r.status = 'online';

    elsif v_r.kind = 'clock_drift' then
      -- Estado atual: o desvio e uma propriedade da maquina naquele instante, e
      -- relogio nao oscila em torno do limiar como CPU.
      v_valor := abs(coalesce(v_r.clock_drift_seconds, 0));
      if v_r.clock_drift_seconds is not null then
        v_viola := v_valor >= v_r.threshold;
        v_limpa := v_valor <  v_r.threshold;
      end if;

    elsif v_r.kind = 'disk_low' then
      -- Disco é o mínimo entre os volumes, já calculado pela view. Não faz
      -- sentido exigir N ciclos: disco não oscila como CPU.
      v_valor := v_r.disk_min_free_pct;
      if v_valor is not null then
        v_viola := v_valor <= v_r.threshold;
        v_limpa := v_valor > v_r.threshold;
      end if;

    else
      -- ------------------------------------------- métricas com histerese
      -- Exige que TODAS as últimas N amostras violem. Uma única leitura acima
      -- do limiar é ruído; N seguidas são um problema.
      select count(*) into v_amostras
      from (
        select public.valor_da_regra(v_r.kind, m.*) as v
        from public.metrics m
        where m.machine_id = v_r.machine_id
        order by m."time" desc
        limit v_r.consecutive_cycles
      ) x
      where x.v is not null;

      if v_amostras >= v_r.consecutive_cycles then
        select
          bool_and(case v_r.comparator
            when '>'  then x.v >  v_r.threshold
            when '>=' then x.v >= v_r.threshold
            when '<'  then x.v <  v_r.threshold
            else           x.v <= v_r.threshold end),
          bool_and(case v_r.comparator
            when '>'  then x.v <= v_r.threshold
            when '>=' then x.v <  v_r.threshold
            when '<'  then x.v >= v_r.threshold
            else           x.v >  v_r.threshold end),
          max(x.v)
        into v_viola, v_limpa, v_valor
        from (
          select public.valor_da_regra(v_r.kind, m.*) as v
          from public.metrics m
          where m.machine_id = v_r.machine_id
          order by m."time" desc
          limit v_r.consecutive_cycles
        ) x
        where x.v is not null;
      end if;
    end if;

    -- ------------------------------------------------- evento em aberto?
    select e.id into v_evento
    from public.events e
    where e.machine_id = v_r.machine_id
      and e.rule_id = v_r.rule_id
      and e.kind = 'alert_open'
      and e.resolved_at is null
    order by e.opened_at desc
    limit 1;

    if v_viola and v_evento is null then
      -- Cooldown conta do FECHAMENTO do último evento da mesma regra.
      select max(e.resolved_at) into v_ultimo_fim
      from public.events e
      where e.machine_id = v_r.machine_id and e.rule_id = v_r.rule_id
        and e.resolved_at is not null;

      if v_ultimo_fim is not null
         and v_ultimo_fim > now() - make_interval(mins => v_r.cooldown_minutes) then
        continue;
      end if;

      insert into public.events (
        machine_id, site_id, rule_id, kind, severity, metric, value, threshold, message, payload
      ) values (
        v_r.machine_id, v_r.site_id, v_r.rule_id, 'alert_open', v_r.severity,
        v_r.kind, v_valor, v_r.threshold,
        format('%s: %s', v_r.label, public.texto_do_alerta(
               v_r.kind, v_valor, v_r.threshold,
               v_r.services_down::numeric, v_r.services_down_names,
               v_r.disk_worst_drive, v_r.seconds_since_seen::numeric)),
        jsonb_build_object('rule', v_r.name, 'site_code', v_r.site_code,
                           'ciclos', v_r.consecutive_cycles, 'escopo', v_r.scope,
                           'canais', v_r.channels)
      );
      v_abertos := v_abertos + 1;

    elsif v_limpa and v_evento is not null then
      update public.events
         set resolved_at = now()
       where id = v_evento;

      -- Evento SEPARADO para a recuperação, e não só o resolved_at: o aviso de
      -- "voltou" precisa passar pela mesma fila de notificação do aviso de
      -- "caiu", senão a equipe fica sabendo do problema e nunca do fim dele.
      insert into public.events (
        machine_id, site_id, rule_id, kind, severity, metric, value, threshold, message, payload
      ) values (
        v_r.machine_id, v_r.site_id, v_r.rule_id, 'alert_recovered', 'info',
        v_r.kind, v_valor, v_r.threshold,
        format('%s: %s normalizado', v_r.label, v_r.kind),
        jsonb_build_object('rule', v_r.name, 'site_code', v_r.site_code,
                           'evento_origem', v_evento, 'canais', v_r.channels)
      );
      v_resolvidos := v_resolvidos + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'em', now(),
    'avaliadas', v_avaliadas,
    'abertos', v_abertos,
    'resolvidos', v_resolvidos,
    'em_aberto_total', (select count(*) from public.events
                        where kind = 'alert_open' and resolved_at is null)
  );
end
$fn$;

revoke all on function public.avaliar_alertas() from public;
grant execute on function public.avaliar_alertas() to service_role;

comment on function public.avaliar_alertas() is
  'Compara o estado contra alert_rules e abre/resolve eventos. Só service_role: é o pg_cron que chama.';

-- -----------------------------------------------------------------------------
-- Texto do alerta
-- -----------------------------------------------------------------------------
-- Separado porque é o que a equipe vai LER às 2h da manhã. Tem de dizer o número
-- e a unidade, não só "limiar excedido".
-- Parametros numericos em NUMERIC, e a chamada converte explicitamente.
-- `count(*)` do Postgres e bigint, e bigint -> integer nao e conversao implicita
-- na resolucao de funcao: a assinatura com `integer` fazia o Postgres nao achar
-- a funcao, com um erro que fala de "explicit type casts" e nao de bigint.
create or replace function public.texto_do_alerta(
  p_kind text, p_valor numeric, p_limiar numeric,
  p_servicos numeric, p_nomes text[], p_volume text, p_silencio numeric
)
returns text
language sql
immutable
as $fn$
  select case p_kind
    when 'offline' then
      'sem contato há ' || case
        when p_silencio is null then 'tempo desconhecido'
        when p_silencio < 5400 then round(p_silencio / 60)::text || ' min'
        else round(p_silencio / 3600)::text || ' h'
      end
    when 'service_down' then
      coalesce(p_servicos, 0)::text || ' serviço(s) parado(s)'
      || coalesce(': ' || array_to_string(p_nomes, ', '), '')
    when 'smart_failing' then 'SMART prevendo falha de disco'
    when 'disk_low' then
      'disco ' || coalesce(p_volume, '?') || ' com ' || round(coalesce(p_valor, 0), 1)::text
      || '% livre (piso ' || p_limiar::text || '%)'
    when 'cpu_sustained' then
      'CPU sustentada em ' || round(coalesce(p_valor, 0), 1)::text || '% (limiar ' || p_limiar::text || '%)'
    when 'mem_high' then
      'memória em ' || round(coalesce(p_valor, 0), 1)::text || '% (limiar ' || p_limiar::text || '%)'
    when 'temp_high' then
      'temperatura em ' || round(coalesce(p_valor, 0), 1)::text || ' °C (limiar ' || p_limiar::text || ')'
    when 'clock_drift' then
      'relógio ' || round(coalesce(p_valor, 0))::text || 's fora de hora (limiar ' || p_limiar::text || 's)'
    else p_kind
  end
$fn$;

-- -----------------------------------------------------------------------------
-- Agendamento
-- -----------------------------------------------------------------------------
-- Tolerante: sem pg_cron a migração avisa e segue. Assim o mesmo arquivo aplica
-- no Postgres do docker (sem a extensão) e no Supabase (com ela).
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise warning 'pg_cron ausente: avaliar_alertas() NAO sera agendada. Chame manualmente ou habilite a extensao.';
    return;
  end if;

  -- Minuto 2 de cada intervalo de 5, e não 0: o minuto redondo é quando todo
  -- job de todo mundo dispara, inclusive os nossos de rollup e particao.
  perform cron.unschedule('avaliar-alertas') where exists (
    select 1 from cron.job where jobname = 'avaliar-alertas');

  perform cron.schedule('avaliar-alertas', '2-59/5 * * * *',
                        'select public.avaliar_alertas();');

  raise notice 'avaliar_alertas() agendada a cada 5 minutos';
end
$$;
