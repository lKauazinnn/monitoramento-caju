-- =============================================================================
-- 0019 — Remover máquina, loja e os dados de demonstração
-- =============================================================================
-- Faltava o caminho de volta. Dava para cadastrar pela interface, mas não para
-- desfazer: as lojas do seed ficavam para sempre no dashboard, misturadas com as
-- reais, e um PDV desativado continuava contando nos totais.
--
-- DESTRUTIVO DE VERDADE, e o desenho assume isso:
--
--   1. só admin, verificado DENTRO da função;
--   2. remover loja EXIGE confirmação explícita quando ela tem máquinas — o
--      padrão é recusar, não arrastar tudo junto;
--   3. o evento de auditoria é gravado ANTES e SEM referência à linha removida.
--
-- O item 3 não é detalhe: `events.machine_id` é `on delete cascade`. Um evento
-- "máquina removida" apontando para a máquina removida some junto com ela, e a
-- trilha de auditoria fica vazia exatamente no caso em que ela mais importa.
-- Por isso o identificador vai no payload, como texto.
-- =============================================================================

alter table public.events drop constraint if exists events_kind_ck;
alter table public.events add constraint events_kind_ck check (kind in (
  'alert_open', 'alert_recovered', 'alert_notify_failed',
  'machine_provisioned', 'machine_first_seen', 'machine_renamed',
  'token_revoked', 'token_rotated',
  'partition_created', 'partition_dropped', 'retention_purge', 'rollup_run',
  'maintenance_start', 'maintenance_end',
  'agent_error', 'clock_drift', 'ingest_rejected',
  'ingest_config_changed',
  'machine_removed', 'site_removed', 'demo_data_removed'
));

-- Quem está pedindo. Repetido em três funções, então vira função.
create or replace function public.ator_atual()
returns text
language sql
stable
as $fn$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'),
    session_user
  )
$fn$;

