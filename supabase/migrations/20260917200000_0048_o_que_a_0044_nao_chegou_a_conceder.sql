-- =============================================================================
-- 0048 — As permissões que ficaram para trás, e a guarda para elas
-- =============================================================================
-- COMO APARECEU
--
-- O painel entrou (login, token, RLS, tudo certo) e a primeira tela veio vazia,
-- com 403 no console:
--
--   {"code":"42501","message":"permission denied for table machine_volumes"}
--
-- A 0044 concede essa permissão -- na ÚLTIMA linha do arquivo. A tabela existia,
-- a função existia, a view existia: só o `grant` do fim não estava lá. Ou seja,
-- a 0044 foi aplicada PELA METADE em 15/09, e ninguém soube, porque quem aplicou
-- não parou no primeiro erro.
--
-- O DETALHE QUE ESCONDEU O DEFEITO POR HORAS
--
-- Conferir com `set role authenticated; select count(*) from machines_status;`
-- passava, e isso não é bug do Postgres: `count(*)` não referencia nenhuma
-- coluna de machine_volumes, então o planejador ELIMINA o join, e permissão de
-- tabela que não está no plano não é verificada. O painel pede `select=*`, o
-- join volta, e a permissão falta. Conferência que não pede as colunas de
-- verdade não prova acesso de verdade.
--
-- POR QUE UMA MIGRATION, JÁ QUE O COMANDO SOLTO RESOLVEU NESTA MÁQUINA
--
-- Porque consertar no terminal conserta UM banco. O próximo ambiente -- ou esta
-- mesma máquina reinstalada -- nasceria com o mesmo buraco, e o sintoma (tela
-- vazia com login funcionando) custa caro para diagnosticar. Aqui fica escrito.
--
-- Idempotente: `grant` repetido não faz nada.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- O que ficou para trás
-- -----------------------------------------------------------------------------
grant select on public.machine_volumes to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- E a lista inteira do que o painel precisa ler, reconcedida de uma vez
-- -----------------------------------------------------------------------------
-- Não é zelo excessivo: se a 0044 parou no meio, qualquer outra pode ter parado
-- também, e um `grant` já concedido custa nada. O que custa é descobrir o
-- próximo faltando pelo mesmo caminho de hoje -- três horas e um painel vazio.
--
-- As PARTIÇÕES continuam fora de propósito (metrics_2026xx e companhia): o
-- acesso a elas é pelo pai, e alcançá-las direto escaparia das policies. O teste
-- 01.9 guarda isso, e esta migration não o contradiz.
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
  public.user_site_access,
  public.machine_volumes
to authenticated;

grant select on
  public.machines_status,
  public.sites_status,
  public.brands_status,
  public.agent_tokens_admin,
  public.machine_services_expected,
  public.open_alerts
to authenticated;

-- -----------------------------------------------------------------------------
-- A prova, no próprio arquivo
-- -----------------------------------------------------------------------------
-- Sem isto, a migration "passa" mesmo que algum grant não tenha surtido efeito
-- -- que é exatamente o modo de falha que nos trouxe até aqui.
do $do$
declare
  v_faltando text;
begin
  select string_agg(o, ', ' order by o) into v_faltando
  from unnest(array[
    'public.brands', 'public.sites', 'public.machine_roles', 'public.machines',
    'public.metrics', 'public.metrics_disks', 'public.metrics_services',
    'public.metrics_hourly', 'public.metrics_disks_hourly', 'public.alert_rules',
    'public.events', 'public.app_settings', 'public.agent_tokens',
    'public.user_roles', 'public.user_site_access', 'public.machine_volumes',
    'public.machines_status', 'public.sites_status', 'public.brands_status',
    'public.agent_tokens_admin', 'public.machine_services_expected',
    'public.open_alerts'
  ]) o
  where to_regclass(o) is not null
    and not has_table_privilege('authenticated', to_regclass(o), 'select');

  if v_faltando is not null then
    raise exception 'authenticated segue sem SELECT em: %', v_faltando;
  end if;

  raise notice 'conferido: authenticated le tudo o que o painel consome.';
end
$do$;
