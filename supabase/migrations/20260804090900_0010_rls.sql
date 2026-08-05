-- =============================================================================
-- 0010 — RLS, privilégios de tabela e privilégios de função
-- =============================================================================
-- Postura: NEGAR por padrão e conceder por exceção.
--
--   anon           -> nenhum privilégio em nenhuma tabela ou view. A ingestão da
--                     Fase 2 receberá EXECUTE apenas na função de ingestão.
--   authenticated  -> SELECT, limitado pelas policies ao escopo de lojas do
--                     usuário. NENHUMA escrita em séries temporais (regra 3).
--   service_role   -> acesso total; é a única identidade que provisiona e ingere.
--
-- Regra 3 literal: não existe nenhuma policy com USING (true) para
-- INSERT/UPDATE/DELETE em role pública neste arquivo. Toda escrita de série
-- passa por função servidor.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Zerar privilégios herdados
-- -----------------------------------------------------------------------------
-- O Supabase mantém ALTER DEFAULT PRIVILEGES concedendo acesso a
-- anon/authenticated em objetos novos. Isto desfaz a herança para tudo que já
-- existe, incluindo as partições criadas na 0007.
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;

-- -----------------------------------------------------------------------------
-- 2. Habilitar RLS
-- -----------------------------------------------------------------------------
-- FORCE ROW LEVEL SECURITY não é usado de propósito: aplicaria RLS também ao
-- dono das tabelas, quebrando toda função SECURITY DEFINER do projeto.
alter table public.app_settings        enable row level security;
alter table public.brands              enable row level security;
alter table public.sites               enable row level security;
alter table public.machine_roles       enable row level security;
alter table public.machines            enable row level security;
alter table public.agent_tokens        enable row level security;
alter table public.user_roles          enable row level security;
alter table public.user_site_access    enable row level security;
alter table public.metrics             enable row level security;
alter table public.metrics_disks       enable row level security;
alter table public.metrics_services    enable row level security;
alter table public.metrics_hourly      enable row level security;
alter table public.metrics_disks_hourly enable row level security;
alter table public.alert_rules         enable row level security;
alter table public.events              enable row level security;

-- -----------------------------------------------------------------------------
-- 3. Concessões de leitura ao dashboard
-- -----------------------------------------------------------------------------
-- Apenas o PAI particionado recebe SELECT. O PostgreSQL verifica privilégio na
-- relação nomeada na consulta, então ler via `metrics` funciona enquanto
-- `metrics_202608` permanece inacessível — e é o acesso direto à partição que
-- escaparia das policies do pai.
grant select on
  public.brands,
  public.sites,
  public.machine_roles,
  public.machines,
  public.metrics,
  public.metrics_disks,
  public.metrics_services,
  public.metrics_hourly,
  public.metrics_disks_hourly,
  public.alert_rules,
  public.events,
  public.app_settings,
  public.agent_tokens,
  public.user_roles,
  public.user_site_access
to authenticated;

grant select on
  public.machines_status,
  public.sites_status,
  public.brands_status,
  public.agent_tokens_admin,
  public.machine_services_expected,
  public.open_alerts
to authenticated;

grant all on
  public.machines_status,
  public.sites_status,
  public.brands_status,
  public.agent_tokens_admin,
  public.machine_services_expected,
  public.open_alerts
to service_role;

-- Escrita no cadastro fica com admin, mediada por policy (item 5).
grant insert, update, delete on
  public.brands,
  public.sites,
  public.machines,
  public.machine_roles,
  public.alert_rules,
  public.app_settings,
  public.user_roles,
  public.user_site_access
to authenticated;

-- Reconhecimento de alerta e silenciamento precisam de UPDATE em events.
grant update on public.events to authenticated;

-- -----------------------------------------------------------------------------
-- 4. Policies de leitura (escopadas por loja)
-- -----------------------------------------------------------------------------
-- Catálogos globais: qualquer usuário autenticado lê.
drop policy if exists app_settings_read on public.app_settings;
create policy app_settings_read on public.app_settings
  for select to authenticated using (true);

