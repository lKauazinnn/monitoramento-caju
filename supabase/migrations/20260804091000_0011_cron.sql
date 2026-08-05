-- =============================================================================
-- 0011 — Agendamento (pg_cron)
-- =============================================================================
-- Este arquivo NÃO falha em ambiente sem pg_cron: apenas emite aviso. Isso
-- mantém as migrations executáveis em PostgreSQL puro para o teste de
-- idempotência, sem criar um segundo caminho de migration.
--
-- pg_cron agenda no fuso do servidor (UTC no Supabase). 03:17 UTC = 00:17 BRT,
-- fora da janela de operação das lojas.
-- =============================================================================

do $do$
begin
  -- No Supabase a extensão pode exigir habilitação prévia pelo painel
  -- (Database > Extensions). A tentativa aqui é intencionalmente tolerante.
  begin
    create extension if not exists pg_cron;
  exception
    when others then
      raise notice 'pg_cron não pôde ser criado (%). Prossigo sem agendamento.', sqlerrm;
  end;

  if to_regnamespace('cron') is null then
    raise warning
      'pg_cron AUSENTE: a manutenção de partições NÃO está agendada. '
      'Habilite a extensão e reaplique esta migration, ou agende '
      '"select public.run_maintenance();" em um agendador externo. '
      'Sem isso, a ingestão para quando acabarem as partições futuras.';
    return;
  end if;

  -- Reagendamento idempotente: remove pelo nome antes de criar.
  perform cron.unschedule(j.jobid)
  from cron.job j
  where j.jobname in ('monitor_maintenance');

  perform cron.schedule(
    'monitor_maintenance',
    '17 3 * * *',
    'select public.run_maintenance();'
  );

  raise notice 'pg_cron: job monitor_maintenance agendado para 03:17 UTC diariamente.';
end
$do$;

-- Verificação rápida do que ficou agendado:
--   select jobname, schedule, command, active from cron.job order by jobname;
--   select * from cron.job_run_details order by start_time desc limit 20;
