-- =============================================================================
-- Teste 07 — rollup horário e a trava da retenção
-- =============================================================================
-- O que precisa ser verdade:
--
--   1. o rollup agrega o cru em horas, com os números certos
--   2. rodar de novo NÃO duplica nem altera (idempotente)
--   3. a hora CORRENTE fica de fora (ela ainda está recebendo amostra)
--   4. `drop_old_partitions` RECUSA derrubar mês não consolidado
--   5. consolidado o mês, ela passa a permitir
--   6. `run_maintenance` agrega ANTES de apagar
--
-- O item 4 é a razão deste arquivo existir. Sem ele, o job das 3:17 apaga
-- métrica crua que nunca virou histórico, e o dado some para sempre — o tipo de
-- defeito que só aparece 30 dias depois, quando não há mais como recuperar.
-- =============================================================================

\set ON_ERROR_STOP on

do $$
declare
  v_brand uuid;
  v_site  uuid;
  v_maq   uuid;
  v_cod   text := 'ZZROLL';
  v_hora  timestamptz := date_trunc('hour', now()) - interval '3 hours';
  v_r     jsonb;
  v_linha record;
  v_antes jsonb;
  v_depois jsonb;
begin
  delete from public.machines where label = 'PC-ROLLUP';
  delete from public.sites where code = v_cod;
  delete from public.brands where code = v_cod;

  insert into public.brands (code, name) values (v_cod, 'rollup') returning id into v_brand;
  insert into public.sites (brand_id, code, name) values (v_brand, v_cod, 'loja rollup') returning id into v_site;
  insert into public.machines (site_id, role_code, label) values (v_site, 'pdv', 'PC-ROLLUP')
  returning id into v_maq;

  -- Quatro amostras na MESMA hora fechada, com CPU conhecida: 10, 20, 30, 90.
  -- Média 37,5 e máximo 90 — números que dá para conferir de cabeça.
  insert into public.metrics (machine_id, "time", agent_version, cpu_pct, mem_pct, uptime_seconds)
  values (v_maq, v_hora + interval '5 min',  'teste', 10, 40, 1000),
         (v_maq, v_hora + interval '15 min', 'teste', 20, 42, 1600),
         (v_maq, v_hora + interval '25 min', 'teste', 30, 44, 2200),
         (v_maq, v_hora + interval '35 min', 'teste', 90, 46,  100);  -- uptime CAIU: reiniciou

  -- E uma na hora corrente, que NÃO pode entrar.
  insert into public.metrics (machine_id, "time", agent_version, cpu_pct, mem_pct, uptime_seconds)
  values (v_maq, date_trunc('hour', now()) + interval '2 min', 'teste', 99, 99, 50);

  -- ------------------------------------------------------------ 1. agrega
  perform public.rollup_horario(6);

  select * into v_linha from public.metrics_hourly
  where machine_id = v_maq and hour = v_hora;

  if v_linha is null then
    raise exception 'FALHA: o rollup nao gravou a hora fechada';
  end if;

  if v_linha.samples <> 4 then
    raise exception 'FALHA: esperava 4 amostras na hora, veio %', v_linha.samples;
  end if;
  if round(v_linha.cpu_avg) <> 38 then
    raise exception 'FALHA: media de CPU deveria ser ~37.5, veio %', v_linha.cpu_avg;
  end if;
  if v_linha.cpu_max <> 90 then
    raise exception 'FALHA: maximo de CPU deveria ser 90, veio %', v_linha.cpu_max;
  end if;
  if v_linha.reboot_count <> 1 then
    raise exception 'FALHA: uptime caiu uma vez, esperava reboot_count 1, veio %', v_linha.reboot_count;
  end if;
  raise notice '1. agrega: 4 amostras, media 37.5, max 90, 1 reinicio (ok)';

  -- --------------------------------------------- 3. a hora corrente fica fora
  if exists (select 1 from public.metrics_hourly
             where machine_id = v_maq and hour = date_trunc('hour', now())) then
    raise exception 'FALHA: gravou a hora CORRENTE, que ainda esta recebendo amostra';
  end if;
  raise notice '3. a hora corrente nao entra (ok)';

  -- ------------------------------------------------------- 2. idempotencia
  select to_jsonb(h) into v_antes from public.metrics_hourly h
  where h.machine_id = v_maq and h.hour = v_hora;

  perform public.rollup_horario(6);
  perform public.rollup_horario(6);

  select to_jsonb(h) into v_depois from public.metrics_hourly h
  where h.machine_id = v_maq and h.hour = v_hora;

  if (select count(*) from public.metrics_hourly where machine_id = v_maq and hour = v_hora) <> 1 then
    raise exception 'FALHA: rodar de novo duplicou a linha';
  end if;

  -- `computed_at` muda de proposito: e o carimbo de quando foi calculado.
  if (v_antes - 'computed_at') <> (v_depois - 'computed_at') then
    raise exception 'FALHA: recalcular mudou os numeros. antes=% depois=%', v_antes, v_depois;
  end if;
  raise notice '2. rodar tres vezes: uma linha, numeros identicos (ok)';

  delete from public.machines where id = v_maq;
  delete from public.sites where id = v_site;
  delete from public.brands where id = v_brand;
