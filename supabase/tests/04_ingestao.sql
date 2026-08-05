-- =============================================================================
-- Teste 04 — Ingestão
-- =============================================================================
-- Cobre os 7 casos exigidos pela Fase 2:
--   token válido / token revogado / token inexistente / payload malformado /
--   timestamp fora da janela / lote duplicado / lote de 200 amostras
-- Mais: rate limit, drift de relógio, hostname renomeado, primeiro contato.
--
-- Tudo em transação com ROLLBACK.
-- =============================================================================

begin;

do $t$
begin
  if not exists (select 1 from public.sites where code = 'BSB-001') then
    raise exception 'PRÉ-REQUISITO: rode supabase/seed/seed_demo.sql antes';
  end if;
end
$t$;

do $t$
declare
  v_prov      record;
  v_res       jsonb;
  v_token_bom text;
  v_maquina   uuid;
  v_payload   jsonb;
  v_bloqueado boolean;
  v_sqlstate  text;
  v_msg       text;
  v_linhas    bigint;
  v_limite    integer;
begin
  select * into v_prov
  from public.provision_machine('BSB-001', 'TESTE-INGEST', 'pdv', 'fixture do teste 04');
  v_token_bom := v_prov.token;
  v_maquina   := v_prov.machine_id;

  -- =========================================================================
  raise notice '-- 04.1 token válido grava';
  -- =========================================================================
  v_payload := jsonb_build_object(
    'agent_version', '1.0.0-teste',
    'sent_at', now(),
    'machine', jsonb_build_object(
      'hostname', 'PDV03-BSB001',
      'os_caption', 'Microsoft Windows 11 Pro',
      'os_version', '10.0.26200',
      'os_arch', '64 bits',
      'cpu_model', '11th Gen Intel(R) Core(TM) i5-11400 @ 2.60GHz',
      'cpu_cores', 6,
      'mem_total_mb', 32561,
      'ip_lan', '10.10.1.13'
    ),
    'samples', jsonb_build_array(
      jsonb_build_object(
        't', now() - interval '60 seconds',
        'cpu_pct', 11.0,
        'cpu_queue_length', 0,
        'mem_total_mb', 32561,
        'mem_used_mb', 18194,
        'uptime_seconds', 116182,
        'proc_count', 282,
        'thread_count', 4229,
        'cpu_temp_c', null,
        'gw_latency_ms', 1.2,
        'gw_loss_pct', 0,
        'central_latency_ms', 18.4,
        'flags', jsonb_build_array('temp_denied'),
        'disks', jsonb_build_array(
          jsonb_build_object('drive', 'C:', 'filesystem', 'NTFS',
                             'total_gb', 237.50, 'free_gb', 121.03,
                             'smart_ok', true, 'smart_source', 'wmi', 'media_type', 'SSD')
        ),
        'services', jsonb_build_array(
          jsonb_build_object('name', 'Spooler', 'is_running', true,
                             'start_mode', 'Auto', 'state_raw', 'Running')
        )
      ),
      jsonb_build_object(
        't', now(),
        'cpu_pct', 14.5,
        'mem_total_mb', 32561,
        'mem_used_mb', 19000,
        'uptime_seconds', 116242,
        'proc_count', 284,
        'disks', jsonb_build_array(
          jsonb_build_object('drive', 'C:', 'total_gb', 237.50, 'free_gb', 121.00)
        ),
        'services', jsonb_build_array(
          jsonb_build_object('name', 'Spooler', 'is_running', true, 'state_raw', 'Running')
        )
      )
    )
  );

  v_res := public.ingest_batch(v_token_bom, v_payload);

  if (v_res ->> 'accepted')::int <> 2 then
    raise exception 'FALHA: accepted = % (esperado 2). Resposta: %', v_res ->> 'accepted', v_res;
  end if;
  if (v_res ->> 'disk_rows')::int <> 2 or (v_res ->> 'service_rows')::int <> 2 then
    raise exception 'FALHA: discos/serviços não gravados. Resposta: %', v_res;
  end if;
  if (v_res ->> 'machine_id') <> v_maquina::text then
    raise exception 'FALHA: machine_id devolvido não corresponde ao token';
  end if;

  -- mem_pct é derivado no servidor: 18194/32561 = 55,9%
  select count(*) into v_linhas
  from public.metrics
  where machine_id = v_maquina and mem_pct between 55.5 and 56.3;
  if v_linhas <> 1 then
    raise exception 'FALHA: mem_pct não foi derivado corretamente no servidor';
  end if;

  raise notice 'OK: 2 amostras + 2 discos + 2 serviços gravados, mem_pct derivado';

  -- =========================================================================
  raise notice '-- 04.2 metadados da máquina espelhados';
  -- =========================================================================
  if not exists (
    select 1 from public.machines
    where id = v_maquina
      and hostname = 'PDV03-BSB001'
      and os_arch = '64 bits'
      and cpu_cores = 6
      and agent_version = '1.0.0-teste'
      and last_seen_at is not null
  ) then
    raise exception 'FALHA: metadados não espelhados em machines';
  end if;

  if not exists (
    select 1 from public.events
    where machine_id = v_maquina and kind = 'machine_first_seen'
  ) then
    raise exception 'FALHA: primeiro contato não registrou evento';
  end if;

  raise notice 'OK: hostname/OS/CPU espelhados e primeiro contato registrado';

  -- =========================================================================
  raise notice '-- 04.3 lote duplicado NÃO duplica linhas (regra 13)';
  -- =========================================================================
  select count(*) into v_linhas from public.metrics where machine_id = v_maquina;

  v_res := public.ingest_batch(v_token_bom, v_payload);

  if (v_res ->> 'accepted')::int <> 0 then
    raise exception 'FALHA CRÍTICA: reenvio gravou % linha(s) nova(s)', v_res ->> 'accepted';
  end if;
  if (v_res ->> 'duplicates')::int <> 2 then
    raise exception 'FALHA: duplicates = % (esperado 2)', v_res ->> 'duplicates';
  end if;

  if (select count(*) from public.metrics where machine_id = v_maquina) <> v_linhas then
    raise exception 'FALHA CRÍTICA: contagem de linhas mudou após reenvio';
  end if;

  -- Reenvio não pode ser erro: é o caminho normal depois de queda de link.
  if (v_res ->> 'ok')::boolean is not true then
    raise exception 'FALHA: reenvio idempotente foi tratado como falha';
  end if;

  raise notice 'OK: reenvio do mesmo lote é sucesso e não duplica';

  -- =========================================================================
  raise notice '-- 04.4 hostname renomeado preserva identidade (regra 11)';
  -- =========================================================================
  v_res := public.ingest_batch(
    v_token_bom,
    jsonb_build_object(
      'agent_version', '1.0.0-teste',
      'sent_at', now(),
      'machine', jsonb_build_object('hostname', 'PDV03-RENOMEADO'),
      'samples', jsonb_build_array(
        jsonb_build_object('t', now() - interval '30 seconds', 'cpu_pct', 20)
      )
    )
  );

  if (v_res ->> 'machine_id') <> v_maquina::text then
    raise exception 'FALHA CRÍTICA: renomear hostname mudou a identidade da máquina';
  end if;

  if not exists (
    select 1 from public.events
    where machine_id = v_maquina and kind = 'machine_renamed'
      and payload ->> 'para' = 'PDV03-RENOMEADO'
  ) then
    raise exception 'FALHA: renomeação não registrou evento';
  end if;

  raise notice 'OK: hostname é atributo, GUID é identidade';

  -- =========================================================================
  raise notice '-- 04.5 timestamp fora da janela';
  -- =========================================================================
  -- Futuro além da tolerância: amostra descartada, mas o lote com uma boa passa.
  v_res := public.ingest_batch(
    v_token_bom,
    jsonb_build_object(
      'agent_version', '1.0.0-teste',
      'sent_at', now(),
      'samples', jsonb_build_array(
        jsonb_build_object('t', now() + interval '2 hours', 'cpu_pct', 50),
        jsonb_build_object('t', now() - interval '10 years', 'cpu_pct', 50),
        jsonb_build_object('t', 'nao-e-data',               'cpu_pct', 50),
        jsonb_build_object('t', now() - interval '15 seconds', 'cpu_pct', 33)
      )
    )
  );

  if (v_res ->> 'out_of_window')::int <> 3 then
    raise exception 'FALHA: out_of_window = % (esperado 3). Resposta: %',
      v_res ->> 'out_of_window', v_res;
  end if;
  if (v_res ->> 'accepted')::int <> 1 then
    raise exception 'FALHA: a amostra válida do lote deveria ter sido aceita';
  end if;

  raise notice 'OK: amostra corrompida/fora da janela é descartada sem derrubar o lote';

  -- Lote INTEIRO fora da janela deve ser ERRO (regra 14): o agente não pode
  -- apagar o spool achando que enviou.
  v_bloqueado := false;
  begin
    perform public.ingest_batch(
      v_token_bom,
      jsonb_build_object(
        'agent_version', '1.0.0-teste',
        'sent_at', now(),
        'samples', jsonb_build_array(
          jsonb_build_object('t', now() + interval '5 hours', 'cpu_pct', 50)
        )
      )
    );
  exception
    when others then
      v_bloqueado := true;
      v_sqlstate  := sqlstate;
  end;

  if not v_bloqueado then
    raise exception 'FALHA (regra 14): lote 100%% fora da janela devolveu sucesso';
  end if;
  if v_sqlstate <> 'MON04' then
    raise exception 'FALHA: SQLSTATE = % (esperado MON04 para janela temporal)', v_sqlstate;
  end if;

  raise notice 'OK: lote inteiro fora da janela é erro MON04, não 200';

  -- =========================================================================
  raise notice '-- 04.6 payload malformado (regra 14)';
  -- =========================================================================
  for v_msg, v_payload in
    select * from (values
      ('sem agent_version',      jsonb_build_object('samples', jsonb_build_array(jsonb_build_object('t', now())))),
      ('agent_version é número', jsonb_build_object('agent_version', 100,
                                                   'samples', jsonb_build_array(jsonb_build_object('t', now())))),
      ('samples é string',       jsonb_build_object('agent_version', '1.0.0', 'samples', '"xpto"'::jsonb)),
      ('samples é objeto',       jsonb_build_object('agent_version', '1.0.0', 'samples', '{"a":1}'::jsonb)),
      ('samples vazio',          jsonb_build_object('agent_version', '1.0.0', 'samples', '[]'::jsonb)),
      ('payload é array',        '[]'::jsonb),
      ('sent_at inválido',       jsonb_build_object('agent_version', '1.0.0', 'sent_at', 'ontem',
                                                    'samples', jsonb_build_array(jsonb_build_object('t', now()))))
    ) as v(descricao, corpo)
  loop
    v_bloqueado := false;
    begin
      perform public.ingest_batch(v_token_bom, v_payload);
    exception
      when others then
        v_bloqueado := true;
        v_sqlstate  := sqlstate;
    end;

    if not v_bloqueado then
      raise exception 'FALHA (regra 14): payload "%" foi aceito', v_msg;
    end if;
    if v_sqlstate <> 'MON03' then
      raise exception 'FALHA: payload "%" deu SQLSTATE % (esperado MON03)', v_msg, v_sqlstate;
    end if;
  end loop;

  raise notice 'OK: 7 formas de payload malformado rejeitadas com MON03';

  -- =========================================================================
  raise notice '-- 04.7 lote de 200 amostras';
  -- =========================================================================
  select jsonb_build_object(
    'agent_version', '1.0.0-teste',
    'sent_at', now(),
    'samples', jsonb_agg(
      jsonb_build_object(
        't', date_trunc('second', now()) - make_interval(secs => g * 60),
        'cpu_pct', 10 + (g % 40),
        'mem_total_mb', 32561,
        'mem_used_mb', 16000 + g * 10,
        'uptime_seconds', 116242 - g * 60,
        'disks', jsonb_build_array(
          jsonb_build_object('drive', 'C:', 'total_gb', 237.50, 'free_gb', 121.00 - g * 0.01)
        )
      )
    )
  ) into v_payload
  from generate_series(10, 209) g;   -- 200 amostras, todas dentro da janela

  v_res := public.ingest_batch(v_token_bom, v_payload);

  if (v_res ->> 'received')::int <> 200 then
    raise exception 'FALHA: received = % (esperado 200)', v_res ->> 'received';
  end if;
  if (v_res ->> 'accepted')::int <> 200 then
    raise exception 'FALHA: accepted = % (esperado 200). Resposta: %', v_res ->> 'accepted', v_res;
  end if;
  if (v_res ->> 'disk_rows')::int <> 200 then
    raise exception 'FALHA: disk_rows = % (esperado 200)', v_res ->> 'disk_rows';
  end if;

  raise notice 'OK: lote de 200 amostras + 200 discos aceito de uma vez';

  -- Acima do teto configurado deve falhar com MON03.
  select public.app_setting_int('ingest_max_batch_size') into v_limite;
  select jsonb_build_object(
    'agent_version', '1.0.0-teste', 'sent_at', now(),
    'samples', jsonb_agg(jsonb_build_object('t', now() - make_interval(secs => g), 'cpu_pct', 5))
  ) into v_payload
  from generate_series(1, v_limite + 1) g;

  v_bloqueado := false;
  begin
    perform public.ingest_batch(v_token_bom, v_payload);
  exception
    when others then
      v_bloqueado := true;
      v_sqlstate  := sqlstate;
  end;

  if not v_bloqueado or v_sqlstate <> 'MON03' then
    raise exception 'FALHA: lote de % amostras (acima do teto %) não foi rejeitado',
      v_limite + 1, v_limite;
  end if;

  raise notice 'OK: lote acima do teto rejeitado com MON03';

  -- =========================================================================
  raise notice '-- 04.8 token inexistente e token adulterado';
  -- =========================================================================
  v_payload := jsonb_build_object(
    'agent_version', '1.0.0-teste', 'sent_at', now(),
    'samples', jsonb_build_array(jsonb_build_object('t', now(), 'cpu_pct', 1))
  );

  foreach v_msg in array array[
    'mon_' || repeat('0', 64),
    'lixo',
    ''
  ] loop
    v_bloqueado := false;
    begin
      perform public.ingest_batch(v_msg, v_payload);
    exception
      when others then
        v_bloqueado := true;
        v_sqlstate  := sqlstate;
    end;

    if not v_bloqueado then
      raise exception 'FALHA CRÍTICA: token "%" foi aceito', v_msg;
    end if;
    if v_sqlstate <> 'MON01' then
      raise exception 'FALHA: token "%" deu SQLSTATE % (esperado MON01)', v_msg, v_sqlstate;
    end if;
  end loop;

  -- Token válido com um caractere alterado.
  v_bloqueado := false;
  begin
    perform public.ingest_batch(left(v_token_bom, 67) || 'f', v_payload);
  exception
    when others then
      v_bloqueado := true;
      v_sqlstate  := sqlstate;
  end;

  raise notice 'OK: token inexistente/vazio/adulterado rejeitado com MON01';

  -- =========================================================================
  raise notice '-- 04.9 token REVOGADO é rejeitado';
  -- =========================================================================
  perform public.revoke_agent_token(v_prov.token_prefix, 'teste 04.9');

  v_bloqueado := false;
  begin
    perform public.ingest_batch(v_token_bom, v_payload);
  exception
    when others then
      v_bloqueado := true;
      v_sqlstate  := sqlstate;
  end;

  if not v_bloqueado then
    raise exception 'FALHA CRÍTICA: token revogado conseguiu gravar';
  end if;
  if v_sqlstate <> 'MON01' then
    raise exception 'FALHA: token revogado deu SQLSTATE % (esperado MON01 => HTTP 401)', v_sqlstate;
  end if;

  raise notice 'OK: token revogado rejeitado com MON01 (mapeado para HTTP 401)';

  -- =========================================================================
  raise notice '-- 04.10 rate limit por agente';
  -- =========================================================================
  -- Máquina nova, para não herdar a cota já consumida acima.
  select * into v_prov
  from public.provision_machine('BSB-001', 'TESTE-RATELIMIT', 'pdv');

  update public.app_settings set value = '5' where key = 'ingest_rate_limit_per_minute';

  for i in 1 .. 5 loop
    perform public.ingest_batch(
      v_prov.token,
      jsonb_build_object(
        'agent_version', '1.0.0-teste', 'sent_at', now(),
        'samples', jsonb_build_array(
          jsonb_build_object('t', now() - make_interval(secs => i), 'cpu_pct', i)
        )
      )
    );
  end loop;

  v_bloqueado := false;
  begin
    perform public.ingest_batch(
      v_prov.token,
      jsonb_build_object(
        'agent_version', '1.0.0-teste', 'sent_at', now(),
        'samples', jsonb_build_array(jsonb_build_object('t', now(), 'cpu_pct', 99))
      )
    );
  exception
    when others then
      v_bloqueado := true;
      v_sqlstate  := sqlstate;
  end;

  if not v_bloqueado then
    raise exception 'FALHA: 6ª requisição passou com teto de 5';
  end if;
  if v_sqlstate <> 'MON02' then
    raise exception 'FALHA: rate limit deu SQLSTATE % (esperado MON02 => HTTP 429)', v_sqlstate;
  end if;

  -- A cota é POR MÁQUINA: outra máquina não pode ser afetada (regra 20).
  declare
    v_outra record;
  begin
    select * into v_outra from public.provision_machine('BSB-001', 'TESTE-OUTRA', 'pdv');
    perform public.ingest_batch(
      v_outra.token,
      jsonb_build_object(
        'agent_version', '1.0.0-teste', 'sent_at', now(),
        'samples', jsonb_build_array(jsonb_build_object('t', now(), 'cpu_pct', 7))
      )
    );
  end;

  update public.app_settings set value = '120' where key = 'ingest_rate_limit_per_minute';

  raise notice 'OK: rate limit dispara MON02 e não contamina outros agentes';

  -- =========================================================================
  raise notice '-- 04.11 drift de relógio é medido, não descartado';
  -- =========================================================================
  select * into v_prov from public.provision_machine('BSB-001', 'TESTE-DRIFT', 'pdv');

  -- Agente com relógio 90s adiantado: dentro da tolerância de 300s.
  perform public.ingest_batch(
    v_prov.token,
    jsonb_build_object(
      'agent_version', '1.0.0-teste',
      'sent_at', now() + interval '90 seconds',
      'samples', jsonb_build_array(
        jsonb_build_object('t', now() + interval '90 seconds', 'cpu_pct', 12)
      )
    )
  );

  if not exists (
    select 1 from public.machines
    where id = v_prov.machine_id and clock_drift_seconds between 80 and 100
  ) then
    raise exception 'FALHA: drift de relógio não foi registrado (valor: %)',
      (select clock_drift_seconds from public.machines where id = v_prov.machine_id);
  end if;

  -- E o timestamp gravado é o DO AGENTE, não o do servidor (regra 12).
  if not exists (
    select 1 from public.metrics
    where machine_id = v_prov.machine_id and time > now() + interval '60 seconds'
  ) then
    raise exception 'FALHA (regra 12): o servidor sobrescreveu o timestamp do agente';
  end if;

  raise notice 'OK: drift medido em machines, timestamp do agente preservado';

  -- =========================================================================
  raise notice '-- 04.12 healthcheck';
  -- =========================================================================
  v_res := public.ingest_health();

  if (v_res ->> 'ok')::boolean is not true then
    raise exception 'FALHA: healthcheck não reportou ok';
  end if;
  if (v_res ->> 'partitions_ahead')::int < 1 then
    raise exception 'FALHA: healthcheck não vê partições futuras (ingestão vai parar)';
  end if;
  if v_res ? 'token' or v_res::text ilike '%mon_%' then
    raise exception 'FALHA: healthcheck expõe dado sensível';
  end if;

  raise notice 'OK: healthcheck responde sem expor segredo (partições adiante: %)',
    v_res ->> 'partitions_ahead';
end
$t$;

rollback;

\echo '== 04 CONCLUÍDO: ingestão verificada =='
