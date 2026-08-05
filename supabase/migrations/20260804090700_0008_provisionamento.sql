-- =============================================================================
-- 0008 — Provisionamento e ciclo de vida do token
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Provisiona máquina e emite token
-- -----------------------------------------------------------------------------
-- O texto claro do token é devolvido UMA ÚNICA VEZ, aqui. Não há caminho de
-- recuperação: no banco só existe o SHA-256. Perdeu o token, rotaciona.
create or replace function public.provision_machine(
  p_site_code text,
  p_label     text,
  p_role_code text default 'pdv',
  p_notes     text default '',
  p_rotate    boolean default false
)
returns table (
  machine_id   uuid,
  site_code    text,
  site_name    text,
  label        text,
  role_code    text,
  token        text,
  token_prefix text,
  is_new_machine boolean
)
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_site        record;
  v_machine_id  uuid;
  v_is_new      boolean := false;
  v_active_cnt  integer;
  v_token       text;
  v_prefix      text;
  v_actor       text;
begin
  if p_label is null or length(btrim(p_label)) = 0 then
    raise exception 'label da máquina é obrigatório';
  end if;

  select s.id, s.code, s.name into v_site
  from public.sites s
  where upper(s.code) = upper(btrim(p_site_code)) and s.is_active;

  -- `not found` em vez de testar v_site.id: não depende de como o PL/pgSQL
  -- trata acesso a campo de record sem linha atribuída.
  if not found then
    raise exception 'loja inexistente ou inativa: %', p_site_code
      using hint = 'Cadastre a loja em public.sites antes de provisionar máquinas.';
  end if;

  if not exists (select 1 from public.machine_roles r where r.code = p_role_code) then
    raise exception 'perfil de máquina inválido: % (válidos: %)',
      p_role_code,
      (select string_agg(r.code, ', ' order by r.code) from public.machine_roles r);
  end if;

  select m.id into v_machine_id
  from public.machines m
  where m.site_id = v_site.id and m.label = btrim(p_label);

  if v_machine_id is null then
    insert into public.machines (site_id, role_code, label, notes)
    values (v_site.id, p_role_code, btrim(p_label), coalesce(p_notes, ''))
    returning id into v_machine_id;
    v_is_new := true;
  else
    -- Máquina já existe: emitir segundo token só com intenção explícita,
    -- para não acumular credencial esquecida por engano.
    select count(*) into v_active_cnt
    from public.agent_tokens t
    where t.machine_id = v_machine_id
      and t.revoked_at is null
      and (t.expires_at is null or t.expires_at > now());

    if v_active_cnt > 0 and not p_rotate then
      raise exception
        'máquina %/% já possui % token(s) ativo(s)', v_site.code, btrim(p_label), v_active_cnt
        using hint = 'Para rotação com sobreposição chame com p_rotate => true, '
                     'confirme o heartbeat com o token novo e só então revogue o antigo.';
    end if;
  end if;

  -- 244 bits de entropia de gen_random_uuid() (pg_strong_random). Sem hifens
  -- para colar direto no config.json sem escaping.
  v_token  := 'mon_'
              || replace(gen_random_uuid()::text, '-', '')
              || replace(gen_random_uuid()::text, '-', '');
  v_prefix := left(v_token, 16);

  v_actor := coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    session_user
  );

  insert into public.agent_tokens (machine_id, token_prefix, token_hash, created_by)
  values (v_machine_id, v_prefix, sha256(convert_to(v_token, 'UTF8')), v_actor);

  insert into public.events (machine_id, site_id, kind, severity, message, payload)
  values (
    v_machine_id, v_site.id,
    case when v_is_new then 'machine_provisioned' else 'token_rotated' end,
    'info',
    format('token %s emitido para %s / %s (prefixo %s)',
           case when v_is_new then 'inicial' else 'de rotação' end,
           v_site.code, btrim(p_label), v_prefix),
    jsonb_build_object('token_prefix', v_prefix, 'actor', v_actor, 'role', p_role_code)
  );

  -- O perfil devolvido é o REAL da máquina, não o solicitado: reprovisionar uma
  -- máquina existente não muda o perfil dela, e o operador precisa ver isso.
  return query
    select v_machine_id, v_site.code, v_site.name, m.label,
           m.role_code, v_token, v_prefix, v_is_new
    from public.machines m
    where m.id = v_machine_id;
