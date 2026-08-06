-- =============================================================================
-- 0015 — Emissão de token para máquina EXISTENTE, identificada por GUID
-- =============================================================================
-- POR QUE ESTA FUNÇÃO EXISTE, e o bug que ela elimina:
--
-- provision_machine(site_code, label, ...) CRIA a máquina quando o label não
-- existe. Isso é correto para provisionamento, mas perigoso para qualquer
-- automação que reemita tokens: se o label chegar diferente por um único byte, a
-- função cria uma máquina nova em vez de reaproveitar a existente.
--
-- Foi exatamente o que aconteceu. O simulador lia o label do banco, devolvia por
-- PowerShell e o reenviava; "Estação gerência" atravessou uma camada com
-- codificação diferente, virou "Estaç?o ger?ncia", e o banco ganhou uma sexta
-- máquina fantasma — com histórico próprio e contando nos totais do dashboard.
--
-- Aqui a identidade é o GUID (regra 11), que é ASCII e não se corrompe. A função
-- FALHA se a máquina não existir, em vez de criar.
-- =============================================================================

create or replace function public.issue_agent_token(
  p_machine_id uuid,
  p_note       text default 'reemissão automática'
)
returns table (
  machine_id   uuid,
  site_code    text,
  label        text,
  token        text,
  token_prefix text
)
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_maq    record;
  v_token  text;
  v_prefix text;
  v_actor  text := coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''), session_user);
begin
  select m.id, m.label, m.site_id, s.code as site_code
    into v_maq
  from public.machines m
  join public.sites s on s.id = m.site_id
  where m.id = p_machine_id
    and m.is_active
    and s.is_active;

  -- Erro, NUNCA criação. É a diferença central em relação a provision_machine.
  if not found then
    raise exception 'máquina inexistente ou inativa: %', p_machine_id
      using errcode = 'MON01',
            hint = 'Cadastre a máquina com provision_machine antes de reemitir token.';
  end if;

  v_token  := 'mon_'
              || replace(gen_random_uuid()::text, '-', '')
              || replace(gen_random_uuid()::text, '-', '');
  v_prefix := left(v_token, 16);

  insert into public.agent_tokens (machine_id, token_prefix, token_hash, created_by)
  values (p_machine_id, v_prefix, sha256(convert_to(v_token, 'UTF8')), v_actor);

  insert into public.events (machine_id, site_id, kind, severity, message, payload)
  values (p_machine_id, v_maq.site_id, 'token_rotated', 'info',
          format('token reemitido para %s / %s (prefixo %s)',
                 v_maq.site_code, v_maq.label, v_prefix),
          jsonb_build_object('token_prefix', v_prefix, 'actor', v_actor, 'note', p_note));

  return query select v_maq.id, v_maq.site_code, v_maq.label, v_token, v_prefix;
end
$fn$;

revoke all on function public.issue_agent_token(uuid, text) from public;
grant execute on function public.issue_agent_token(uuid, text) to service_role;

comment on function public.issue_agent_token(uuid, text) is
  'Emite token para máquina EXISTENTE pelo GUID. Nunca cria máquina — ao contrário de provision_machine.';

-- -----------------------------------------------------------------------------
-- Limpeza das máquinas fantasma já criadas pelo bug
-- -----------------------------------------------------------------------------
-- Identifica pelo caractere de substituição (U+FFFD) e pelo '?' que sobra de
-- conversão malfeita. Restrito a labels que TAMBÉM têm um par bem-formado na
-- mesma loja, para nunca remover uma máquina legítima com nome incomum.
do $do$
declare
  r record;
  v_removidas integer := 0;
begin
  for r in
    select m.id, m.label, s.code as site_code
    from public.machines m
    join public.sites s on s.id = m.site_id
    where m.label ~ '[�]|\?'
      and exists (
        select 1 from public.machines m2
        where m2.site_id = m.site_id
          and m2.id <> m.id
          -- Mesmo nome depois de remover tudo que não é ASCII imprimível:
          -- é assim que o par corrompido é reconhecido.
          and regexp_replace(m2.label, '[^\x20-\x7E]', '', 'g')
            = regexp_replace(m.label, '[^\x20-\x7E?]', '', 'g')
      )
  loop
    delete from public.machines where id = r.id;
    v_removidas := v_removidas + 1;
    raise notice 'máquina fantasma removida: %/% (%)', r.site_code, r.label, r.id;
  end loop;

  if v_removidas > 0 then
    raise notice '% máquina(s) fantasma removida(s) — criadas por corrupção de codificação no label', v_removidas;
  end if;
end
$do$;
