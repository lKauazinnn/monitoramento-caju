-- =============================================================================
-- 0021 — Reconhecer alerta
-- =============================================================================
-- O painel vai passar a exibir uma faixa vermelha enquanto houver alerta crítico
-- em aberto. Isso só funciona se houver como CALAR a faixa sem apagar o alerta.
--
-- Sem reconhecimento, a faixa fica acesa enquanto a loja não for consertada — e
-- um aviso permanente vira papel de parede em dois dias. Com ele, a equipe diz
-- "já vi, estou tratando", a faixa some, e o alerta continua aberto no histórico
-- até a condição realmente se desfazer.
--
-- QUEM reconheceu fica gravado, e vem do JWT — não do cliente. Um campo de
-- auditoria que o navegador pode preencher não é auditoria.
-- =============================================================================

create or replace function public.reconhecer_alerta(p_event_id bigint)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_e    record;
  v_quem uuid := auth.uid();
begin
  select e.id, e.machine_id, e.site_id, e.message, e.acknowledged_at
    into v_e
  from public.events e
  where e.id = p_event_id and e.kind = 'alert_open' and e.resolved_at is null;

  if not found then
    raise exception 'alerta não encontrado ou já resolvido' using errcode = 'MON07';
  end if;

  -- Escopo verificado AQUI. A função é SECURITY DEFINER, então a RLS de events
  -- não vale dentro dela: sem esta checagem, um usuário de uma loja poderia
  -- reconhecer o alerta de outra passando o id na mão.
  if v_e.site_id is not null
     and not exists (select 1 from public.current_user_site_ids() s where s = v_e.site_id) then
    raise exception 'este alerta não é de uma loja sua' using errcode = 'MON09';
  end if;

  if v_e.acknowledged_at is not null then
    return jsonb_build_object('ok', true, 'ja_reconhecido', true, 'event_id', v_e.id);
  end if;

  update public.events
     set acknowledged_at = now(),
         acknowledged_by = v_quem
   where id = p_event_id;

  return jsonb_build_object('ok', true, 'event_id', v_e.id, 'por', v_quem);
end
$fn$;

revoke all on function public.reconhecer_alerta(bigint) from public;
grant execute on function public.reconhecer_alerta(bigint) to authenticated, service_role;

comment on function public.reconhecer_alerta(bigint) is
  'Silencia a faixa de incidente sem fechar o alerta. Registra quem reconheceu, a partir do JWT.';

-- -----------------------------------------------------------------------------
-- O que o painel precisa para a faixa
-- -----------------------------------------------------------------------------
-- Uma chamada em vez de duas: a faixa precisa saber se deve aparecer E o que
-- dizer, e buscar isso em dois lugares abriria a janela para a contagem e o
-- texto discordarem.
create or replace function public.incidentes_abertos()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  with visiveis as (
    select a.*
    from public.open_alerts a
    where a.site_id is null
       or a.site_id in (select public.current_user_site_ids())
  )
  select jsonb_build_object(
    -- A faixa só acende para o que NÃO foi reconhecido. Reconhecido continua
    -- aberto, e continua contando em `criticos`.
    'gritar', (select count(*) from visiveis
               where severity = 'critical' and acknowledged_at is null),
    'criticos', (select count(*) from visiveis where severity = 'critical'),
    'avisos', (select count(*) from visiveis where severity = 'warning'),
    'lista', coalesce((
      select jsonb_agg(jsonb_build_object(
               'event_id', v.event_id,
               'machine_id', v.machine_id,
               'label', v.machine_label,
               'site_code', v.site_code,
               'kind', v.rule_kind,
               'severity', v.severity,
               'message', v.message,
               'aberto_ha', v.open_seconds,
               'reconhecido', v.acknowledged_at is not null)
             -- Crítico primeiro, e dentro dele o MAIS RECENTE.
             --
             -- Ordenar pelo mais antigo parecia justo ("está esperando há mais
             -- tempo"), mas numa faixa que serve para chamar atenção produz o
             -- contrário: um incidente velho e não reconhecido monopoliza o
             -- espaço, e o problema que acabou de acontecer fica escondido atrás
             -- de um "+2 outros". O que entrou agora é o que ninguém viu ainda.
             order by (v.severity = 'critical') desc, v.opened_at desc)
      from visiveis v
    ), '[]'::jsonb)
  )
$fn$;

revoke all on function public.incidentes_abertos() from public;
grant execute on function public.incidentes_abertos() to authenticated, service_role;

comment on function public.incidentes_abertos() is
  'Alertas em aberto no escopo do usuário, com a contagem que decide se a faixa acende.';
