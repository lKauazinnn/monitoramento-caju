-- =============================================================================
-- 0044 — Escolher quais volumes acompanhar
-- =============================================================================
-- Hoje a decisão de qual volume vale é 100% automática: a 0036 ignora volumes
-- abaixo de `disk_ignore_below_gb` e o resto entra na conta, com o mais apertado
-- virando o número do cartão. Não há como dizer "acompanhe C: e D:" nem
-- "acompanhe só C:".
--
-- Isso quebra em dois casos reais desta frota:
--
--   Um D: de backup que vive em 95% cheio, de propósito, mantém a loja em
--   ATENÇÃO para sempre e o alerta de disco fica gritando por uma condição
--   normal. É o caminho mais curto para o alerta de disco ser ignorado -- e
--   junto com ele o C: que enche de verdade.
--
--   O inverso também: quem quer acompanhar os dois hoje não tem como saber que o
--   cartão está falando de UM volume só, porque o cartão mostra o pior.
--
-- A escolha é do OPERADOR e por MÁQUINA, porque a resposta depende do que aquele
-- disco faz naquele PC -- não existe regra global que acerte isso.
--
-- DUAS COISAS DIFERENTES, de propósito:
--
--   `disk_ignore_below_gb` é uma HEURÍSTICA de tamanho, e por isso tem escape: a
--   0036 volta a considerar o maior volume pequeno quando não sobrou nenhum
--   grande, para uma máquina nunca perder a leitura de disco.
--
--   O que esta migração adiciona é uma DECISÃO explícita, e decisão não tem
--   escape. Se a pessoa desmarcou D:, D: não volta pela porta de trás -- nem
--   quando é o único volume que sobrou. Nesse caso o cartão fica sem número de
--   disco, e está certo: foi o que se pediu.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. A tabela de escolhas
-- -----------------------------------------------------------------------------
-- Guarda o que foi TOCADO, não o estado de todos os volumes. Um disco novo que
-- aparece amanhã não está na tabela e portanto é acompanhado -- o padrão seguro é
-- vigiar. Se a tabela guardasse o estado completo, um pendrive novo entraria como
-- não-acompanhado e ninguém saberia por quê.
create table if not exists public.machine_volumes (
  machine_id  uuid not null references public.machines(id) on delete cascade,
  -- Sempre em maiúscula: o agente manda 'C:' mas nada garante que continue. Duas
  -- linhas 'c:' e 'C:' para o mesmo volume seriam duas escolhas conflitantes para
  -- a mesma coisa, e a última venceria por acidente de ordenação.
  drive       text not null,
  acompanhar  boolean not null default true,
  nota        text,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,

  primary key (machine_id, drive),
  constraint machine_volumes_drive_ck check (drive = upper(btrim(drive)) and length(drive) between 1 and 16)
);

comment on table public.machine_volumes is
  'Escolha explícita de quais volumes de cada máquina entram nas métricas e nos alertas. Só as exceções ficam gravadas; ausente = acompanhado.';
comment on column public.machine_volumes.acompanhar is
  'false remove o volume das métricas e dos alertas. Não tem escape: mesmo sendo o único volume, ele não volta.';

alter table public.machine_volumes enable row level security;

-- Leitura pelo escopo do usuário, como o resto. Escrita só pela função abaixo --
-- nenhuma policy de INSERT/UPDATE para role pública.
drop policy if exists machine_volumes_leitura on public.machine_volumes;
create policy machine_volumes_leitura on public.machine_volumes
  for select to authenticated
  using (
    exists (
      select 1 from public.machines m
      join public.sites s on s.id = m.site_id
      where m.id = machine_volumes.machine_id
        and (s.id in (select public.current_user_site_ids()) or public.current_user_is_admin())
    )
  );

drop trigger if exists machine_volumes_touch on public.machine_volumes;
create trigger machine_volumes_touch
  before update on public.machine_volumes
  for each row execute function public.touch_updated_at();

