-- =============================================================================
-- 0047 — O agendador fora do alcance dos papéis da aplicação
-- =============================================================================
-- Apareceu ao subir a primeira instalação self-hosted. O teste 01 acusou:
--
--   FALHA (regra 3): policy de escrita exposta a anon/PUBLIC:
--     cron.job.cron_job_policy [cmd=*]
--     cron.job_run_details.cron_job_run_details_policy [cmd=*]
--
-- E não era falso positivo. Medido no banco:
--
--   PUBLIC | job             | SELECT
--   PUBLIC | job_run_details | SELECT
--   PUBLIC | job_run_details | DELETE
--
-- POR QUE ISSO NUNCA APARECEU NO SUPABASE
--
-- Lá o pg_cron já vem instalado e com o schema fechado para os papéis da
-- aplicação. Self-hosted, quem cria a extensão somos nós (0011), e ela traz os
-- próprios GRANTs para PUBLIC -- que é como o pg_cron permite um usuário comum
-- administrar os PRÓPRIOS jobs.
--
-- QUAL É O RISCO DE VERDADE, sem exagero
--
-- As policies do pg_cron filtram por `username = current_user`, então `anon`
-- leria zero linhas hoje. O problema não é o vazamento imediato: é `anon` ter
-- privilégio num objeto que ele não tem motivo nenhum para alcançar, e
-- `job_run_details` aceitar DELETE de PUBLIC -- apagar histórico de execução do
-- agendador é apagar justamente a evidência que se usa quando o agendamento
-- falha. Foi medindo esse histórico que descobrimos hoje que o avaliador leva
-- 0,4 s e podia ir para 1 minuto.
--
-- Quem agenda neste sistema é o superusuário, pelas migrations. Nenhum papel da
-- aplicação precisa de leitura, escrita ou sequer USAGE no schema.
--
-- Tolerante a ambiente sem pg_cron, pela mesma razão da 0011: o mesmo arquivo
-- aplica no Postgres do docker sem a extensão e no servidor com ela.
-- =============================================================================

do $do$
begin
  if not exists (select 1 from pg_namespace where nspname = 'cron') then
    raise notice 'schema cron ausente: nada a revogar (ambiente sem pg_cron).';
    return;
  end if;

  -- A ordem importa: tirar USAGE do schema sozinho já barra o acesso, mas os
  -- GRANTs de tabela continuariam listados e o teste continuaria acusando.
  -- Tirar os dois deixa o estado limpo e o motivo óbvio para quem inspecionar.
  revoke all on all tables in schema cron from public;
  revoke usage on schema cron from public;

  -- anon e authenticated existem neste projeto (0010). Revogar explicitamente
  -- além de PUBLIC porque um GRANT direto a eles não é coberto pelo revoke de
  -- PUBLIC -- e um dia alguém pode conceder.
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on all tables in schema cron from anon;
    revoke usage on schema cron from anon;
  end if;

  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    revoke all on all tables in schema cron from authenticated;
    revoke usage on schema cron from authenticated;
  end if;

  raise notice 'schema cron fechado para public, anon e authenticated.';
end
$do$;

-- -----------------------------------------------------------------------------
-- A prova, no próprio arquivo
-- -----------------------------------------------------------------------------
-- Sem isto, a migração "passa" mesmo que o revoke não tenha surtido efeito --
-- e o sintoma só reapareceria na próxima vez que alguém rodasse o teste 01.
do $do$
declare
  v_sobrou text;
begin
  if not exists (select 1 from pg_namespace where nspname = 'cron') then
    return;
  end if;

  select string_agg(grantee || ' -> ' || table_name || ' (' || privilege_type || ')', ', ')
    into v_sobrou
  from information_schema.role_table_grants
  where table_schema = 'cron'
    and grantee in ('PUBLIC', 'anon', 'authenticated');

  if v_sobrou is not null then
    raise exception 'ainda ha privilegio no schema cron: %', v_sobrou;
  end if;

  raise notice 'conferido: nenhum privilegio de aplicacao no schema cron.';
end
$do$;
