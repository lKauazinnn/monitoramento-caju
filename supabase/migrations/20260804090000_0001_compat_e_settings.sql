-- =============================================================================
-- 0001 — Compatibilidade de ambiente + configuração central
-- =============================================================================
-- PREMISSAS ASSUMIDAS NESTA FASE (confirmar / corrigir):
--   1. Marca é entidade própria (tabela `brands`), não coluna em `sites`.
--   2. `sites.vpn_subnet` existe desde já, nullable, aguardando a VPN IPsec.
--   3. Código de loja é texto livre curto e único (case-insensitive).
--      => Se o ERP já tem código de loja, use o dele. NÃO crie segundo namespace.
--   4. Intervalo de coleta do agente: 60 segundos.
--   5. Retenção: 30 dias de série bruta, 400 dias de rollup horário.
--   6. Escala alvo: ~600 máquinas em 12 meses.
--   7. Escopo de acesso por usuário existe desde já (`user_roles`/`user_site_access`).
--   8. Serviços críticos vivem no banco por perfil de máquina, com override.
--   9. Telegram: um chat por marca (`brands.telegram_chat_id`).
--
-- Todas as migrations deste diretório são IDEMPOTENTES: rodar duas vezes
-- seguidas no mesmo banco não pode falhar nem alterar dado de operação.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Shim de compatibilidade: roles do Supabase
-- -----------------------------------------------------------------------------
-- Em Supabase, anon/authenticated/service_role já existem. Em PostgreSQL puro
-- (docker local, usado para o teste de idempotência) não existem, e os GRANT/
-- REVOKE da migration 0010 falhariam. O bloco abaixo só age quando faltam.
do $do$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end
$do$;

grant usage on schema public to anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Shim de compatibilidade: auth.uid()
-- -----------------------------------------------------------------------------
-- As policies de RLS usam auth.uid(). Em Supabase a função é nativa e nada é
-- criado aqui. Em PostgreSQL puro criamos um equivalente que lê o mesmo GUC
-- que o PostgREST popula, para que as policies sejam testáveis localmente.
do $do$
begin
  if to_regnamespace('auth') is null then
    create schema auth;
  end if;

  if to_regprocedure('auth.uid()') is null then
    -- Lê os DOIS formatos de GUC, porque o PostgREST mudou:
    --   * moderno (db-use-legacy-gucs = false): um único `request.jwt.claims`
    --     contendo o JSON inteiro do token — é o que o Supabase usa;
    --   * legado: um GUC por claim, `request.jwt.claim.sub`.
    -- Ler só o legado faz auth.uid() devolver NULL silenciosamente, e o sintoma
    -- é "o usuário logou mas não vê nada" — sem erro em lugar nenhum.
    execute $f$
      create function auth.uid() returns uuid
      language plpgsql
      stable
      as $b$
      declare
        v_claims text;
        v_sub    text;
      begin
        v_claims := nullif(current_setting('request.jwt.claims', true), '');

        if v_claims is not null then
          begin
            v_sub := v_claims::jsonb ->> 'sub';
          exception when others then
            v_sub := null;   -- claims não-JSON: ignora
          end;
        end if;

        if v_sub is null then
          v_sub := nullif(current_setting('request.jwt.claim.sub', true), '');
        end if;

        if v_sub is null then
          return null;
        end if;

        begin
          return v_sub::uuid;
        exception when others then
          return null;       -- sub que não é UUID
        end;
      end
      $b$
    $f$;
    grant usage on schema auth to anon, authenticated, service_role;
    grant execute on function auth.uid() to anon, authenticated, service_role;
  end if;
end
$do$;

-- -----------------------------------------------------------------------------
-- Gatilho genérico de updated_at
-- -----------------------------------------------------------------------------
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $fn$
begin
  new.updated_at := now();
  return new;
end
$fn$;

-- -----------------------------------------------------------------------------
-- Configuração central (regra 22: nada de const no código;
--                      regra 23: timeout de offline é UM parâmetro só)
-- -----------------------------------------------------------------------------
create table if not exists public.app_settings (
  key         text primary key,
  value       text not null,
  description text not null default '',
  updated_at  timestamptz not null default now()
);

drop trigger if exists app_settings_touch on public.app_settings;
create trigger app_settings_touch
  before update on public.app_settings
  for each row execute function public.touch_updated_at();

-- `do nothing` (e não `do update`) é intencional: reaplicar a migration não
-- pode sobrescrever um valor que o operador já ajustou em produção.
insert into public.app_settings (key, value, description) values
  ('offline_timeout_seconds',        '180',
   'Segundos sem heartbeat para considerar a máquina offline. FONTE ÚNICA: view, cron de alertas e dashboard leem daqui.'),
  ('agent_interval_seconds',         '60',
   'Intervalo de coleta esperado do agente. Usado para dimensionar histerese e contagem de amostras/hora.'),
  ('clock_skew_future_seconds',      '300',
   'Tolerância para timestamp do agente no futuro. Acima disso a amostra é rejeitada (regra 12).'),
  ('backfill_max_age_seconds',       '172800',
   'Idade máxima de amostra reenviada do spool (48h). Acima disso a amostra é rejeitada.'),
  ('clock_drift_alert_seconds',      '120',
   'Drift sustentado entre relógio do agente e do servidor que caracteriza relógio quebrado.'),
  ('status_lookback_hours',          '168',
   'Janela em que a view de status procura a última amostra. Limita quantas partições o planejador varre.'),
  ('metrics_retention_days',         '30',
   'Retenção da série bruta. Granularidade mensal de partição: a retenção efetiva fica entre N e N+31 dias.'),
  ('metrics_hourly_retention_days',  '400',
   'Retenção do rollup horário (13 meses, para comparativo ano a ano).'),
  ('events_retention_days',          '1095',
   'Retenção da trilha de eventos e alertas.'),
  ('partition_months_ahead',         '3',
   'Meses de partição criados adiante. O cron diário mantém esta folga.'),
  ('ingest_rate_limit_per_minute',   '120',
   'Teto de requisições de ingestão por token por minuto (aplicado na Fase 2).'),
  ('ingest_max_batch_size',          '500',
   'Máximo de amostras por lote aceito pela ingestão (aplicado na Fase 2).')
on conflict (key) do nothing;

-- Falha alto e claro quando a chave não existe. Retornar null aqui produziria
-- `last_seen_at > now() - null` => toda máquina "offline" em silêncio.
create or replace function public.app_setting_int(p_key text)
returns integer
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_value text;
begin
  select value into v_value from public.app_settings where key = p_key;

  if v_value is null then
    raise exception 'configuração ausente em app_settings: %', p_key
      using errcode = 'no_data_found';
  end if;

  return v_value::integer;
end
$fn$;

create or replace function public.app_setting_text(p_key text)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_value text;
begin
  select value into v_value from public.app_settings where key = p_key;

  if v_value is null then
    raise exception 'configuração ausente em app_settings: %', p_key
      using errcode = 'no_data_found';
  end if;

  return v_value;
end
$fn$;

-- Intervalo de tolerância de offline, derivado da fonte única.
create or replace function public.offline_cutoff()
returns timestamptz
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select now() - make_interval(secs => public.app_setting_int('offline_timeout_seconds'))
$fn$;

comment on table public.app_settings is
  'Configuração central do monitoramento. Alterar aqui muda o comportamento de view, cron e dashboard simultaneamente.';