-- -----------------------------------------------------------------------------
-- 2. A view, recriada com o filtro
-- -----------------------------------------------------------------------------
-- Cópia da 0040 com UMA mudança de comportamento: volumes com acompanhar=false
-- saem antes de qualquer conta. Recriada inteira porque é assim que este
-- repositório trata views -- um patch textual sobre pg_get_viewdef seria mais
-- curto e impossível de revisar.
create or replace view public.machines_status
with (security_invoker = true) as
SELECT m.id AS machine_id, m.label, m.hostname, m.role_code,
    r.name AS role_name,
    s.id AS site_id, s.code AS site_code, s.name AS site_name, s.timezone AS site_timezone,
    b.id AS brand_id, b.code AS brand_code, b.name AS brand_name,
    m.is_active, m.last_seen_at, m.last_boot_at, m.agent_version, m.clock_drift_seconds,
    m.os_caption, m.cpu_model, m.cpu_cores, m.mem_total_mb, m.ip_lan,
    m.maintenance_until IS NOT NULL AND m.maintenance_until > now() AS in_maintenance,
    m.maintenance_until,
        CASE
            WHEN NOT m.is_active THEN 'disabled'::text
            WHEN COALESCE(m.last_contact_at, m.last_seen_at) IS NULL THEN 'never_seen'::text
            WHEN COALESCE(m.last_contact_at, m.last_seen_at) > offline_cutoff() THEN 'online'::text
            ELSE 'offline'::text
        END AS status,
        CASE
            WHEN COALESCE(m.last_contact_at, m.last_seen_at) IS NULL THEN NULL::integer
            ELSE EXTRACT(epoch FROM now() - COALESCE(m.last_contact_at, m.last_seen_at))::integer
        END AS seconds_since_seen,
    lm."time" AS last_sample_at,
    lm.cpu_pct, lm.mem_pct, lm.mem_used_mb, lm.uptime_seconds, lm.cpu_temp_c,
    lm.gw_latency_ms, lm.gw_loss_pct, lm.central_latency_ms, lm.collect_flags,
    ld.disk_min_free_pct, ld.disk_min_free_gb, ld.disk_worst_drive,
    COALESCE(lsv.services_down, 0::bigint) AS services_down,
    lsv.services_down_names,
    m.os_version, m.os_arch,
    m.mac_address, m.mac_is_wifi,
    m.last_contact_at,
    ld.disk_worst_free_gb, ld.disk_worst_total_gb,
    ld.disk_volumes_ignorados,
    m.mac_is_virtual, m.virt_fabricante, m.virt_modelo, m.virt_uuid,
    public.hipervisor_de(m.virt_fabricante, m.virt_modelo, m.virt_bios) AS hipervisor,
  ld.disk_worst_media_type,
  ld.disk_worst_smart_ok,
  ld.disk_worst_wear_pct,
  ld.disk_worst_power_on_hours,
  ld.disk_pior_wear_pct,
  ld.disk_maior_horas,
  -- 0044: quantos volumes o operador tirou do acompanhamento. Vai para a tela.
  --
  -- Não é detalhe de auditoria: sem este número o cartão diria "disco 40 GB de
  -- 120" sem avisar que existe um segundo volume cheio fora da conta, e a pessoa
  -- que desmarcou não é necessariamente a que está olhando.
  COALESCE(lvf.disk_volumes_fora, 0::bigint) AS disk_volumes_fora,
  -- Quais são, para a dica caber na tela sem uma segunda consulta por máquina.
  lvf.disk_drives_fora
   FROM machines m
     JOIN sites s ON s.id = m.site_id
     JOIN brands b ON b.id = s.brand_id
     JOIN machine_roles r ON r.code = m.role_code
     LEFT JOIN LATERAL ( SELECT x."time", x.cpu_pct, x.mem_pct, x.mem_used_mb,
            x.uptime_seconds, x.cpu_temp_c, x.gw_latency_ms, x.gw_loss_pct,
            x.central_latency_ms, x.collect_flags
           FROM metrics x
          WHERE x.machine_id = m.id AND x."time" > (now() - make_interval(hours => app_setting_int('status_lookback_hours'::text)))
          ORDER BY x."time" DESC
         LIMIT 1) lm ON true
     LEFT JOIN LATERAL (
       SELECT
         (array_agg(v.free_pct ORDER BY v.ordem))[1]                   AS disk_min_free_pct,
         (array_agg(v.free_gb  ORDER BY v.conta DESC, v.free_gb))[1]   AS disk_min_free_gb,
         (array_agg(v.drive    ORDER BY v.ordem))[1]                   AS disk_worst_drive,
         (array_agg(v.free_gb  ORDER BY v.ordem))[1]                   AS disk_worst_free_gb,
         (array_agg(v.total_gb ORDER BY v.ordem))[1]                   AS disk_worst_total_gb,
         count(*) FILTER (WHERE NOT v.conta)                           AS disk_volumes_ignorados,
         (array_agg(v.media_type ORDER BY v.ordem))[1]                 AS disk_worst_media_type,
         (array_agg(v.smart_ok   ORDER BY v.ordem))[1]                 AS disk_worst_smart_ok,
         (array_agg(v.wear       ORDER BY v.ordem))[1]                 AS disk_worst_wear_pct,
         (array_agg(v.horas      ORDER BY v.ordem))[1]                 AS disk_worst_power_on_hours,
         max(v.wear)                                                   AS disk_pior_wear_pct,
         max(v.horas)                                                  AS disk_maior_horas
       FROM (
         SELECT d.drive, d.free_pct, d.free_gb, d.total_gb,
                d.media_type, d.smart_ok,
                d.smart_wear_pct AS wear, d.smart_power_on_hours AS horas,
                (d.total_gb IS NULL
                 OR d.total_gb >= app_setting_int('disk_ignore_below_gb'::text)) AS conta,
                (CASE
                   WHEN d.total_gb IS NULL
                     OR d.total_gb >= app_setting_int('disk_ignore_below_gb'::text)
                   THEN coalesce(d.free_pct, 100)::numeric
                   ELSE 1e6 - coalesce(d.total_gb, 0)
                 END) AS ordem
         FROM metrics_disks d
         -- 0044: o volume desmarcado sai AQUI, antes de qualquer agregação.
         -- Filtrar depois (num FILTER, ou dando ordem alta) deixaria a porta do
         -- escape da 0036 aberta: quando não sobra nenhum volume grande, o
         -- array_agg pegaria o desmarcado por falta de opção.
         LEFT JOIN public.machine_volumes mv
                ON mv.machine_id = d.machine_id
               AND mv.drive = upper(btrim(d.drive))
         WHERE d.machine_id = m.id AND d."time" = lm."time"
           AND coalesce(mv.acompanhar, true)
       ) v) ld ON true
     LEFT JOIN LATERAL (
       -- Os desmarcados, contados à parte justamente porque saíram da conta
       -- acima. Sem esta lateral eles seriam invisíveis para a tela.
       SELECT count(*) AS disk_volumes_fora,
              string_agg(d2.drive, ', ' ORDER BY d2.drive) AS disk_drives_fora
       FROM metrics_disks d2
       JOIN public.machine_volumes mv2
            ON mv2.machine_id = d2.machine_id
           AND mv2.drive = upper(btrim(d2.drive))
       WHERE d2.machine_id = m.id AND d2."time" = lm."time"
         AND mv2.acompanhar = false
     ) lvf ON true
     LEFT JOIN LATERAL ( SELECT count(*) FILTER (WHERE NOT sv.is_running) AS services_down,
            array_agg(sv.service_name ORDER BY sv.service_name) FILTER (WHERE NOT sv.is_running) AS services_down_names
           FROM metrics_services sv
          WHERE sv.machine_id = m.id AND sv."time" = lm."time") lsv ON true;

