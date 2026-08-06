-- =============================================================================
-- 0016 — Provisionar máquina pelo dashboard
-- =============================================================================
-- provision_machine() é EXECUTE só para service_role, e com razão: emitir
-- credencial não é operação de usuário comum. Mas exigir terminal e script para
-- cada máquina nova é atrito que, num parque de dezenas de lojas, garante que o
-- cadastro fique desatualizado.
--
-- Esta função abre esse caminho para o dashboard com três limites:
--   1. só admin (verificado DENTRO da função, não confiando no cliente)
--   2. o token aparece UMA vez, na resposta — não há como relê-lo depois
--   3. toda emissão vai para `events`, com o usuário que a fez
--
-- O token trafega para o navegador do admin. É o mesmo modelo de token pessoal do
-- GitHub: mostrado uma vez, e quem o vê já é quem poderia emitir outro.
-- =============================================================================

create or replace function public.provisionar_maquina_ui(
  p_site_code text,
  p_label     text,
  p_role_code text default 'pdv',
  p_services  text[] default null,
  p_site_name text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_site      record;
  v_brand_id  uuid;
  v_machine   uuid;
  v_token     text;
  v_prefix    text;
  v_nova_loja boolean := false;
  v_ator      text := coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
                               (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'),
                               session_user);
begin
  -- Autorização verificada AQUI. Uma função SECURITY DEFINER que confia no
  -- cliente para decidir quem é admin não é autorização, é decoração.
  if not public.current_user_is_admin() then
    raise exception 'apenas administradores podem cadastrar máquinas'
      using errcode = 'MON09';
  end if;

  if p_label is null or length(btrim(p_label)) = 0 then
    raise exception 'informe o nome da máquina' using errcode = 'MON07';
  end if;

  if p_site_code is null or length(btrim(p_site_code)) = 0 then
    raise exception 'informe a loja' using errcode = 'MON07';
  end if;

  if not exists (select 1 from public.machine_roles r where r.code = p_role_code) then
    raise exception 'perfil inválido: %', p_role_code using errcode = 'MON07';
  end if;

  -- ------------------------------------------------------------------- loja
  select s.id, s.code, s.name into v_site
  from public.sites s
  where upper(s.code) = upper(btrim(p_site_code));

  if not found then
    -- Loja nova entra sob a marca LOCAL, criada se preciso. Sem isso, cadastrar
    -- uma máquina numa loja ainda não registrada exigiria dois passos e o
    -- operador desistiria no meio.
    insert into public.brands (code, name)
    values ('LOCAL', 'Máquinas locais')
    on conflict do nothing;

    select b.id into v_brand_id from public.brands b where upper(b.code) = 'LOCAL';

    insert into public.sites (brand_id, code, name)
    values (v_brand_id, btrim(p_site_code),
            coalesce(nullif(btrim(p_site_name), ''), btrim(p_site_code)))
    returning sites.id, sites.code, sites.name into v_site;

    v_nova_loja := true;
  end if;

  -- ---------------------------------------------------------------- máquina
  select m.id into v_machine
  from public.machines m
  where m.site_id = v_site.id and m.label = btrim(p_label);

  if v_machine is null then
    insert into public.machines (site_id, role_code, label, critical_services_override, notes)
    values (v_site.id, p_role_code, btrim(p_label),
            case when p_services is null or cardinality(p_services) = 0 then null else p_services end,
            'cadastrada pelo dashboard')
    returning machines.id into v_machine;
  else
    -- Máquina já existe: atualiza o que o operador informou e emite token novo.
    -- É o caminho de "reinstalei aquele PDV", que precisa ser simples.
    update public.machines m
       set role_code = p_role_code,
           critical_services_override =
             case when p_services is null or cardinality(p_services) = 0
                  then m.critical_services_override else p_services end,
           is_active = true
     where m.id = v_machine;
  end if;

  -- ------------------------------------------------------------------ token
  v_token  := 'mon_'
              || replace(gen_random_uuid()::text, '-', '')
              || replace(gen_random_uuid()::text, '-', '');
  v_prefix := left(v_token, 16);

  insert into public.agent_tokens (machine_id, token_prefix, token_hash, created_by)
  values (v_machine, v_prefix, sha256(convert_to(v_token, 'UTF8')), v_ator);

  insert into public.events (machine_id, site_id, kind, severity, message, payload)
  values (v_machine, v_site.id, 'machine_provisioned', 'info',
          format('cadastrada pelo dashboard: %s / %s (prefixo %s)',
                 v_site.code, btrim(p_label), v_prefix),
          jsonb_build_object('token_prefix', v_prefix, 'actor', v_ator,
                             'role', p_role_code, 'via', 'dashboard'));

  return jsonb_build_object(
    'ok', true,
    'machine_id', v_machine,
    'site_code', v_site.code,
    'site_name', v_site.name,
    'site_criada', v_nova_loja,
    'label', btrim(p_label),
    'role', p_role_code,
    'token', v_token,
    'token_prefix', v_prefix
  );
end
$fn$;

revoke all on function public.provisionar_maquina_ui(text, text, text, text[], text) from public;
grant execute on function public.provisionar_maquina_ui(text, text, text, text[], text)
  to authenticated, service_role;

comment on function public.provisionar_maquina_ui(text, text, text, text[], text) is
  'Cadastra máquina e emite token pelo dashboard. Só admin; o token aparece uma única vez.';

-- -----------------------------------------------------------------------------
-- Lista de lojas e perfis para os campos do formulário
-- -----------------------------------------------------------------------------
-- Uma chamada em vez de três: o formulário abre com tudo o que precisa, e não há
-- estado intermediário onde metade das opções carregou.
create or replace function public.opcoes_cadastro()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select jsonb_build_object(
    'lojas', coalesce((
      select jsonb_agg(jsonb_build_object('code', s.code, 'name', s.name, 'brand', b.code)
                       order by s.code)
      from public.sites s
      join public.brands b on b.id = s.brand_id
      where s.is_active
        and s.id in (select public.current_user_site_ids())
    ), '[]'::jsonb),
    'perfis', coalesce((
      select jsonb_agg(jsonb_build_object('code', r.code, 'name', r.name,
                                          'services', r.critical_services)
                       order by r.code)
      from public.machine_roles r
    ), '[]'::jsonb),
    'is_admin', public.current_user_is_admin()
  )
$fn$;

revoke all on function public.opcoes_cadastro() from public;
grant execute on function public.opcoes_cadastro() to authenticated, service_role;
