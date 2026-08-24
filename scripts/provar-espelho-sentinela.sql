-- =============================================================================
-- Prova do formato que vai para a API Sentinela do sistema principal
-- =============================================================================
-- Os dados locais estao velhos (o agente local para quando o Docker cai), entao
-- a consulta de mapeamento nunca seria exercitada com dado de verdade. Aqui eu
-- crio uma maquina completa -- metricas, dois discos e dois servicos -- e imprimo
-- o JSON exatamente como ele sairia no POST, para comparar campo por campo com o
-- exemplo documentado pela outra API.
--
-- Transacao com rollback: nao deixa nada na base.
-- =============================================================================
begin;

do $$
declare
  v_brand uuid;
  v_site  uuid;
  v_maq   uuid;
  v_t     timestamptz := date_trunc('second', now());
begin
  delete from public.machines where label = 'PDV-ESPELHO';
  delete from public.sites  where code = 'ZZESP';
  delete from public.brands where code = 'ZZESP';

  insert into public.brands (code, name) values ('ZZESP', 'espelho') returning id into v_brand;
  insert into public.sites (brand_id, code, name, timezone)
  values (v_brand, 'ZZESP', 'Loja do espelho', 'America/Sao_Paulo') returning id into v_site;

  insert into public.machines (site_id, label, hostname, role_code, is_active,
                               last_seen_at, last_contact_at, agent_version,
                               os_caption, ip_lan, mem_total_mb)
  values (v_site, 'PDV-ESPELHO', 'PDV-ESPELHO', 'pdv', true,
          v_t, v_t, 'ps-1.8.0', 'Windows 11 Pro', '10.0.12.21', 8192)
  returning id into v_maq;

  insert into public.metrics (machine_id, "time", ingested_at, agent_version,
                              cpu_pct, mem_total_mb, mem_used_mb,
                              uptime_seconds, gw_latency_ms)
  values (v_maq, v_t, v_t, 'ps-1.8.0', 37.5, 8192, 5588, 84213, 3.4);

  insert into public.metrics_disks
    (machine_id, "time", drive, volume_label, filesystem, total_gb, free_gb, free_pct, smart_ok, media_type)
  values
    (v_maq, v_t, 'C:', 'Sistema', 'NTFS', 476, 92,  19, true,  'SSD'),
    (v_maq, v_t, 'D:', 'Backup',  'NTFS', 1000, 40,  4, false, 'HDD');

  insert into public.metrics_services (machine_id, "time", service_name, is_running)
  values (v_maq, v_t, 'PDVService', true),
         (v_maq, v_t, 'Spooler',    false);

  raise notice 'maquina de prova criada';
end $$;

\echo ''
\echo '--- o corpo que iria no POST (todos os volumes) ---'
\pset tuples_only on
\pset format unaligned

select jsonb_pretty(jsonb_strip_nulls(jsonb_build_object(
  'versao_agente', regexp_replace(coalesce(a.agent_version, ''), '^ps-', ''),
  'host', jsonb_build_object(
    'hostname', coalesce(a.hostname, a.label),
    'ip_lan',   a.ip_lan,
    'so_nome',  a.os_caption
  ),
  'metricas', jsonb_build_object(
    'cpu_pct',             a.cpu_pct,
    'memoria_pct', coalesce(a.mem_pct,
      case when coalesce(a.mem_total_mb, 0) > 0
           then round(a.mem_used_mb::numeric * 100 / a.mem_total_mb, 1) end),
    'uptime_segundos',     a.uptime_seconds,
    'latencia_gateway_ms', a.gw_latency_ms
  ),
  'discos', (
    select jsonb_agg(jsonb_build_object(
             'unidade',  d.drive,
             'total_gb', round(d.total_gb)::int,
             'livre_gb', round(d.free_gb)::int,
             'smart_ok', d.smart_ok
           ) order by d.drive)
    from public.metrics_disks d
    left join public.machine_volumes mv
           on mv.machine_id = d.machine_id and mv.drive = upper(btrim(d.drive))
    where d.machine_id = a.machine_id and d."time" = a.last_sample_at
      and coalesce(mv.acompanhar, true)
  ),
  'servicos', (
    select jsonb_agg(jsonb_build_object(
             'servico', sv.service_name,
             'rodando', sv.is_running
           ) order by sv.service_name)
    from public.metrics_services sv
    where sv.machine_id = a.machine_id and sv."time" = a.last_sample_at
  )
)))
from public.machines_status a
where a.label = 'PDV-ESPELHO';

\echo ''
\echo '--- conferencia automatica ---'
\pset tuples_only off

do $$
declare
  v_maq uuid;
  v_c   jsonb;