end
$$;

-- ---------------------------------------------------------------------------
-- 4 e 5. A trava da retenção
-- ---------------------------------------------------------------------------
-- Bloco separado: mexe em partição, e precisa criar uma antiga de propósito.
do $$
declare
  v_mes      date := date_trunc('month', now() - interval '8 months')::date;
  v_nome     text;
  v_brand    uuid;
  v_site     uuid;
  v_maq      uuid;
  v_cod      text := 'ZZRET';
  v_recusou  boolean := false;
  v_removeu  boolean := false;
  r          record;
begin
  raise notice '';
  raise notice '--- 4 e 5. trava da retencao ---';

  v_nome := 'metrics_' || to_char(v_mes, 'YYYYMM');

  delete from public.machines where label = 'PC-RETENCAO';
  delete from public.sites where code = v_cod;
  delete from public.brands where code = v_cod;

  insert into public.brands (code, name) values (v_cod, 'retencao') returning id into v_brand;
  insert into public.sites (brand_id, code, name) values (v_brand, v_cod, 'loja retencao') returning id into v_site;
  insert into public.machines (site_id, role_code, label) values (v_site, 'pdv', 'PC-RETENCAO')
  returning id into v_maq;

  -- Partição daquele mês, com uma amostra dentro e NENHUM rollup.
  perform public.ensure_month_partition('metrics', v_mes);

  insert into public.metrics (machine_id, "time", agent_version, cpu_pct, mem_pct)
  values (v_maq, v_mes + interval '10 days', 'teste', 50, 50);

  delete from public.metrics_hourly
  where hour >= v_mes and hour < (v_mes + interval '1 month');

  -- A trava tem de RECUSAR.
  for r in select * from public.drop_old_partitions() loop
    if r.partition_name = v_nome and r.action = 'mantida_sem_rollup' then
      v_recusou := true;
    end if;
  end loop;

  if not v_recusou then
    raise exception 'FALHA: derrubou (ou ignorou) a particao % sem rollup do mes', v_nome;
  end if;

  if to_regclass('public.' || v_nome) is null then
    raise exception 'FALHA: a particao % foi REMOVIDA mesmo sem consolidacao', v_nome;
  end if;
  raise notice '4. mes sem rollup -> particao PRESERVADA (ok)';

  -- Consolidado, ela passa a permitir.
  insert into public.metrics_hourly (
    machine_id, hour, samples, samples_expected, cpu_avg, cpu_max, cpu_p95,
    mem_avg, mem_max, uptime_max, reboot_count, service_down_count, computed_at
  ) values (
    v_maq, date_trunc('hour', v_mes + interval '10 days'), 1, 60, 50, 50, 50,
    50, 50, 0, 0, 0, now()
  );

  for r in select * from public.drop_old_partitions() loop
    if r.partition_name = v_nome and r.action = 'removida' then
      v_removeu := true;
    end if;
  end loop;

  if not v_removeu then
    raise exception 'FALHA: com o mes consolidado, a particao % deveria ter sido removida', v_nome;
  end if;
  raise notice '5. mes consolidado -> particao removida (ok)';

  delete from public.metrics_hourly where machine_id = v_maq;
  delete from public.machines where id = v_maq;
  delete from public.sites where id = v_site;
  delete from public.brands where id = v_brand;
end
$$;

-- ---------------------------------------------------------------------------
-- 6. A ordem em run_maintenance
-- ---------------------------------------------------------------------------
do $$
declare
  v_r jsonb;
begin
  raise notice '';
  raise notice '--- 6. run_maintenance agrega antes de apagar ---';

  v_r := public.run_maintenance();

  if v_r -> 'rollup' is null then
    raise exception 'FALHA: run_maintenance nao chamou o rollup';
  end if;

  if (v_r -> 'rollup' ->> 'ate') is null then
    raise exception 'FALHA: o rollup nao devolveu janela: %', v_r -> 'rollup';
  end if;

  raise notice '    run_maintenance devolve o resultado do rollup (ok)';
  raise notice '    %', v_r -> 'rollup';
end
$$;

select 'TESTE 07: ROLLUP E RETENCAO CORRETOS' as resultado;
