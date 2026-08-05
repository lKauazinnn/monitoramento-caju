-- =============================================================================
-- Teste 03 — Provisionamento, uso e revogação de token
-- =============================================================================
-- Critério de aceite da Fase 1: "a função de provisionamento gera token
-- utilizável".
--
-- Roda inteiro dentro de uma transação com ROLLBACK: nada fica no banco.
-- =============================================================================

begin;

do $t$
begin
  if not exists (select 1 from public.sites where code = 'BSB-001') then
    raise exception
      'PRÉ-REQUISITO AUSENTE: rode supabase/seed/seed_demo.sql antes deste teste';
  end if;
end
$t$;

do $t$
declare
  v_prov      record;
  v_prov2     record;
  v_verificado uuid;
  v_hash      bytea;
  v_vazou     bigint;
  v_bloqueado boolean;
begin
  -- -------------------------------------------------------------------------
  raise notice '-- 03.1 emissão de token para máquina nova';
  -- -------------------------------------------------------------------------
  select * into v_prov
  from public.provision_machine('BSB-001', 'TESTE-AUTOMATIZADO', 'pdv', 'fixture do teste 03');

  if v_prov.token is null or v_prov.token !~ '^mon_[0-9a-f]{64}$' then
    raise exception 'FALHA: formato de token inesperado: %', v_prov.token;
  end if;

  if not v_prov.is_new_machine then
    raise exception 'FALHA: máquina deveria ser nova';
  end if;

  if v_prov.machine_id is null then
    raise exception 'FALHA: provisionamento não devolveu o GUID da máquina';
  end if;

  raise notice 'OK: token emitido (prefixo %, máquina %)', v_prov.token_prefix, v_prov.machine_id;

  -- -------------------------------------------------------------------------
  raise notice '-- 03.2 o texto claro NÃO fica no banco (regra 2)';
  -- -------------------------------------------------------------------------
  select count(*) into v_vazou
  from public.agent_tokens t
  where t.token_prefix = v_prov.token          -- prefixo não pode ser o token todo
     or position(v_prov.token in t.token_prefix) > 0;

  if v_vazou <> 0 then
    raise exception 'FALHA CRÍTICA: texto claro do token encontrado em agent_tokens';
  end if;

  select t.token_hash into v_hash
  from public.agent_tokens t
  where t.token_prefix = v_prov.token_prefix;

  if v_hash is distinct from sha256(convert_to(v_prov.token, 'UTF8')) then
    raise exception 'FALHA: hash armazenado não corresponde ao SHA-256 do token';
  end if;

  if octet_length(v_hash) <> 32 then
    raise exception 'FALHA: hash com % bytes (esperado 32)', octet_length(v_hash);
  end if;

  -- A view administrativa não pode projetar o hash.
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'agent_tokens_admin'
      and column_name = 'token_hash'
  ) then
    raise exception 'FALHA: agent_tokens_admin expõe token_hash';
  end if;

  raise notice 'OK: só o hash SHA-256 persistido, e a view não o projeta';

  -- -------------------------------------------------------------------------
  raise notice '-- 03.3 o token é utilizável';
  -- -------------------------------------------------------------------------
  v_verificado := public.verify_agent_token(v_prov.token);

  if v_verificado is distinct from v_prov.machine_id then
    raise exception 'FALHA: verify_agent_token devolveu % (esperado %)',
      v_verificado, v_prov.machine_id;
  end if;

  if public.verify_agent_token(v_prov.token || 'x') is not null then
    raise exception 'FALHA: token alterado foi aceito';
  end if;

  if public.verify_agent_token('mon_' || repeat('0', 64)) is not null then
    raise exception 'FALHA: token inexistente foi aceito';
  end if;

  raise notice 'OK: token resolve para a máquina correta; token alterado/inexistente rejeitado';

  -- -------------------------------------------------------------------------
  raise notice '-- 03.4 reprovisionar sem p_rotate é bloqueado';
  -- -------------------------------------------------------------------------
  v_bloqueado := false;
  begin
    perform public.provision_machine('BSB-001', 'TESTE-AUTOMATIZADO', 'pdv');
  exception
    when others then
      v_bloqueado := true;
  end;

  if not v_bloqueado then
    raise exception 'FALHA: segundo token emitido sem p_rotate => acúmulo silencioso de credencial';
  end if;

  raise notice 'OK: emissão duplicada exige intenção explícita (p_rotate)';

  -- -------------------------------------------------------------------------
  raise notice '-- 03.5 rotação com sobreposição: os dois tokens valem';
  -- -------------------------------------------------------------------------
  select * into v_prov2
  from public.provision_machine('BSB-001', 'TESTE-AUTOMATIZADO', 'pdv', '', true);

  if v_prov2.machine_id is distinct from v_prov.machine_id then
    raise exception 'FALHA: rotação criou máquina nova (deveria reaproveitar o GUID)';
  end if;

  if v_prov2.is_new_machine then
    raise exception 'FALHA: rotação marcou a máquina como nova';
  end if;

  if v_prov2.token = v_prov.token then
    raise exception 'FALHA CRÍTICA: rotação devolveu o mesmo token';
  end if;

  if public.verify_agent_token(v_prov.token)  is null
  or public.verify_agent_token(v_prov2.token) is null then
    raise exception 'FALHA: rotação deveria manter os dois tokens válidos durante a sobreposição';
  end if;

  raise notice 'OK: token novo emitido, antigo ainda válido (janela de sobreposição)';

  -- -------------------------------------------------------------------------
  raise notice '-- 03.6 revogação individual';
  -- -------------------------------------------------------------------------
  perform public.revoke_agent_token(v_prov.token_prefix, 'teste 03.6');

  if public.verify_agent_token(v_prov.token) is not null then
    raise exception 'FALHA CRÍTICA: token revogado continua válido';
  end if;

  if public.verify_agent_token(v_prov2.token) is null then
    raise exception 'FALHA: revogar um token invalidou o outro da mesma máquina';
  end if;

  raise notice 'OK: revogação é individual e imediata';

  -- -------------------------------------------------------------------------
  raise notice '-- 03.7 revogar duas vezes falha alto';
  -- -------------------------------------------------------------------------
  v_bloqueado := false;
  begin
    perform public.revoke_agent_token(v_prov.token_prefix, 'segunda tentativa');
  exception
    when others then
      v_bloqueado := true;
  end;

  if not v_bloqueado then
    raise exception 'FALHA (regra 14): revogar token já revogado devolveu sucesso';
  end if;

  raise notice 'OK: revogação repetida é erro, não sucesso silencioso';

  -- -------------------------------------------------------------------------
  raise notice '-- 03.8 máquina inativa invalida o token';
  -- -------------------------------------------------------------------------
  update public.machines set is_active = false where id = v_prov.machine_id;

  if public.verify_agent_token(v_prov2.token) is not null then
    raise exception 'FALHA: token de máquina desativada continua válido';
  end if;

  update public.machines set is_active = true where id = v_prov.machine_id;

  -- Loja inativa também deve invalidar.
  update public.sites set is_active = false where code = 'BSB-001';

  if public.verify_agent_token(v_prov2.token) is not null then
    raise exception 'FALHA: token de loja desativada continua válido';
  end if;

  raise notice 'OK: desativar máquina ou loja invalida o token imediatamente';

  -- -------------------------------------------------------------------------
  raise notice '-- 03.9 loja inexistente falha alto (regra 14)';
  -- -------------------------------------------------------------------------
  v_bloqueado := false;
  begin
    perform public.provision_machine('LOJA-QUE-NAO-EXISTE', 'PDV 01');
  exception
    when others then
      v_bloqueado := true;
  end;

  if not v_bloqueado then
    raise exception 'FALHA (regra 14): provisionar em loja inexistente não deu erro';
  end if;

  raise notice 'OK: loja inexistente é erro explícito';

  -- -------------------------------------------------------------------------
  raise notice '-- 03.10 trilha de auditoria registrada';
  -- -------------------------------------------------------------------------
  if not exists (
    select 1 from public.events e
    where e.machine_id = v_prov.machine_id and e.kind = 'machine_provisioned'
  ) then
    raise exception 'FALHA: emissão de token não gerou evento machine_provisioned';
  end if;

  if not exists (
    select 1 from public.events e
    where e.machine_id = v_prov.machine_id and e.kind = 'token_rotated'
  ) then
    raise exception 'FALHA: rotação não gerou evento token_rotated';
  end if;

  if not exists (
    select 1 from public.events e
    where e.machine_id = v_prov.machine_id
      and e.kind = 'token_revoked'
      and e.payload ->> 'token_prefix' = v_prov.token_prefix
  ) then
    raise exception 'FALHA: revogação não gerou evento token_revoked';
  end if;

  -- Nenhum evento pode conter o texto claro do token.
  if exists (
    select 1 from public.events e
    where position(v_prov.token in e.message) > 0
       or position(v_prov.token in e.payload::text) > 0
  ) then
    raise exception 'FALHA CRÍTICA: texto claro do token vazou para a trilha de eventos';
  end if;

  raise notice 'OK: trilha completa em events, sem texto claro de token';
end
$t$;

rollback;

\echo '== 03 CONCLUÍDO: ciclo de vida do token verificado =='