drop policy if exists machine_roles_read on public.machine_roles;
create policy machine_roles_read on public.machine_roles
  for select to authenticated using (true);

-- Marca é visível se o usuário tem alguma loja dela.
drop policy if exists brands_read on public.brands;
create policy brands_read on public.brands
  for select to authenticated
  using (
    public.current_user_is_admin()
    or exists (
      select 1 from public.sites s
      where s.brand_id = brands.id
        and s.id in (select public.current_user_site_ids())
    )
  );

drop policy if exists sites_read on public.sites;
create policy sites_read on public.sites
  for select to authenticated
  using (sites.id in (select public.current_user_site_ids()));

drop policy if exists machines_read on public.machines;
create policy machines_read on public.machines
  for select to authenticated
  using (machines.site_id in (select public.current_user_site_ids()));

-- Séries temporais: escopo herdado da máquina.
drop policy if exists metrics_read on public.metrics;
create policy metrics_read on public.metrics
  for select to authenticated
  using (exists (
    select 1 from public.machines m
    where m.id = metrics.machine_id
      and m.site_id in (select public.current_user_site_ids())
  ));

drop policy if exists metrics_disks_read on public.metrics_disks;
create policy metrics_disks_read on public.metrics_disks
  for select to authenticated
  using (exists (
    select 1 from public.machines m
    where m.id = metrics_disks.machine_id
      and m.site_id in (select public.current_user_site_ids())
  ));

drop policy if exists metrics_services_read on public.metrics_services;
create policy metrics_services_read on public.metrics_services
  for select to authenticated
  using (exists (
    select 1 from public.machines m
    where m.id = metrics_services.machine_id
      and m.site_id in (select public.current_user_site_ids())
  ));

drop policy if exists metrics_hourly_read on public.metrics_hourly;
create policy metrics_hourly_read on public.metrics_hourly
  for select to authenticated
  using (exists (
    select 1 from public.machines m
    where m.id = metrics_hourly.machine_id
      and m.site_id in (select public.current_user_site_ids())
  ));

drop policy if exists metrics_disks_hourly_read on public.metrics_disks_hourly;
create policy metrics_disks_hourly_read on public.metrics_disks_hourly
  for select to authenticated
  using (exists (
    select 1 from public.machines m
    where m.id = metrics_disks_hourly.machine_id
      and m.site_id in (select public.current_user_site_ids())
  ));

drop policy if exists events_read on public.events;
create policy events_read on public.events
  for select to authenticated
  using (
    public.current_user_is_admin()
    or events.site_id in (select public.current_user_site_ids())
    or exists (
      select 1 from public.machines m
      where m.id = events.machine_id
        and m.site_id in (select public.current_user_site_ids())
    )
  );

drop policy if exists alert_rules_read on public.alert_rules;
create policy alert_rules_read on public.alert_rules
  for select to authenticated
  using (
    public.current_user_is_admin()
    or alert_rules.scope in ('global', 'role')
    or alert_rules.site_id in (select public.current_user_site_ids())
    or exists (
      select 1 from public.machines m
      where m.id = alert_rules.machine_id
        and m.site_id in (select public.current_user_site_ids())
    )
    or exists (
      select 1 from public.sites s
      where s.brand_id = alert_rules.brand_id
        and s.id in (select public.current_user_site_ids())
    )
  );

-- Tokens: só admin, e mesmo assim sem o hash (via agent_tokens_admin).
drop policy if exists agent_tokens_read on public.agent_tokens;
create policy agent_tokens_read on public.agent_tokens
  for select to authenticated
  using (public.current_user_is_admin());

drop policy if exists user_roles_read on public.user_roles;
create policy user_roles_read on public.user_roles
  for select to authenticated
  using (public.current_user_is_admin() or user_roles.user_id = auth.uid());