end
$fn$;

comment on function public.provision_machine(text, text, text, text, boolean) is
  'Cria/reaproveita a máquina e emite token. O texto claro sai UMA vez — só o hash é persistido.';

-- -----------------------------------------------------------------------------
-- Revogação individual (regra 2)
-- -----------------------------------------------------------------------------
create or replace function public.revoke_agent_token(
  p_token_prefix text,
  p_reason       text default 'revogado manualmente'
)
returns table (token_prefix text, machine_id uuid, site_code text, label text, revoked_at timestamptz)
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_actor      text := coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''), session_user);
  v_machine_id uuid;
  v_revoked    timestamptz;
  v_reason     text := coalesce(nullif(btrim(p_reason), ''), 'revogado manualmente');
begin
  update public.agent_tokens t
     set revoked_at = now(),
         revoked_reason = v_reason
   where t.token_prefix = btrim(p_token_prefix)
     and t.revoked_at is null
  returning t.machine_id, t.revoked_at
    into v_machine_id, v_revoked;

  if v_machine_id is null then
    raise exception 'nenhum token ATIVO com prefixo %', p_token_prefix
      using hint = 'Consulte public.agent_tokens_admin — o token pode já estar revogado ou o prefixo estar errado.';
  end if;

  insert into public.events (machine_id, site_id, kind, severity, message, payload)
  select v_machine_id, m.site_id, 'token_revoked', 'warning',
         format('token %s revogado (%s)', btrim(p_token_prefix), v_reason),
         jsonb_build_object('token_prefix', btrim(p_token_prefix), 'actor', v_actor, 'reason', v_reason)
  from public.machines m
  where m.id = v_machine_id;

  return query
    select btrim(p_token_prefix), v_machine_id, s.code, m.label, v_revoked
    from public.machines m
    join public.sites s on s.id = m.site_id
    where m.id = v_machine_id;
end
$fn$;

-- -----------------------------------------------------------------------------
-- Validação de token (consumida pela ingestão na Fase 2)
-- -----------------------------------------------------------------------------
-- Não há comparação byte a byte de segredo aqui: o token recebido é hasheado e
-- procurado por igualdade em índice único. O tempo de resposta depende do
-- índice, não de quantos bytes do segredo coincidem — não há oráculo de tempo
-- sobre o token. A comparação em tempo constante exigida pela Fase 2 se aplica
-- ao segredo compartilhado da Edge Function, que é comparado em memória.
create or replace function public.verify_agent_token(p_token text)
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select t.machine_id
  from public.agent_tokens t
  join public.machines m on m.id = t.machine_id
  join public.sites s on s.id = m.site_id
  where t.token_hash = sha256(convert_to(p_token, 'UTF8'))
    and t.revoked_at is null
    and (t.expires_at is null or t.expires_at > now())
    and m.is_active
    and s.is_active
  limit 1
$fn$;

-- Contabilidade de uso, separada da validação para que verify_agent_token
-- permaneça sem efeito colateral (e testável).
create or replace function public.touch_agent_token(p_token_hash bytea)
returns void
language sql
volatile
security definer
set search_path = public, pg_temp
as $fn$
  update public.agent_tokens
     set last_used_at = now(),
         use_count = use_count + 1
   where token_hash = p_token_hash
     and (last_used_at is null or last_used_at < now() - interval '5 minutes')
$fn$;

comment on function public.touch_agent_token(bytea) is
  'Atualiza no máximo a cada 5 min: evita uma escrita por agente por ciclo em linha quente.';
