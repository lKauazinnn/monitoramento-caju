-- =============================================================================
-- 0042 — Setores realocados e pendentes na gaveta
-- =============================================================================
-- O agente ps-1.8.0 passou a ler SMART CRU (`MSStorageDriver_FailurePredictData`),
-- o mesmo buffer de 512 bytes que o CrystalDiskInfo obtem mandando comando ATA ao
-- disco. Dali saem os dois atributos que respondem "quando trocar":
--
--   ID 5   setores realocados -> QUALQUER valor acima de zero e disco morrendo
--   ID 197 setores pendentes  -> pior que o 5: setor falhando AGORA
--
-- As colunas `smart_reallocated` e `smart_pending` existem em `metrics_disks`
-- desde a 0004 e a ingestao sempre as gravou — estavam nulas porque o agente nunca
-- as preencheu. Mesma historia de `smart_wear_pct`: nao precisa tocar em
-- `register_metrics`.
--
-- Aqui so a RPC da gaveta passa a devolve-las.
-- =============================================================================

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
               -- 0042: os dois que decidem troca de peca.
               'realocados', d.smart_reallocated,
               'pendentes', d.smart_pending,
               'pequeno', (d.total_gb is not null
                           and d.total_gb < public.app_setting_int('disk_ignore_below_gb'))
             ) order by d.total_gb desc nulls last)
      from public.metrics_disks d
      where d.machine_id = p_machine_id and d."time" = v_t), '[]'::jsonb));
end
$fn$;

revoke all on function public.discos_da_maquina(uuid) from public;
grant execute on function public.discos_da_maquina(uuid) to authenticated, service_role;
