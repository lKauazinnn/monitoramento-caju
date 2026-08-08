-- =============================================================================
-- 0028 — Dias sem reiniciar, e o reinício agendado para a madrugada
-- =============================================================================
-- Suspender resolve "a loja fecha e eu quero economizar energia sem perder o
-- acesso". NÃO resolve o que suspender nunca resolveu: Windows que fica semanas
-- sem reiniciar acumula vazamento de memória, handle preso, driver em estado
-- ruim e atualização pendente esperando reinício. A máquina vai degradando, e o
-- painel mostra CPU e memória subindo devagar sem causa aparente.
--
-- Suspensão NÃO conta como reinício: o sistema volta do mesmo lugar, com os
-- mesmos processos e a mesma memória suja. Do ponto de vista do desgaste, uma
-- máquina suspensa toda noite por um mês está ligada há um mês.
--
-- Então os dois convivem, resolvendo coisas diferentes:
--
--   suspender     -> todo dia, no fecho da loja. Reversível pela rede.
--   reiniciar     -> de tempos em tempos, na madrugada. Limpa de verdade.
--
-- E o reinício não precisa de Wake-on-LAN nenhum: a máquina volta sozinha. É a
-- operação remota mais segura que existe aqui — a única que não depende de
-- placa, firmware ou vizinho.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A regra
-- -----------------------------------------------------------------------------
-- A constraint original chama-se _ck, nao _check. Na primeira tentativa criei
-- uma SEGUNDA constraint com o outro nome: a nova permitia o tipo novo, e a
-- antiga continuava recusando. Duas constraints com nomes parecidos sobre a
-- mesma coluna e uma armadilha silenciosa — a insercao falha citando um nome
-- que ninguem acabou de escrever.
alter table public.alert_rules drop constraint if exists alert_rules_kind_check;
alter table public.alert_rules drop constraint if exists alert_rules_kind_ck;
alter table public.alert_rules add constraint alert_rules_kind_ck check (kind in (
  'offline', 'cpu_sustained', 'mem_high', 'disk_low', 'temp_high',
  'service_down', 'clock_drift', 'smart_failing',
  'uptime_long'
));

-- A restrição de threshold obrigatório lista os kinds que NÃO precisam dele.
-- `uptime_long` precisa (é o número de dias), então nada muda ali.

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
    when 'uptime_long' then
      round(coalesce(p_valor, 0))::text || ' dias sem reiniciar (limiar '
      || p_limiar::text || '). Suspender não conta: precisa de reinício de verdade.'
    else p_kind
  end
$fn$;