-- -----------------------------------------------------------------------------
-- Remover uma máquina
-- -----------------------------------------------------------------------------
-- Leva junto, por cascata: métricas, discos, serviços, tokens e eventos dela.
-- É o que se quer — máquina removida não deve deixar histórico órfão inflando as
-- partições. Quem só quer parar de monitorar sem perder o histórico deve
-- DESATIVAR (is_active = false), que é outra operação.
create or replace function public.remover_maquina_ui(p_machine_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_m      record;
  v_ator   text := public.ator_atual();
  v_metric bigint;
begin
  if not public.current_user_is_admin() then
    raise exception 'apenas administradores podem remover máquinas' using errcode = 'MON09';
  end if;

  select m.id, m.label, s.code as site_code, s.id as site_id
    into v_m
  from public.machines m
  join public.sites s on s.id = m.site_id
  where m.id = p_machine_id;

  if not found then
    raise exception 'máquina não encontrada' using errcode = 'MON07';
  end if;

  select count(*) into v_metric from public.metrics where machine_id = p_machine_id;

  -- Auditoria ANTES, e SEM machine_id NEM site_id.
  --
  -- machine_id é óbvio: com a referência, o cascade levaria o próprio registro
  -- da remoção. site_id é a mesma armadilha um passo adiante, e eu caí nela na
  -- primeira versão: `events.site_id` também é `on delete cascade`, então o
  -- registro "máquina removida" sobrevivia à remoção da máquina e desaparecia
  -- depois, quando a LOJA fosse removida — apagando justamente o histórico de
  -- quem removeu o quê. Os dois identificadores vão no payload, como texto.
  insert into public.events (kind, severity, message, payload)
  values ('machine_removed', 'warning',
          format('máquina removida: %s / %s', v_m.site_code, v_m.label),
          jsonb_build_object('machine_id', v_m.id::text, 'label', v_m.label,
                             'site_id', v_m.site_id::text, 'site_code', v_m.site_code,
                             'actor', v_ator, 'amostras_removidas', v_metric));

  delete from public.machines where id = p_machine_id;

  return jsonb_build_object(
    'ok', true,
    'label', v_m.label,
    'site_code', v_m.site_code,
    'amostras_removidas', v_metric
  );
end
$fn$;

revoke all on function public.remover_maquina_ui(uuid) from public;
grant execute on function public.remover_maquina_ui(uuid) to authenticated, service_role;

comment on function public.remover_maquina_ui(uuid) is
  'Remove máquina e todo o histórico dela. Só admin. Auditado em events sem referência à linha removida.';

-- -----------------------------------------------------------------------------
-- Remover uma loja
-- -----------------------------------------------------------------------------
create or replace function public.remover_loja_ui(
  p_site_code text,
  p_com_maquinas boolean default false
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_s       record;
  v_ator    text := public.ator_atual();
  v_qtd     integer;
  v_labels  text;
  v_marca   uuid;
  v_sobrou  integer;
begin
  if not public.current_user_is_admin() then
    raise exception 'apenas administradores podem remover lojas' using errcode = 'MON09';
  end if;

  select s.id, s.code, s.name, s.brand_id into v_s
  from public.sites s
  where upper(s.code) = upper(btrim(p_site_code));

  if not found then
    raise exception 'loja não encontrada: %', p_site_code using errcode = 'MON07';
  end if;

  select count(*), string_agg(m.label, ', ' order by m.label)
    into v_qtd, v_labels
  from public.machines m where m.site_id = v_s.id;

  -- Recusa por padrão. Apagar uma loja com dez PDVs por engano é irreversível, e
  -- "tem certeza?" precisa existir do lado do servidor também — o cliente pode
  -- ter sido contornado.
  if v_qtd > 0 and not p_com_maquinas then
    raise exception 'a loja % tem % máquina(s): %', v_s.code, v_qtd, v_labels
      using errcode = 'MON07',
            hint = 'Chame de novo com p_com_maquinas = true para remover tudo.';
  end if;

  insert into public.events (kind, severity, message, payload)
  values ('site_removed', 'warning',
          format('loja removida: %s (%s) com %s máquina(s)', v_s.code, v_s.name, v_qtd),
          jsonb_build_object('site_id', v_s.id::text, 'site_code', v_s.code,
                             'site_name', v_s.name, 'maquinas', v_qtd,
                             'labels', coalesce(v_labels, ''), 'actor', v_ator));

  v_marca := v_s.brand_id;

  delete from public.machines where site_id = v_s.id;   -- FK da loja é `restrict`
  delete from public.sites where id = v_s.id;

  -- Marca sem nenhuma loja vira lixo na barra lateral e nos filtros. Removida
  -- junto, mas só se ficou realmente vazia.
  select count(*) into v_sobrou from public.sites where brand_id = v_marca;
  if v_sobrou = 0 then
    delete from public.brands where id = v_marca;
  end if;

  return jsonb_build_object(
    'ok', true,
    'site_code', v_s.code,
    'site_name', v_s.name,
    'maquinas_removidas', v_qtd,
    'marca_removida', v_sobrou = 0
  );
end
$fn$;

revoke all on function public.remover_loja_ui(text, boolean) from public;
grant execute on function public.remover_loja_ui(text, boolean) to authenticated, service_role;

comment on function public.remover_loja_ui(text, boolean) is
  'Remove loja. Recusa se houver máquinas, salvo p_com_maquinas = true. Só admin.';

-- -----------------------------------------------------------------------------
-- Remover os dados de demonstração
-- -----------------------------------------------------------------------------
-- As lojas e máquinas do seed têm GUID fixo (`aaaaaaaa-` para lojas,
-- `bbbbbbbb-` para máquinas). É o mesmo marcador que o simulador usa para NÃO
-- tocar em máquina real, e é ASCII — imune à corrupção de acento no caminho
-- PowerShell -> docker -> psql que já criou máquina fantasma neste projeto.
--
-- Uma chamada, porque tirar cinco máquinas e três lojas uma a uma é atrito que
-- faz o ambiente de produção nascer com dado de demonstração dentro.
create or replace function public.remover_dados_demo()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_ator text := public.ator_atual();
  v_maq  integer;
  v_loj  integer;
  v_mar  integer;
begin
  if not public.current_user_is_admin() then
    raise exception 'apenas administradores podem remover os dados de demonstração'
      using errcode = 'MON09';
  end if;

  select count(*) into v_maq from public.machines where id::text like 'bbbbbbbb-%';
  select count(*) into v_loj from public.sites    where id::text like 'aaaaaaaa-%';

  if v_maq = 0 and v_loj = 0 then
    return jsonb_build_object('ok', true, 'nada_a_remover', true,
                              'maquinas', 0, 'lojas', 0, 'marcas', 0);
  end if;

  insert into public.events (kind, severity, message, payload)
  values ('demo_data_removed', 'info',
          format('dados de demonstração removidos: %s máquina(s), %s loja(s)', v_maq, v_loj),
          jsonb_build_object('maquinas', v_maq, 'lojas', v_loj, 'actor', v_ator));

  delete from public.machines where id::text like 'bbbbbbbb-%';

  -- Só remove a loja de demonstração se ela ficou VAZIA. Se o operador cadastrou
  -- uma máquina real numa loja do seed, a loja passou a ser dele e fica.
  delete from public.sites s
  where s.id::text like 'aaaaaaaa-%'
    and not exists (select 1 from public.machines m where m.site_id = s.id);

  get diagnostics v_loj = row_count;

  delete from public.brands b
  where not exists (select 1 from public.sites s where s.brand_id = b.id)
    and exists (
      -- Só marcas que nasceram do seed: uma marca vazia criada pelo operador
      -- pode estar esperando a primeira loja.
      select 1 where b.code in ('CJP', 'BRASA')
    );

  get diagnostics v_mar = row_count;

  return jsonb_build_object('ok', true, 'maquinas', v_maq, 'lojas', v_loj, 'marcas', v_mar);
end
$fn$;

revoke all on function public.remover_dados_demo() from public;
grant execute on function public.remover_dados_demo() to authenticated, service_role;

comment on function public.remover_dados_demo() is
  'Remove marcas, lojas e máquinas do seed de demonstração. Só admin. Preserva loja que já tenha máquina real.';

-- -----------------------------------------------------------------------------
-- O dashboard precisa saber se ainda há dado de demonstração
-- -----------------------------------------------------------------------------
create or replace function public.tem_dados_demo()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select jsonb_build_object(
    'maquinas', (select count(*) from public.machines where id::text like 'bbbbbbbb-%'),
    'lojas',    (select count(*) from public.sites    where id::text like 'aaaaaaaa-%'),
    'is_admin', public.current_user_is_admin()
  )
$fn$;

revoke all on function public.tem_dados_demo() from public;
grant execute on function public.tem_dados_demo() to authenticated, service_role;