begin
  select machine_id into v_maq from public.machines_status where label = 'PDV-ESPELHO';

  select jsonb_strip_nulls(jsonb_build_object(
    'versao_agente', regexp_replace(coalesce(a.agent_version, ''), '^ps-', ''),
    'host', jsonb_build_object('hostname', coalesce(a.hostname, a.label),
                               'ip_lan', a.ip_lan, 'so_nome', a.os_caption),
    'metricas', jsonb_build_object('cpu_pct', a.cpu_pct,
                                   'memoria_pct', coalesce(a.mem_pct,
                                     case when coalesce(a.mem_total_mb, 0) > 0
                                          then round(a.mem_used_mb::numeric * 100 / a.mem_total_mb, 1) end),
                                   'uptime_segundos', a.uptime_seconds,
                                   'latencia_gateway_ms', a.gw_latency_ms),
    'discos', (select jsonb_agg(jsonb_build_object('unidade', d.drive,
                 'total_gb', round(d.total_gb)::int, 'livre_gb', round(d.free_gb)::int,
                 'smart_ok', d.smart_ok) order by d.drive)
               from public.metrics_disks d
               left join public.machine_volumes mv on mv.machine_id = d.machine_id
                     and mv.drive = upper(btrim(d.drive))
               where d.machine_id = a.machine_id and d."time" = a.last_sample_at
                 and coalesce(mv.acompanhar, true)),
    'servicos', (select jsonb_agg(jsonb_build_object('servico', sv.service_name,
                   'rodando', sv.is_running) order by sv.service_name)
                 from public.metrics_services sv
                 where sv.machine_id = a.machine_id and sv."time" = a.last_sample_at)
  )) into v_c
  from public.machines_status a where a.machine_id = v_maq;

  -- 1. As cinco chaves de topo que a outra API documenta.
  if not (v_c ? 'versao_agente' and v_c ? 'host' and v_c ? 'metricas'
          and v_c ? 'discos' and v_c ? 'servicos') then
    raise exception 'FALHOU 1: falta chave de topo (%)',
      (select string_agg(k, ', ') from jsonb_object_keys(v_c) k);
  end if;
  raise notice 'ok  1  as cinco chaves de topo estao la';

  -- 2. A versao sai sem o prefixo 'ps-', no formato do exemplo deles.
  if v_c->>'versao_agente' <> '1.8.0' then
    raise exception 'FALHOU 2: versao_agente=% (esperava 1.8.0)', v_c->>'versao_agente';
  end if;
  raise notice 'ok  2  versao no formato deles (%)', v_c->>'versao_agente';

  -- 3. As metricas com os NOMES deles, e nao os nossos.
  if (v_c->'metricas'->>'memoria_pct') <> '68.2'
     or (v_c->'metricas'->>'uptime_segundos') <> '84213'
     or (v_c->'metricas'->>'latencia_gateway_ms') <> '3.4' then
    raise exception 'FALHOU 3: metricas mapeadas errado (%)', v_c->'metricas';
  end if;
  raise notice 'ok  3  metricas traduzidas (memoria_pct=%, uptime=%, latencia=%)',
    v_c->'metricas'->>'memoria_pct', v_c->'metricas'->>'uptime_segundos',
    v_c->'metricas'->>'latencia_gateway_ms';

  -- 4. Dois discos, com unidade/total_gb/livre_gb/smart_ok.
  if jsonb_array_length(v_c->'discos') <> 2 then
    raise exception 'FALHOU 4: esperava 2 discos, veio %', jsonb_array_length(v_c->'discos');
  end if;
  if (v_c->'discos'->0->>'unidade') <> 'C:'
     or (v_c->'discos'->0->>'total_gb') <> '476'
     or (v_c->'discos'->0->>'livre_gb') <> '92'
     or (v_c->'discos'->0->>'smart_ok') <> 'true' then
    raise exception 'FALHOU 4: disco mapeado errado (%)', v_c->'discos'->0;
  end if;
  raise notice 'ok  4  discos no formato deles (unidade/total_gb/livre_gb/smart_ok)';

  -- 5. Servicos com servico/rodando.
  if jsonb_array_length(v_c->'servicos') <> 2
     or (v_c->'servicos'->0->>'servico') <> 'PDVService'
     or (v_c->'servicos'->0->>'rodando') <> 'true' then
    raise exception 'FALHOU 5: servicos mapeados errado (%)', v_c->'servicos';
  end if;
  raise notice 'ok  5  servicos no formato deles (servico/rodando)';

  -- 6. O volume DESMARCADO aqui nao vai para la. E o ponto que evita
  --    reintroduzir no outro sistema o alerta que a gente acabou de calar.
  perform set_config('request.jwt.claim.sub', '99999999-9999-4999-8999-999999999999', true);
  insert into public.user_roles (user_id, role, note)
  values ('99999999-9999-4999-8999-999999999999', 'admin', 'prova espelho')
  on conflict (user_id) do update set role = 'admin';

  perform public.definir_volume_acompanhado(v_maq, 'D:', false);

  select (select jsonb_agg(d.drive order by d.drive)
          from public.metrics_disks d
          left join public.machine_volumes mv on mv.machine_id = d.machine_id
                and mv.drive = upper(btrim(d.drive))
          where d.machine_id = a.machine_id and d."time" = a.last_sample_at
            and coalesce(mv.acompanhar, true))
  into v_c
  from public.machines_status a where a.machine_id = v_maq;

  if v_c <> '["C:"]'::jsonb then
    raise exception 'FALHOU 6: com D: desmarcado esperava so C:, veio %', v_c;
  end if;
  raise notice 'ok  6  volume desmarcado aqui NAO e enviado para la';

  raise notice '';
  raise notice 'O corpo esta no formato da API Sentinela.';
end $$;

rollback;