-- -----------------------------------------------------------------------------
-- A avaliação
-- -----------------------------------------------------------------------------
-- Sem histerese, como disco: dias-ligada não oscila em torno do limiar. Exigir
-- N ciclos seguidos só atrasaria o alerta em N minutos sem filtrar ruído nenhum.
create or replace function public.dias_ligada(p_machine_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select case
    when m.last_boot_at is null then null
    -- Contra o relógio da MÁQUINA não: `last_boot_at` já é derivado do uptime
    -- que ela reportou, e comparar com now() do servidor é o único jeito de o
    -- número não depender de uma máquina com a hora errada.
    else round(extract(epoch from (now() - m.last_boot_at)) / 86400.0, 2)
  end
  from public.machines m where m.id = p_machine_id
$fn$;

revoke all on function public.dias_ligada(uuid) from public;
grant execute on function public.dias_ligada(uuid) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Reinício agendado
-- -----------------------------------------------------------------------------
-- `enfileirar_comando` sempre aceitou `p_quando`, mas nada usava. Reiniciar um
-- PDV às 15h de uma sexta é derrubar a loja no movimento; a mesma ação às 4h da
-- manhã não custa nada a ninguém.
--
-- O comando fica `pending` até a hora marcada e só então é entregue. Se a
-- máquina estiver desligada nessa hora, ele expira — e expirar é o certo:
-- reiniciar quando a loja abrir seria pior que não reiniciar.
create or replace function public.agendar_reinicio(
  p_machine_id uuid,
  p_hora       integer default 4,
  p_dry_run    boolean default false
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_m       record;
  v_quando  timestamptz;
  v_parede  timestamp;   -- hora de parede, sem fuso: ver o comentario abaixo
  v_tz      text;
  v_ttl     integer := public.app_setting_int('command_ttl_minutes');
  v_r       jsonb;
begin
  if p_hora < 0 or p_hora > 23 then
    raise exception 'hora fora da faixa 0..23 (recebido %)', p_hora using errcode = 'MON07';
  end if;

  select m.machine_id, m.label, m.site_id, m.site_timezone
    into v_m
  from public.machines_status m
  where m.machine_id = p_machine_id;

  if not found then
    raise exception 'máquina não encontrada' using errcode = 'MON07';
  end if;

  v_tz := coalesce(v_m.site_timezone, 'America/Sao_Paulo');

  -- No fuso DA LOJA. Brasília e São Paulo hoje coincidem, mas escrever "4h" e
  -- gravar a hora do servidor é o tipo de coisa que funciona até o dia em que
  -- não funciona, e aí ninguém liga o defeito à causa.
  --
  -- `v_parede` é `timestamp` SEM fuso, e isso é essencial. Guardar a hora de
  -- parede intermediária num `timestamptz` faz o Postgres convertê-la pelo fuso
  -- da SESSÃO (UTC aqui), não pelo da loja — e a segunda conversão parte de um
  -- valor já errado. Na primeira versão desta função, "4h" virava 22h do dia
  -- anterior, o que reiniciaria a loja no meio do expediente.
  v_parede := date_trunc('day', now() at time zone v_tz) + make_interval(hours => p_hora);
  v_quando := v_parede at time zone v_tz;

  -- Já passou hoje? Marca para amanhã.
  if v_quando <= now() then
    v_quando := v_quando + interval '1 day';
  end if;

  -- A janela de entrega tem que alcançar a hora marcada. Com o TTL padrão de 30
  -- min, um comando agendado para daqui a 8 h expiraria antes de ser entregue —
  -- silenciosamente, e ninguém entenderia por que o reinício não aconteceu.
  v_r := public.enfileirar_comando(
    p_machine_id, 'restart_machine', '{}'::jsonb, p_dry_run, true, v_quando, 'painel');

  update public.agent_commands
     set expires_at = v_quando + make_interval(mins => greatest(v_ttl, 120))
   where id = (v_r ->> 'command_id')::uuid;

  return jsonb_build_object(
    'ok', true,
    'command_id', v_r ->> 'command_id',
    'maquina', v_m.label,
    'quando', v_quando,
    'dry_run', p_dry_run,
    'nota', format('%s reinicia às %sh no fuso da loja. Se estiver desligada na hora, o comando expira.',
                   v_m.label, p_hora));
end
$fn$;

revoke all on function public.agendar_reinicio(uuid, integer, boolean) from public;
grant execute on function public.agendar_reinicio(uuid, integer, boolean) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- O painel mostra os dias
-- -----------------------------------------------------------------------------
create or replace function public.acoes_da_maquina(p_machine_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_m        record;
  v_servicos text[];
  v_ultimo   timestamptz;
  v_cooldown integer := public.app_setting_int('command_reboot_cooldown_minutes');
  v_pend     integer;
  v_mac      macaddr;
  v_vizinho  uuid;
  v_nome_v   text;
  v_acordou  boolean;
  v_dias     numeric;
  v_limiar   numeric;
begin
  select m.machine_id, m.label, m.site_id, m.status, m.agent_version, mm.mac_address
    into v_m
  from public.machines_status m
  join public.machines mm on mm.id = m.machine_id
  where m.machine_id = p_machine_id;

  if not found then
    raise exception 'máquina não encontrada' using errcode = 'MON07';
  end if;

  if not exists (select 1 from public.current_user_site_ids() s where s = v_m.site_id) then
    raise exception 'esta máquina não é de uma loja sua' using errcode = 'MON09';
  end if;

  v_servicos := public.effective_critical_services(p_machine_id);
  v_mac      := v_m.mac_address;
  v_dias     := public.dias_ligada(p_machine_id);

  select max(c.created_at) into v_ultimo
  from public.agent_commands c
  where c.machine_id = p_machine_id and c.kind = 'restart_machine'
    and not c.dry_run and c.status <> 'canceled';

  select count(*) into v_pend
  from public.agent_commands c
  where c.machine_id = p_machine_id and c.status in ('pending', 'sent', 'acked');

  if v_m.status <> 'online' and v_mac is not null then
    v_vizinho := public.vizinho_para_acordar(p_machine_id);
    if v_vizinho is not null then
      select label into v_nome_v from public.machines where id = v_vizinho;
    end if;
  end if;

  select exists (
    select 1 from public.agent_commands c
    where c.kind = 'wake_machine' and not c.dry_run and c.result_ok
      and c.params ->> 'mac' = v_mac::text
  ) into v_acordou;

  -- O limiar que vale PARA ESTA máquina, e não um número fixo na tela: a regra
  -- pode ser afinada por loja ou por perfil, e a tela tem que concordar com o
  -- que o avaliador de alertas vai fazer.
  select re.threshold into v_limiar
  from public.regras_efetivas re
  where re.machine_id = p_machine_id and re.kind = 'uptime_long'
  limit 1;

  return jsonb_build_object(
    'pode',      public.current_user_is_admin(),
    'servicos',  to_jsonb(coalesce(v_servicos, array[]::text[])),
    'status',    v_m.status,
    'pendentes', v_pend,
    'agente_suporta', public.agente_suporta_comandos(v_m.agent_version),
    'agent_version',  v_m.agent_version,

    'ligar', jsonb_build_object(
      'aplicavel', v_m.status <> 'online',
      'tem_mac',   v_mac is not null,
      'vizinho',   v_nome_v),

    'suspender', jsonb_build_object(
      'aplicavel', v_m.status = 'online',
      'tem_mac',   v_mac is not null,
      'tem_vizinho', v_m.status = 'online'
                     and public.vizinho_para_acordar(p_machine_id) is not null,
      'ja_acordou', v_acordou),

    'uptime', jsonb_build_object(
      'dias',   v_dias,
      'limiar', v_limiar,
      'passou', v_limiar is not null and v_dias is not null and v_dias >= v_limiar),

    'reboot_liberado_em', case
      when v_ultimo is null then null
      when v_ultimo > now() - make_interval(mins => v_cooldown)
        then v_ultimo + make_interval(mins => v_cooldown)
      else null end
  );
end
$fn$;

-- -----------------------------------------------------------------------------
-- A regra padrão
-- -----------------------------------------------------------------------------
-- 14 dias, e `info` e não `warning`: não é uma falha, é manutenção devida. Subir
-- para warning colocaria isso na mesma cor de disco cheio, e a cor deixaria de
-- significar urgência.
insert into public.alert_rules (name, kind, scope, threshold, comparator,
                                consecutive_cycles, cooldown_minutes, severity, channels)
select 'Muito tempo sem reiniciar', 'uptime_long', 'global', 14, '>=', 1, 10080, 'info', array['telegram']
where not exists (
  select 1 from public.alert_rules where kind = 'uptime_long' and scope = 'global'
);

-- -----------------------------------------------------------------------------
-- O avaliador aprende o novo tipo
-- -----------------------------------------------------------------------------
-- Recriada por inteiro: uma regra que existe e nunca e avaliada e pior que
-- regra nenhuma, porque a tela mostra que ela esta ativa.
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

    elsif v_r.kind = 'uptime_long' then
      -- Dias desde o ultimo boot. Sem histerese: isto nao oscila em torno do
      -- limiar, so cresce — e so cai de uma vez, quando a maquina reinicia.
      --
      -- SUSPENDER NAO ZERA ISTO, e e o ponto: o sistema volta do mesmo lugar,
      -- com a mesma memoria suja. Uma maquina suspensa toda noite por um mes
      -- esta ligada ha um mes.
      v_valor := public.dias_ligada(v_r.machine_id);
      if v_valor is not null and v_r.status = 'online' then
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
