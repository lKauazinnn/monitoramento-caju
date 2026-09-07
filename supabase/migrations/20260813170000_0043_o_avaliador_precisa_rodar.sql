-- =============================================================================
-- 0043 — O avaliador de alertas precisa RODAR
-- =============================================================================
-- O Kaua pediu um barulho quando um PC desligar. Ao procurar onde encaixar,
-- descobri que a peça que faltava não era o som: era o alerta.
--
-- O pipeline inteiro existia e estava correto desde a 0020:
--   regra 'Máquina offline' (severity critical, 1 ciclo, cooldown 30min)  ✓
--   avaliar_alertas(), que para offline nem usa amostra ("a ausência dela É a
--     condição")                                                          ✓
--   incidentes_abertos(), a faixa vermelha e tocarSeNovo() no painel       ✓
--
-- E eu concluí que ninguém chamava avaliar_alertas() em produção. ESTAVA ERRADO:
-- a 0020 já a agendava a cada 5 minutos. Leia o bloco 1, que conta o erro e o
-- desfaz -- o parágrafo original ficaria aqui mentindo para quem abrisse o arquivo
-- daqui a seis meses.
--
-- O que esta migração entrega, e que continua válido: regras_de_alerta() e
-- editar_regra_de_alerta(), o gerenciamento de alerta do painel.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. CORRECAO: nao havia agendamento a fazer
-- -----------------------------------------------------------------------------
-- A versao original desta migracao agendava avaliar_alertas() a cada minuto,
-- com o nome 'monitor_avaliar_alertas', porque eu concluí que o avaliador nunca
-- rodava em producao.
--
-- ESTAVA ERRADO. A migracao 0020 JA agendava, com o nome 'avaliar-alertas', a
-- cada 5 minutos ('2-59/5 * * * *'). Eu nao vi porque truncei um grep truncado
-- e a linha da 0020 ficou fora da saida.
--
-- A prova estava na primeira execucao: ela devolveu abertos=0 com
-- em_aberto_total=10. Dez alertas ja estavam abertos. Se ninguem avaliasse, a
-- primeira execucao teria aberto os dez -- o zero era a resposta, e eu li como
-- confirmacao em vez de contradicao.
--
-- Consequencia: por algumas horas existiram DOIS jobs fazendo o mesmo trabalho, e
-- o meu rodava 5x mais vezes, cada execucao percorrendo machines_status (uma view
-- com cinco laterais por maquina). Nao enche disco, mas queima CPU e conexao --
-- e entrou na conta do limite que estourou.
--
-- Este bloco agora REMOVE o duplicado, em vez de cria-lo. Reaplicar esta migracao
-- passa a consertar o estrago, e nao a repeti-lo.
do $do$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron ausente: nada a desagendar.';
    return;
  end if;

  if exists (select 1 from cron.job where jobname = 'monitor_avaliar_alertas') then
    perform cron.unschedule('monitor_avaliar_alertas');
    raise notice 'job duplicado monitor_avaliar_alertas removido.';
  end if;

  -- O agendamento CERTO e o da 0020. Aviso se ele nao estiver de pe, em vez de
  -- criar um terceiro: quem cria o job de alerta e a 0020, e um so lugar tem de
  -- ser o dono disso.
  if not exists (select 1 from cron.job where jobname = 'avaliar-alertas' and active) then
    raise warning '%',
      'o job avaliar-alertas (0020) NAO esta ativo: os alertas nao serao '
      'avaliados. Reaplique a 0020 em vez de criar outro job aqui.';
  else
    raise notice 'avaliar-alertas (0020) ativo -- correto.';
  end if;
end
$do$;

-- -----------------------------------------------------------------------------
-- 2. Ver as regras (gerenciamento de alerta)
-- -----------------------------------------------------------------------------
-- Devolve as regras GLOBAIS com um rótulo em português e a unidade do limiar,
-- porque o painel precisa mostrar "90 %" e "120 s" e não pode inventar isso do
-- lado do cliente: se a unidade morasse no JavaScript, uma regra nova apareceria
-- na tela sem unidade nenhuma.
--
-- `explicacao` sai daqui pelo mesmo motivo: quem lê a tela precisa saber que
-- "1 ciclo" no offline não quer dizer "1 minuto", e que o tempo de offline vem
-- de app_settings, não do limiar da regra.
create or replace function public.regras_de_alerta()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select coalesce(jsonb_agg(x order by x->>'ordem'), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'rule_id', r.id,
      'kind', r.kind,
      'nome', r.name,
      'limiar', r.threshold,
      'comparador', r.comparator,
      'ciclos', r.consecutive_cycles,
      'cooldown_min', r.cooldown_minutes,
      'severidade', r.severity,
      'ativa', r.is_active,
      'unidade', case r.kind
        when 'cpu_sustained' then '%'
        when 'mem_high'      then '%'
        when 'disk_low'      then '% livre'
        when 'temp_high'     then '°C'
        when 'clock_drift'   then 's'
        else null
      end,
      'sem_limiar', r.kind in ('offline', 'service_down', 'smart_failing'),
      'explicacao', case r.kind
        when 'offline' then
          'Abre quando a máquina para de reportar. O tempo até ser considerada '
          || 'offline é app_settings.offline_timeout_seconds ('
          || coalesce((select value::text from public.app_settings
                       where key = 'offline_timeout_seconds'), '?')
          || ' s), não o limiar desta regra.'
        when 'service_down'  then 'Abre quando um serviço marcado como crítico está parado.'
        when 'smart_failing' then 'Abre quando o disco informa previsão de falha.'
        when 'cpu_sustained' then 'Abre com a CPU acima do limiar por N amostras seguidas.'
        when 'mem_high'      then 'Abre com a memória acima do limiar por N amostras seguidas.'
        when 'disk_low'      then 'Abre quando o volume mais apertado fica abaixo do limiar.'
        when 'temp_high'     then 'Abre com a temperatura acima do limiar por N amostras seguidas.'
        when 'clock_drift'   then 'Abre quando o relógio da máquina desvia mais que o limiar.'
        else r.name
      end,
      -- Ordem estável e com sentido: crítico primeiro, e dentro dele o nome.
      -- Sem isto a lista embaralha a cada carga e o operador perde o lugar.
      'ordem', case r.severity when 'critical' then '1' when 'warning' then '2' else '3' end
               || r.name
    ) as x
    from public.alert_rules r
    where r.scope = 'global'
  ) s