-- -----------------------------------------------------------------------------
-- 3. A gaveta passa a dizer quem está acompanhado
-- -----------------------------------------------------------------------------
-- Recriada inteira, mantendo o que a 0042 acrescentou (realocados/pendentes) e
-- somando `acompanhando`. A gaveta mostra TODOS os volumes, inclusive os
-- desmarcados: é lá que se marca de volta, e um volume que desaparece da lista
-- quando é desmarcado não teria como ser reativado.
create or replace function public.discos_da_maquina(p_machine_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_t timestamptz;
begin
  -- Escopo como na 0042. `current_user_is_admin` some daqui de propósito: a 0042
  -- exige loja do usuário, e o admin já tem todas as lojas em
  -- current_user_site_ids. Acrescentar o teste de admin aqui mudaria o escopo de
  -- uma função existente sem ninguém pedir.
  if not exists (
    select 1 from public.machines m
    where m.id = p_machine_id
      and m.site_id in (select public.current_user_site_ids())
  ) then
    raise exception 'esta máquina não é de uma loja sua' using errcode = 'MON09';
  end if;

  select max(d."time") into v_t
  from public.metrics_disks d
  where d.machine_id = p_machine_id
    and d."time" > now() - make_interval(hours => public.app_setting_int('status_lookback_hours'));

  -- A FORMA do retorno é a da 0042: um objeto com `medido_em` e `discos`, e os
  -- nomes de campo que o painel já lê (free_gb, saude_ked...). A primeira versão
  -- desta migração devolvia um array cru com nomes novos (`livre_gb`), porque eu
  -- copiei o corpo da 0040 sem ver que a 0042 mudou a forma -- e a gaveta de
  -- discos teria ficado vazia em produção, sem erro nenhum no console.
  if v_t is null then
    return jsonb_build_object('medido_em', null, 'discos', '[]'::jsonb);
  end if;

  return jsonb_build_object(
    'medido_em', v_t,
    'discos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'drive', d.drive,
               'etiqueta', d.volume_label,
               'fs', d.filesystem,
               'total_gb', d.total_gb,
               'free_gb', d.free_gb,
               'free_pct', d.free_pct,
               'tipo', d.media_type,
               'saude_ok', d.smart_ok,
               'fonte', d.smart_source,
               'desgaste_pct', d.smart_wear_pct,
               'horas_ligado', d.smart_power_on_hours,
               'realocados', d.smart_reallocated,
               'pendentes', d.smart_pending,
               -- 0044: ausente na tabela = acompanhado. O padrão seguro é vigiar.
               'acompanhando', coalesce(mv.acompanhar, true),
               'nota', mv.nota,
               -- Ignorado por TAMANHO é outra coisa que ignorado por ESCOLHA, e a
               -- tela precisa dizer qual dos dois -- senão a pessoa desmarca um
               -- volume que já estava fora e não vê nada mudar.
               'pequeno', (d.total_gb is not null
                           and d.total_gb < public.app_setting_int('disk_ignore_below_gb'))
             ) order by d.total_gb desc nulls last)
      from public.metrics_disks d
      left join public.machine_volumes mv
             on mv.machine_id = d.machine_id
            and mv.drive = upper(btrim(d.drive))
      where d.machine_id = p_machine_id and d."time" = v_t), '[]'::jsonb));
