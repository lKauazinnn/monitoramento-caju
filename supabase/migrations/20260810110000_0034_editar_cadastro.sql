-- =============================================================================
-- 0034 — Corrigir o que foi cadastrado errado
-- =============================================================================
-- Dava para cadastrar e dava para REMOVER. Não dava para corrigir. Errar o nome
-- de uma máquina virava escolher entre conviver com o erro ou apagar a máquina —
-- e apagar leva o histórico inteiro dela junto, o que é uma punição absurda para
-- um erro de digitação.
--
-- `null` significa "não mexer neste campo". Sem isso, todo formulário de edição
-- teria que reenviar tudo, e um campo esquecido apagaria dado bom.
--
-- Renomear NÃO muda identidade: a máquina é o GUID, e por isso o agente instalado
-- continua reportando sem reinstalar nada. O mesmo já valia para o hostname, que
-- a ingestão atualiza sozinha e registra em `machine_renamed`.
--
-- Mover a máquina de loja exige as DUAS lojas no escopo de quem edita, senão
-- alguém com acesso a uma loja poderia trazer máquina de outra para dentro do
-- próprio escopo — ganhando acesso a um histórico que não era dele.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Máquina
-- -----------------------------------------------------------------------------
create or replace function public.editar_maquina(
  p_machine_id uuid,
  p_label      text default null,
  p_role_code  text default null,
  p_site_id    uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_antes   record;
  v_label   text;
  v_role    text;
  v_site    uuid;
  v_mudou   jsonb := '{}'::jsonb;
  v_nome_loja text;
begin
  if not public.current_user_is_admin() then
    raise exception 'apenas administradores podem editar o cadastro' using errcode = 'MON09';
  end if;

  select m.id, m.label, m.role_code, m.site_id
    into v_antes
  from public.machines m
  where m.id = p_machine_id;

  if not found then
    raise exception 'máquina inexistente' using errcode = 'MON01';
  end if;

  if not exists (select 1 from public.current_user_site_ids() s where s = v_antes.site_id) then
    raise exception 'esta máquina não é de uma loja sua' using errcode = 'MON09';
  end if;

  -- ------------------------------------------------------------------- nome
  v_label := coalesce(nullif(btrim(p_label), ''), v_antes.label);
  if length(v_label) > 64 then
    raise exception 'o nome tem % caracteres; o limite é 64', length(v_label)
      using errcode = 'MON07';
  end if;

  -- ------------------------------------------------------------------ perfil
  v_role := coalesce(nullif(btrim(p_role_code), ''), v_antes.role_code);
  if not exists (select 1 from public.machine_roles r where r.code = v_role) then
    raise exception 'perfil inexistente: %', v_role using errcode = 'MON07';
  end if;

  -- -------------------------------------------------------------------- loja
  v_site := coalesce(p_site_id, v_antes.site_id);
  if v_site <> v_antes.site_id then
    -- A loja de DESTINO também tem que ser sua. Ver o cabeçalho.
    if not exists (select 1 from public.current_user_site_ids() s where s = v_site) then
      raise exception 'a loja de destino não é sua' using errcode = 'MON09';
    end if;
    if not exists (select 1 from public.sites s where s.id = v_site) then
      raise exception 'loja de destino inexistente' using errcode = 'MON01';
    end if;
  end if;

  -- Nome repetido dentro da loja: a checagem existe no banco
  -- (machines_site_id_label_key), mas o erro cru dela não diz nada a quem está
  -- no painel. Aqui a mensagem nomeia o conflito.
  if exists (
    select 1 from public.machines m
    where m.site_id = v_site and m.label = v_label and m.id <> p_machine_id
  ) then
    raise exception 'já existe uma máquina chamada % nesta loja', v_label
      using errcode = 'MON07';
  end if;

  if v_label = v_antes.label and v_role = v_antes.role_code and v_site = v_antes.site_id then
    return jsonb_build_object('ok', true, 'mudou', '{}'::jsonb, 'nada_a_fazer', true);
  end if;

  if v_label <> v_antes.label then
    v_mudou := v_mudou || jsonb_build_object('label',
      jsonb_build_object('de', v_antes.label, 'para', v_label));
  end if;
  if v_role <> v_antes.role_code then
    v_mudou := v_mudou || jsonb_build_object('role_code',
      jsonb_build_object('de', v_antes.role_code, 'para', v_role));
  end if;
  if v_site <> v_antes.site_id then
    select s.code into v_nome_loja from public.sites s where s.id = v_site;
    v_mudou := v_mudou || jsonb_build_object('site',
      jsonb_build_object('de', (select code from public.sites where id = v_antes.site_id),
                         'para', v_nome_loja));
  end if;

  update public.machines
     set label = v_label, role_code = v_role, site_id = v_site
   where id = p_machine_id;

  -- Trilha. Uma correção de cadastro é indistinguível de sabotagem sem registro
  -- de quem mudou o quê — e este é um sistema que a diretoria audita.
  insert into public.events (machine_id, site_id, kind, severity, message, payload)
  values (p_machine_id, v_site, 'machine_edited', 'info',
          format('cadastro editado: %s',
                 (select string_agg(k, ', ') from jsonb_object_keys(v_mudou) k)),
          v_mudou);

  return jsonb_build_object('ok', true, 'mudou', v_mudou);
end
$fn$;

-- -----------------------------------------------------------------------------
-- Loja
-- -----------------------------------------------------------------------------
create or replace function public.editar_loja(
  p_site_id  uuid,
  p_code     text default null,
  p_name     text default null,
  p_timezone text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_antes record;
  v_code  text;
  v_name  text;
  v_tz    text;
  v_mudou jsonb := '{}'::jsonb;
begin
  if not public.current_user_is_admin() then
    raise exception 'apenas administradores podem editar o cadastro' using errcode = 'MON09';
  end if;

  select s.id, s.code, s.name, s.timezone into v_antes
  from public.sites s where s.id = p_site_id;

  if not found then
    raise exception 'loja inexistente' using errcode = 'MON01';
  end if;

  if not exists (select 1 from public.current_user_site_ids() s where s = p_site_id) then
    raise exception 'esta loja não é sua' using errcode = 'MON09';
  end if;

  v_code := coalesce(nullif(btrim(p_code), ''), v_antes.code);
  v_name := coalesce(nullif(btrim(p_name), ''), v_antes.name);
  v_tz   := coalesce(nullif(btrim(p_timezone), ''), v_antes.timezone);

  if v_code !~ '^[A-Za-z0-9][A-Za-z0-9._-]{1,31}$' then
    raise exception 'código inválido: % (letras, números, ponto, hífen; 2 a 32)', v_code
      using errcode = 'MON07';
  end if;

  if length(v_name) > 120 then
    raise exception 'o nome tem % caracteres; o limite é 120', length(v_name)
      using errcode = 'MON07';
  end if;

  -- O fuso é o que decide a hora do reinício agendado e do relatório mensal.
  -- Um fuso inválido não é detalhe de cadastro: faz a máquina reiniciar na hora
  -- errada, e o CHECK da tabela recusaria com uma mensagem ilegível.
  if not public.is_valid_timezone(v_tz) then
    raise exception 'fuso horário desconhecido: % (ex.: America/Sao_Paulo)', v_tz
      using errcode = 'MON07';
  end if;

  if exists (select 1 from public.sites s where s.code = v_code and s.id <> p_site_id) then
    raise exception 'já existe uma loja com o código %', v_code using errcode = 'MON07';
  end if;

  if v_code = v_antes.code and v_name = v_antes.name and v_tz = v_antes.timezone then
    return jsonb_build_object('ok', true, 'mudou', '{}'::jsonb, 'nada_a_fazer', true);
  end if;

  if v_code <> v_antes.code then
    v_mudou := v_mudou || jsonb_build_object('code',
      jsonb_build_object('de', v_antes.code, 'para', v_code));
  end if;
  if v_name <> v_antes.name then
    v_mudou := v_mudou || jsonb_build_object('name',
      jsonb_build_object('de', v_antes.name, 'para', v_name));
  end if;
  if v_tz <> v_antes.timezone then
    v_mudou := v_mudou || jsonb_build_object('timezone',
      jsonb_build_object('de', v_antes.timezone, 'para', v_tz));
  end if;

  update public.sites set code = v_code, name = v_name, timezone = v_tz
   where id = p_site_id;

  -- machine_id nulo: o evento é da loja, não de uma máquina dela.
  insert into public.events (machine_id, site_id, kind, severity, message, payload)
  values (null, p_site_id, 'site_edited', 'info',
          format('loja editada: %s',
                 (select string_agg(k, ', ') from jsonb_object_keys(v_mudou) k)),
          v_mudou);

  return jsonb_build_object('ok', true, 'mudou', v_mudou);
end
$fn$;

-- -----------------------------------------------------------------------------
-- Marca
-- -----------------------------------------------------------------------------
create or replace function public.editar_marca(
  p_brand_id uuid,
  p_code     text default null,
  p_name     text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_antes record;
  v_code  text;
  v_name  text;
begin
  -- Marca não tem escopo por loja: ela está ACIMA da loja. Editar marca é ato de
  -- admin e ponto — não existe "sua marca".
  if not public.current_user_is_admin() then
    raise exception 'apenas administradores podem editar o cadastro' using errcode = 'MON09';
  end if;

  select b.id, b.code, b.name into v_antes
  from public.brands b where b.id = p_brand_id;

  if not found then
    raise exception 'marca inexistente' using errcode = 'MON01';
  end if;

  v_code := coalesce(nullif(btrim(p_code), ''), v_antes.code);
  v_name := coalesce(nullif(btrim(p_name), ''), v_antes.name);

  if v_code !~ '^[A-Za-z0-9][A-Za-z0-9._-]{1,31}$' then
    raise exception 'código inválido: %', v_code using errcode = 'MON07';
  end if;

  if exists (select 1 from public.brands b where b.code = v_code and b.id <> p_brand_id) then
    raise exception 'já existe uma marca com o código %', v_code using errcode = 'MON07';
  end if;

  if v_code = v_antes.code and v_name = v_antes.name then
    return jsonb_build_object('ok', true, 'nada_a_fazer', true);
  end if;

  update public.brands set code = v_code, name = v_name where id = p_brand_id;

  return jsonb_build_object('ok', true,
    'mudou', jsonb_build_object('de', jsonb_build_object('code', v_antes.code, 'name', v_antes.name),
                                'para', jsonb_build_object('code', v_code, 'name', v_name)));
end
$fn$;

-- -----------------------------------------------------------------------------
-- `machine_edited` e `site_edited` precisam ser tipos de evento aceitos
-- -----------------------------------------------------------------------------
-- A lista de `kind` é fechada de propósito: um kind digitado errado viraria um
-- evento que nenhuma tela procura, e a trilha teria buraco sem ninguém notar.
--
-- O nome da restrição é descoberto em vez de chutado. Este projeto já perdeu
-- tempo com `_ck` contra `_check`, e um `drop constraint if exists` com o nome
-- errado não falha — só não faz nada, e o `add` seguinte quebra por duplicidade.
do $$
declare v_nome text;
begin
  select c.conname into v_nome
  from pg_constraint c
  where c.conrelid = 'public.events'::regclass
    and c.contype = 'c'
    and pg_get_constraintdef(c.oid) ilike '%machine_first_seen%';

  if v_nome is not null then
    execute format('alter table public.events drop constraint %I', v_nome);
  end if;
end $$;

alter table public.events add constraint events_kind_ck check (kind in (
  'alert_open', 'alert_recovered', 'alert_notify_failed',
  'machine_provisioned', 'machine_first_seen', 'machine_renamed',
  'token_revoked', 'token_rotated',
  'partition_created', 'partition_dropped', 'retention_purge', 'rollup_run',
  'maintenance_start', 'maintenance_end',
  'agent_error', 'clock_drift', 'ingest_rejected', 'ingest_config_changed',
  'machine_removed', 'site_removed', 'demo_data_removed',
  'command_queued', 'command_result', 'command_expired', 'command_canceled',
  -- 0034
  'machine_edited', 'site_edited'
));

revoke all on function public.editar_maquina(uuid, text, text, uuid) from public;
revoke all on function public.editar_loja(uuid, text, text, text)     from public;
revoke all on function public.editar_marca(uuid, text, text)          from public;

grant execute on function public.editar_maquina(uuid, text, text, uuid) to authenticated, service_role;
grant execute on function public.editar_loja(uuid, text, text, text)     to authenticated, service_role;
grant execute on function public.editar_marca(uuid, text, text)          to authenticated, service_role;