drop policy if exists user_site_access_read on public.user_site_access;
create policy user_site_access_read on public.user_site_access
  for select to authenticated
  using (public.current_user_is_admin() or user_site_access.user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- 5. Policies de escrita — exclusivamente admin, nunca em série temporal
-- -----------------------------------------------------------------------------
-- Nenhuma policy de INSERT/UPDATE/DELETE existe para metrics, metrics_disks,
-- metrics_services, metrics_hourly, metrics_disks_hourly ou agent_tokens.
-- Com RLS habilitada e sem policy, a escrita é negada mesmo tendo GRANT.
do $do$
declare
  t text;
begin
  foreach t in array array[
    'brands', 'sites', 'machines', 'machine_roles',
    'alert_rules', 'app_settings', 'user_roles', 'user_site_access'
  ] loop
    execute format('drop policy if exists %I on public.%I', t || '_admin_write', t);
    execute format($p$
      create policy %I on public.%I
        for all to authenticated
        using (public.current_user_is_admin())
        with check (public.current_user_is_admin())
    $p$, t || '_admin_write', t);
  end loop;
end
$do$;

-- Operator pode reconhecer alerta e encerrar manutenção; não pode reescrever o
-- histórico. O WITH CHECK impede que o UPDATE mude a máquina/loja do evento.
drop policy if exists events_ack_write on public.events;
create policy events_ack_write on public.events
  for update to authenticated
  using (
    public.current_user_is_admin()
    or exists (
      select 1 from public.user_roles ur
      where ur.user_id = auth.uid() and ur.role = 'operator'
    )
  )
  with check (
    events.site_id in (select public.current_user_site_ids())
    or public.current_user_is_admin()
  );

-- -----------------------------------------------------------------------------
-- 6. Privilégios de FUNÇÃO
-- -----------------------------------------------------------------------------
-- No PostgreSQL, funções novas são executáveis por PUBLIC por padrão. Sem os
-- REVOKE abaixo, provision_machine() ficaria acessível ao role anon — que é
-- exatamente o furo que emitiria tokens para qualquer um com a anon key.
revoke all on function public.provision_machine(text, text, text, text, boolean) from public;
revoke all on function public.revoke_agent_token(text, text)                    from public;
revoke all on function public.verify_agent_token(text)                          from public;
revoke all on function public.touch_agent_token(bytea)                          from public;
revoke all on function public.ensure_month_partition(text, date)                from public;
revoke all on function public.maintain_partitions(integer)                      from public;
revoke all on function public.drop_old_partitions(integer)                      from public;
revoke all on function public.purge_aggregates()                                from public;
revoke all on function public.run_maintenance()                                 from public;

-- Emissão e revogação de credencial: apenas service_role.
grant execute on function public.provision_machine(text, text, text, text, boolean) to service_role;
grant execute on function public.revoke_agent_token(text, text)                     to service_role;
grant execute on function public.verify_agent_token(text)                           to service_role;
grant execute on function public.touch_agent_token(bytea)                           to service_role;

-- Manutenção: service_role (e o pg_cron, que roda como superusuário).
grant execute on function public.ensure_month_partition(text, date) to service_role;
grant execute on function public.maintain_partitions(integer)       to service_role;
grant execute on function public.drop_old_partitions(integer)       to service_role;
grant execute on function public.purge_aggregates()                 to service_role;
grant execute on function public.run_maintenance()                  to service_role;

-- Helpers de leitura usados pelas views e policies: authenticated precisa deles.
grant execute on function public.app_setting_int(text)               to authenticated, service_role;
grant execute on function public.app_setting_text(text)              to authenticated, service_role;
grant execute on function public.offline_cutoff()                    to authenticated, service_role;
grant execute on function public.current_user_is_admin()             to authenticated, service_role;
grant execute on function public.current_user_site_ids()             to authenticated, service_role;
grant execute on function public.effective_critical_services(uuid)   to authenticated, service_role;
grant execute on function public.is_valid_timezone(text)             to authenticated, service_role;

comment on policy metrics_read on public.metrics is
  'Leitura escopada por loja. Não existe policy de escrita: série temporal só entra por função servidor.';