$fn$;

-- -----------------------------------------------------------------------------
-- 3. Editar uma regra
-- -----------------------------------------------------------------------------
-- Só admin, e só as três coisas que fazem sentido ajustar de fora: o limiar, a
-- histerese e o silêncio. `kind`, `scope` e `severity` ficam de fora de
-- propósito -- mudar a severidade de 'offline' para 'warning' calaria a faixa
-- vermelha da frota inteira por um clique errado, e não há como perceber isso
-- olhando a tela depois.
create or replace function public.editar_regra_de_alerta(
  p_rule_id      uuid,
  p_limiar       numeric default null,
  p_ciclos       integer default null,
  p_cooldown_min integer default null,
  p_ativa        boolean default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_antes record;
  v_limiar numeric;
  v_ciclos integer;
  v_cool   integer;
  v_ativa  boolean;
  v_mudou  jsonb := '{}'::jsonb;
begin
  if not public.current_user_is_admin() then
    raise exception 'apenas administradores podem editar regras de alerta'
      using errcode = 'MON09';
  end if;

  select r.id, r.kind, r.name, r.threshold, r.consecutive_cycles,
         r.cooldown_minutes, r.is_active, r.scope
  into v_antes
  from public.alert_rules r
  where r.id = p_rule_id;

  if not found then
    raise exception 'regra inexistente' using errcode = 'MON01';
  end if;

  -- Só as globais, que são as que o painel mostra. Uma regra de escopo de loja
  -- ou de máquina tem dono e contexto; editá-la por este caminho, que não
  -- pergunta de quem é, contornaria o escopo do usuário.
  if v_antes.scope <> 'global' then
    raise exception 'esta função só edita regras globais' using errcode = 'MON07';
  end if;

  -- `coalesce` com o valor atual: null significa "não mexi neste campo". Para
  -- p_ativa isso quer dizer que não há como desativar passando null -- tem de
  -- passar false, explicitamente.
  v_limiar := coalesce(p_limiar, v_antes.threshold);
  v_ciclos := coalesce(p_ciclos, v_antes.consecutive_cycles);
  v_cool   := coalesce(p_cooldown_min, v_antes.cooldown_minutes);
  v_ativa  := coalesce(p_ativa, v_antes.is_active);

  -- Os limites do schema conferidos AQUI, para o erro sair em português em vez
  -- de vazar o nome de uma constraint para a tela.
  if v_ciclos < 1 or v_ciclos > 60 then
    raise exception 'ciclos consecutivos: use de 1 a 60 (recebi %)', v_ciclos
      using errcode = 'MON07';
  end if;

  if v_cool < 0 or v_cool > 10080 then
    raise exception 'silêncio: use de 0 a 10080 minutos (recebi %)', v_cool
      using errcode = 'MON07';
  end if;

  -- Regra 23 do schema: offline não tem limiar próprio. Aceitar um número aqui
  -- criaria a ilusão de que o tempo de offline se ajusta nesta tela.
  if v_antes.kind = 'offline' and v_limiar is not null then
    -- Uma string só: `raise` recebe um literal de formato, não uma expressão --
    -- `'a' || 'b'` ali é erro de sintaxe, e o psql só reclama disso na hora de
    -- criar a função.
    raise exception 'alerta de offline não tem limiar: o tempo vem de app_settings.offline_timeout_seconds'
      using errcode = 'MON07';
  end if;

  if v_antes.kind not in ('offline', 'service_down', 'smart_failing')
     and v_limiar is null then
    raise exception 'esta regra exige limiar' using errcode = 'MON07';
  end if;

  update public.alert_rules
  set threshold = v_limiar,
      consecutive_cycles = v_ciclos,
      cooldown_minutes = v_cool,
      is_active = v_ativa
  where id = p_rule_id;

  if v_limiar is distinct from v_antes.threshold then
    v_mudou := v_mudou || jsonb_build_object('limiar',
      jsonb_build_object('de', v_antes.threshold, 'para', v_limiar));
  end if;
  if v_ciclos is distinct from v_antes.consecutive_cycles then
    v_mudou := v_mudou || jsonb_build_object('ciclos',
      jsonb_build_object('de', v_antes.consecutive_cycles, 'para', v_ciclos));
  end if;
  if v_cool is distinct from v_antes.cooldown_minutes then
    v_mudou := v_mudou || jsonb_build_object('cooldown_min',
      jsonb_build_object('de', v_antes.cooldown_minutes, 'para', v_cool));
  end if;
  if v_ativa is distinct from v_antes.is_active then
    v_mudou := v_mudou || jsonb_build_object('ativa',
      jsonb_build_object('de', v_antes.is_active, 'para', v_ativa));
  end if;

  -- Desativar a regra de offline é uma decisão de operação, não um detalhe de
  -- configuração: fica registrado com quem fez.
  if v_mudou <> '{}'::jsonb then
    insert into public.events (kind, severity, message, payload)
    values ('rule_edited', 'info',
            format('regra "%s" alterada', v_antes.name),
            jsonb_build_object('rule_id', p_rule_id, 'kind', v_antes.kind,
                               'mudou', v_mudou, 'por', auth.uid()));
  end if;

  return jsonb_build_object('ok', true, 'mudou', v_mudou);
end
$fn$;

-- `events.kind` é fechado por CHECK. Sem estender, o insert acima derruba a
-- edição inteira -- foi exatamente o que a 0034 pegou antes de ir para produção.
-- A lista é ESTENDIDA a partir da que está no banco, nunca reescrita à mão.
--
-- Minha primeira versão listou os kinds de memória e derrubou oito que existem de
-- verdade -- ingest_config_changed, machine_first_seen, machine_provisioned,
-- machine_removed, partition_created, partition_dropped, retention_purge,
-- site_removed. O ALTER falhou porque havia linhas gravadas com eles, e foi só a
-- guarda que evitou perder a constraint. Recriar uma lista fechada de memória é
-- errado por construção: eu não tenho como saber o que outra migração acrescentou.
do $do$
declare
  v_def  text;
  v_novo text;
begin
  select pg_get_constraintdef(c.oid) into v_def
  from pg_constraint c
  where c.conname = 'events_kind_ck' and c.conrelid = 'public.events'::regclass;

  if v_def is null then
    raise warning 'events_kind_ck não existe: nada a estender.';
    return;
  end if;

  if position('''rule_edited''' in v_def) > 0 then
    raise notice 'events_kind_ck já aceita rule_edited.';
    return;
  end if;

  -- O Postgres normaliza `kind in (...)` para `kind = ANY (ARRAY[...])`. Entrar
  -- pelo começo do ARRAY preserva TODO o resto sem eu precisar conhecê-lo.
  v_novo := replace(v_def, 'ARRAY[', 'ARRAY[''rule_edited''::text, ');

  if v_novo = v_def then
    raise warning 'events_kind_ck tem forma inesperada (%): não estendi. A edição de '
      'regras vai falhar ao registrar o evento.', v_def;
    return;
  end if;

  execute 'alter table public.events drop constraint events_kind_ck';
  execute 'alter table public.events add constraint events_kind_ck ' || v_novo;

  -- Prova de que funciona, em vez de confiar no ALTER: grava e desfaz. Sem isto
  -- eu descobriria o problema quando alguém editasse uma regra em produção.
  begin
    insert into public.events (kind, severity, message)
    values ('rule_edited', 'info', 'prova da migração 0043');
    delete from public.events
    where kind = 'rule_edited' and message = 'prova da migração 0043';
  exception when others then
    raise warning 'events_kind_ck estendida, mas a prova falhou (%).', sqlerrm;
  end;

  raise notice 'events_kind_ck estendida com rule_edited.';
end
$do$;

revoke all on function public.regras_de_alerta() from public;
revoke all on function public.editar_regra_de_alerta(uuid, numeric, integer, integer, boolean) from public;

grant execute on function public.regras_de_alerta() to authenticated, service_role;
grant execute on function public.editar_regra_de_alerta(uuid, numeric, integer, integer, boolean)
  to authenticated, service_role;

comment on function public.regras_de_alerta() is
  'Regras globais de alerta com rótulo, unidade e explicação para o painel.';
comment on function public.editar_regra_de_alerta(uuid, numeric, integer, integer, boolean) is
  'Ajusta limiar, histerese e silêncio de uma regra global. Só admin. Não muda kind nem severidade.';

notify pgrst, 'reload schema';
