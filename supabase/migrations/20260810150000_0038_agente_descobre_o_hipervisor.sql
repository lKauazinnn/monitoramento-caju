-- =============================================================================
-- 0038 — O agente descobre o hipervisor sozinho
-- =============================================================================
-- Para ligar uma máquina virtual faltavam três coisas: QUAL hipervisor, QUAL VM
-- é aquela, e a CREDENCIAL da API. Eu ia pedir as três por mensagem.
--
-- Duas delas o Windows responde de dentro da própria VM:
--
--   Win32_ComputerSystem.Manufacturer/Model  -> o fabricante da placa-mãe
--     virtual se entrega: "QEMU" é KVM/Proxmox, "VMware, Inc." é ESXi,
--     "Microsoft Corporation" + "Virtual Machine" é Hyper-V, "innotek GmbH" é
--     VirtualBox, "Xen" é XCP-ng.
--
--   Win32_ComputerSystemProduct.UUID        -> o UUID de SMBIOS. No Proxmox é o
--     MESMO valor que a API devolve para a VM, então ele liga "esta máquina" ao
--     "vmid lá" sem ninguém digitar número de VM em formulário nenhum.
--
-- A terceira, a credencial, nenhum agente pode descobrir: ela vem de uma pessoa.
--
-- A CLASSIFICAÇÃO FICA AQUI, e o texto cru é guardado do lado. Se aparecer um
-- hipervisor que eu não previ, o dado está gravado para alguém ler — em vez de
-- ter sido jogado fora por não casar com a minha lista.
-- =============================================================================

alter table public.machines add column if not exists virt_fabricante text;
alter table public.machines add column if not exists virt_modelo     text;
alter table public.machines add column if not exists virt_uuid       text;
alter table public.machines add column if not exists virt_bios       text;

comment on column public.machines.virt_uuid is
  'UUID de SMBIOS. No Proxmox e o mesmo que a API devolve para a VM: e a ponte '
  'entre a maquina monitorada e o vmid do hipervisor.';

create or replace function public.hipervisor_de(
  p_fabricante text, p_modelo text, p_bios text
)
returns text
language sql
immutable
as $fn$
  select case
    when coalesce(p_fabricante, '') = '' and coalesce(p_modelo, '') = '' then null
    -- Ordem importa: Hyper-V se anuncia como "Microsoft Corporation", que também
    -- é o fabricante de PC físico com placa da Microsoft (Surface). O modelo
    -- "Virtual Machine" é o que decide.
    when p_modelo ~* 'virtual machine' and p_fabricante ~* 'microsoft' then 'hyper-v'
    when p_fabricante ~* 'vmware'          then 'vmware'
    when p_fabricante ~* 'innotek|oracle'  then 'virtualbox'
    when p_fabricante ~* 'xen'
      or p_modelo    ~* 'xen'              then 'xen'
    -- `kvm` no padrão, e não só `qemu|standard pc`. Meus oito casos de teste
    -- passaram e o único dado REAL da frota foi classificado como física: o
    -- CBO CAMINITO relata "Common KVM processor", que contém KVM e não contém
    -- nenhuma das duas palavras que eu tinha previsto. Teste escrito a partir do
    -- que eu imaginei, não do que estava no banco.
    when p_fabricante ~* 'qemu|kvm'
      or p_modelo    ~* 'qemu|kvm|standard pc' then 'kvm'
    when p_bios      ~* 'seabios|proxmox'  then 'kvm'
    when p_fabricante ~* 'parallels'       then 'parallels'
    -- Texto conhecido e nenhum casamento: e FISICA. Devolver null aqui faria
    -- "nao sei" e "e fisica" virarem a mesma coisa na tela.
    else 'fisica'
  end
$fn$;

comment on function public.hipervisor_de(text, text, text) is
  'Classifica o hipervisor pelo texto que o Windows relata. Devolve fisica quando '
  'ha texto e nenhum casamento, e null quando nao ha texto nenhum -- sao coisas '
  'diferentes e a tela precisa distinguir.';

revoke all on function public.hipervisor_de(text, text, text) from public;
grant execute on function public.hipervisor_de(text, text, text) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- A ingestão grava os campos novos
-- -----------------------------------------------------------------------------
-- AINDA NÃO. Gravar `virt_*` exige alterar o UPDATE de metadados dentro de
-- `register_metrics`, que é o ÚNICO caminho de escrita da telemetria — e é assim
-- que tem que continuar. Criar uma segunda função para gravar esses quatro
-- campos daria dois caminhos de escrita para divergirem.
--
-- Então esta migração entrega a estrutura (coluna, classificação, exposição) e a
-- 0039 entrega a gravação, junto com a recriação da função. Até lá as colunas
-- ficam nulas para máquina nova.
--
-- O que dá para saber JÁ, sem agente novo: o `cpu_model` de quem roda em KVM diz
-- "Common KVM processor". Isso identifica o hipervisor do CBO CAMINITO hoje. Não
-- resolve as outras três (CPU repassado do hospedeiro), e não dá o UUID — mas é
-- dado real que já estava no banco e ninguém tinha lido.
update public.machines m
   set virt_fabricante = coalesce(m.virt_fabricante, 'inferido do cpu_model'),
       virt_modelo     = coalesce(m.virt_modelo, m.cpu_model)
 where m.cpu_model ~* 'kvm|qemu|virtual'
   and m.virt_fabricante is null;

-- -----------------------------------------------------------------------------
-- No painel
-- -----------------------------------------------------------------------------
-- `mac_is_virtual` (0037) diz que WoL não alcança. Isto diz PARA ONDE ir em vez
-- disso: sem o hipervisor identificado, a recusa do WoL é um beco sem saída.
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
    ld.disk_volumes_ignorados
,
  -- 0038
  m.mac_is_virtual,
  m.virt_fabricante,
  m.virt_modelo,
  m.virt_uuid,
  public.hipervisor_de(m.virt_fabricante, m.virt_modelo, m.virt_bios) AS hipervisor
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
         count(*) FILTER (WHERE NOT v.conta)                           AS disk_volumes_ignorados
       FROM (
         SELECT d.drive, d.free_pct, d.free_gb, d.total_gb,
                (d.total_gb IS NULL
                 OR d.total_gb >= app_setting_int('disk_ignore_below_gb'::text)) AS conta,
                (CASE
                   WHEN d.total_gb IS NULL
                     OR d.total_gb >= app_setting_int('disk_ignore_below_gb'::text)
                   THEN coalesce(d.free_pct, 100)::numeric
                   ELSE 1e6 - coalesce(d.total_gb, 0)
                 END) AS ordem
         FROM metrics_disks d
         WHERE d.machine_id = m.id AND d."time" = lm."time"
       ) v) ld ON true
     LEFT JOIN LATERAL ( SELECT count(*) FILTER (WHERE NOT sv.is_running) AS services_down,
            array_agg(sv.service_name ORDER BY sv.service_name) FILTER (WHERE NOT sv.is_running) AS services_down_names
           FROM metrics_services sv
          WHERE sv.machine_id = m.id AND sv."time" = lm."time") lsv ON true;