end
$fn$;

-- -----------------------------------------------------------------------------
-- 4. Marcar e desmarcar
-- -----------------------------------------------------------------------------
create or replace function public.definir_volume_acompanhado(
  p_machine_id uuid,
  p_drive      text,
  p_acompanhar boolean,
  p_nota       text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_drive text;
  v_label text;
  v_existe boolean;
  v_antes  boolean;
  v_sobra  integer;
begin
  if not public.current_user_is_admin() then
    raise exception 'apenas administradores escolhem os volumes acompanhados'
      using errcode = 'MON09';
  end if;

  select m.label into v_label
  from public.machines m
  join public.sites s on s.id = m.site_id
  where m.id = p_machine_id
    and (s.id in (select public.current_user_site_ids()) or public.current_user_is_admin());

  if v_label is null then
    raise exception 'máquina inexistente ou fora do seu escopo' using errcode = 'MON09';
  end if;

  v_drive := upper(btrim(coalesce(p_drive, '')));
  if v_drive = '' then
    raise exception 'informe o volume' using errcode = 'MON07';
  end if;

  -- O volume tem de EXISTIR numa amostra recente. Sem esta conferência, um erro
  -- de digitação gravaria uma escolha para 'X:' que nunca vai casar com nada, e
  -- a pessoa ficaria esperando um efeito que não vem.
  select exists (
    select 1 from public.metrics_disks d
    where d.machine_id = p_machine_id
      and upper(btrim(d.drive)) = v_drive
      and d."time" > now() - make_interval(hours => public.app_setting_int('status_lookback_hours'))
  ) into v_existe;

  if not v_existe then
    raise exception 'a máquina % não reportou o volume % nas últimas leituras',
      v_label, v_drive using errcode = 'MON01';
  end if;

  select mv.acompanhar into v_antes
  from public.machine_volumes mv
  where mv.machine_id = p_machine_id and mv.drive = v_drive;

  insert into public.machine_volumes (machine_id, drive, acompanhar, nota, updated_by)
  values (p_machine_id, v_drive, coalesce(p_acompanhar, true), nullif(btrim(p_nota), ''), auth.uid())
  on conflict (machine_id, drive) do update
    set acompanhar = excluded.acompanhar,
        nota = coalesce(excluded.nota, public.machine_volumes.nota),
        updated_by = excluded.updated_by;

  -- Aviso, não recusa: desmarcar o último volume é uma escolha legítima (uma
  -- máquina onde disco não interessa), mas quem faz precisa saber que a partir
  -- daí NÃO existe alerta de disco para ela. Recusar seria decidir pelo operador;
  -- deixar calado seria pior.
  select count(*) into v_sobra
  from public.metrics_disks d
  left join public.machine_volumes mv
         on mv.machine_id = d.machine_id and mv.drive = upper(btrim(d.drive))
  where d.machine_id = p_machine_id
    and d."time" > now() - make_interval(hours => public.app_setting_int('status_lookback_hours'))
    and coalesce(mv.acompanhar, true);

  if v_antes is distinct from coalesce(p_acompanhar, true) then
    insert into public.events (machine_id, kind, severity, message, payload)
    values (p_machine_id, 'volume_watch_changed', 'info',
            format('volume %s de %s: %s', v_drive, v_label,
                   case when coalesce(p_acompanhar, true) then 'acompanhando'
                        else 'fora do acompanhamento' end),
            jsonb_build_object('drive', v_drive, 'acompanhar', coalesce(p_acompanhar, true),
                               'antes', v_antes, 'sobram', v_sobra, 'por', auth.uid()));
  end if;

  return jsonb_build_object(
    'ok', true,
    'drive', v_drive,
    'acompanhar', coalesce(p_acompanhar, true),
    'volumes_acompanhados', v_sobra,
    'aviso', case when v_sobra = 0
                  then 'Nenhum volume acompanhado: esta máquina não terá número de disco no cartão nem alerta de disco.'
                  else null end);
end
$fn$;

-- `events.kind` é fechado por CHECK, e a lista é ESTENDIDA a partir da que está no
-- banco -- nunca reescrita de memória. A 0043 aprendeu isso derrubando oito kinds
-- que existiam de verdade.
do $do$
declare
  v_def  text;
  v_novo text;
begin
  select pg_get_constraintdef(c.oid) into v_def
  from pg_constraint c
  where c.conname = 'events_kind_ck' and c.conrelid = 'public.events'::regclass;

  if v_def is null then
    raise warning 'events_kind_ck não existe: nada a estender.';
    return;
  end if;

  if position('''volume_watch_changed''' in v_def) > 0 then
    raise notice 'events_kind_ck já aceita volume_watch_changed.';
    return;
  end if;

  v_novo := replace(v_def, 'ARRAY[', 'ARRAY[''volume_watch_changed''::text, ');

  if v_novo = v_def then
    raise warning 'events_kind_ck tem forma inesperada (%): não estendi.', v_def;
    return;
  end if;

  execute 'alter table public.events drop constraint events_kind_ck';
  execute 'alter table public.events add constraint events_kind_ck ' || v_novo;

  begin
    insert into public.events (kind, severity, message)
    values ('volume_watch_changed', 'info', 'prova da migração 0044');
    delete from public.events
    where kind = 'volume_watch_changed' and message = 'prova da migração 0044';
  exception when others then
    raise warning 'events_kind_ck estendida, mas a prova falhou (%).', sqlerrm;
  end;

  raise notice 'events_kind_ck estendida com volume_watch_changed.';
end
$do$;

revoke all on function public.definir_volume_acompanhado(uuid, text, boolean, text) from public;
grant execute on function public.definir_volume_acompanhado(uuid, text, boolean, text)
  to authenticated, service_role;

grant select on public.machine_volumes to authenticated, service_role;

comment on function public.definir_volume_acompanhado(uuid, text, boolean, text) is
  'Marca ou desmarca um volume de uma máquina. Só admin. Desmarcar remove o volume das métricas e dos alertas, sem escape.';

notify pgrst, 'reload schema';
