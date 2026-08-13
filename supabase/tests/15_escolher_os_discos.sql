-- =============================================================================
-- Teste 15 — escolher quais volumes acompanhar
-- =============================================================================
-- O que precisa ser verdade:
--
--   1. sem escolha nenhuma, os dois volumes contam (o pior manda no cartão)
--   2. desmarcar o D: faz o cartão passar a falar do C:
--   3. e a máquina reporta quantos volumes ficaram FORA, e quais
--   4. remarcar o D: devolve tudo ao estado anterior
--   5. desmarcar TODOS deixa o cartão sem número de disco -- e NÃO ressuscita
--      nenhum volume pelo escape da 0036
--   6. a gaveta mostra todos, inclusive o desmarcado, com `acompanhando`
--   7. a gaveta separa "pequeno" (heurística) de desmarcado (escolha)
--   8. volume que a máquina não reportou é recusado
--   9. não-admin não escolhe
--  10. a mudança deixa trilha em events
--  11. o alerta de disco respeita a escolha: um D: cheio e desmarcado não abre
--
-- O caso 5 é o coração. `disk_ignore_below_gb` (0036) tem escape de propósito --
-- quando não sobra volume grande, o maior pequeno volta, para uma máquina nunca
-- perder a leitura. Uma ESCOLHA não pode ter esse escape: se o operador desmarcou
-- tudo, o número tem de desaparecer. Se o escape valesse aqui, desmarcar o último
-- volume o traria de volta e a tela contradiria o que a pessoa acabou de clicar.
--
-- O caso 11 é o motivo prático de tudo isto existir: um D: de backup que vive em
-- 95% cheio mantinha a loja em ATENÇÃO para sempre.
--
-- ISOLAMENTO: transação com rollback.
-- =============================================================================

\set ON_ERROR_STOP on

begin;

do $$
declare
  v_brand uuid;
  v_site  uuid;
  v_maq   uuid;
  v_cod   text := 'ZZDISCO';
  v_admin uuid := '99999999-9999-4999-8999-999999999999';
  v_ze    uuid := 'aaaaaaaa-9999-4999-8999-999999999999';
  v_t     timestamptz;
  v_r     jsonb;
  v_item  jsonb;
  v_c     record;
  v_n     integer;
  v_txt   text;
begin
  delete from public.machines where label = 'PC-DOIS-DISCOS';
  delete from public.sites  where code = v_cod;
  delete from public.brands where code = v_cod;
  delete from public.user_roles where user_id in (v_admin, v_ze);

  insert into public.user_roles (user_id, role, note) values (v_admin, 'admin', 'teste 15');
  insert into public.user_roles (user_id, role, note) values (v_ze, 'viewer', 'teste 15');
  perform set_config('request.jwt.claim.sub', v_admin::text, true);

  insert into public.brands (code, name) values (v_cod, 'disco') returning id into v_brand;
  insert into public.sites (brand_id, code, name, timezone)
  values (v_brand, v_cod, 'Loja dos dois discos', 'America/Sao_Paulo')
  returning id into v_site;

  insert into public.machines (site_id, label, role_code, is_active)
  values (v_site, 'PC-DOIS-DISCOS', 'server', true)
  returning id into v_maq;

  v_t := date_trunc('second', now());
  update public.machines set last_seen_at = v_t, last_contact_at = v_t where id = v_maq;

  insert into public.metrics (machine_id, "time", ingested_at, agent_version, cpu_pct)
  values (v_maq, v_t, v_t, 'ps-1.8.0', 4);

  -- C: com 40% livre; D: (backup) com 4% livre, de propósito e para sempre;
  -- E: minúsculo, para o caso 7 poder distinguir "pequeno" de "desmarcado".
  insert into public.metrics_disks
    (machine_id, "time", drive, volume_label, filesystem, total_gb, free_gb, free_pct, media_type)
  values
    (v_maq, v_t, 'C:', 'Sistema', 'NTFS', 240, 96,  40, 'SSD'),
    (v_maq, v_t, 'D:', 'Backup',  'NTFS', 2000, 80,  4, 'HDD'),
    (v_maq, v_t, 'E:', 'Boot',    'FAT32', 1,   0.5, 50, 'SSD');

  -- =========================================================== 1
  select disk_worst_drive, disk_min_free_pct, disk_volumes_fora
  into v_c
  from public.machines_status where machine_id = v_maq;

  if v_c.disk_worst_drive <> 'D:' then
    raise exception 'FALHOU 1: o pior volume devia ser D:, veio %', v_c.disk_worst_drive;
  end if;
  if v_c.disk_min_free_pct <> 4 then
    raise exception 'FALHOU 1: livre devia ser 4%%, veio %', v_c.disk_min_free_pct;
  end if;
  if v_c.disk_volumes_fora <> 0 then
    raise exception 'FALHOU 1: nada foi desmarcado e ja ha % fora', v_c.disk_volumes_fora;
  end if;
  raise notice 'ok  1  sem escolha, o pior manda (% com %%% livre)',
    v_c.disk_worst_drive, v_c.disk_min_free_pct;

  -- =========================================================== 2 e 3
  v_r := public.definir_volume_acompanhado(v_maq, 'd:', false, 'backup, vive cheio');

  select disk_worst_drive, disk_min_free_pct, disk_volumes_fora, disk_drives_fora
  into v_c
  from public.machines_status where machine_id = v_maq;

  if v_c.disk_worst_drive <> 'C:' then
    raise exception 'FALHOU 2: com D: fora, o cartao devia falar de C:, veio %',
      v_c.disk_worst_drive;
  end if;
  if v_c.disk_min_free_pct <> 40 then
    raise exception 'FALHOU 2: livre devia ser 40%%, veio %', v_c.disk_min_free_pct;
  end if;
  raise notice 'ok  2  desmarcar D: passa o cartao para C: (%%% livre)', v_c.disk_min_free_pct;

  if v_c.disk_volumes_fora <> 1 or v_c.disk_drives_fora <> 'D:' then
    raise exception 'FALHOU 3: esperava 1 volume fora (D:), veio % (%)',
      v_c.disk_volumes_fora, v_c.disk_drives_fora;
  end if;
  -- Minuscula aceita na entrada, gravada em maiuscula: 'd:' e 'D:' sao o mesmo
  -- volume, e duas linhas para ele seriam duas escolhas conflitantes.
  if v_r->>'drive' <> 'D:' then
    raise exception 'FALHOU 3: o drive devia ser normalizado para D:, veio %', v_r->>'drive';
  end if;
  raise notice 'ok  3  a maquina diz o que ficou fora (% em %)',
    v_c.disk_volumes_fora, v_c.disk_drives_fora;

  -- =========================================================== 11
  -- O alerta de disco olha disk_min_free_pct. Com D: fora, 40% livre nao viola o
  -- limiar de 10% -- que era o alerta eterno desta maquina.
  perform public.avaliar_alertas();

  select count(*) into v_n
  from public.open_alerts a
  where a.machine_id = v_maq and a.rule_kind = 'disk_low';

  if v_n <> 0 then
    raise exception 'FALHOU 11: D: desmarcado e ainda abriu % alerta(s) de disco', v_n;
  end if;
  raise notice 'ok 11  o alerta de disco respeita a escolha';

  -- =========================================================== 4
  perform public.definir_volume_acompanhado(v_maq, 'D:', true);

  select disk_worst_drive, disk_volumes_fora into v_c
  from public.machines_status where machine_id = v_maq;

  if v_c.disk_worst_drive <> 'D:' or v_c.disk_volumes_fora <> 0 then
    raise exception 'FALHOU 4: remarcar devia voltar ao estado anterior (% / %)',
      v_c.disk_worst_drive, v_c.disk_volumes_fora;
  end if;
  raise notice 'ok  4  remarcar devolve o volume a conta';

  -- =========================================================== 5
  -- O caso que separa DECISAO de HEURISTICA. Com todos desmarcados, nao pode
  -- sobrar numero: se o escape da 0036 valesse aqui, o E: (minusculo) voltaria.
  perform public.definir_volume_acompanhado(v_maq, 'C:', false);
  perform public.definir_volume_acompanhado(v_maq, 'D:', false);
  v_r := public.definir_volume_acompanhado(v_maq, 'E:', false);

  select disk_worst_drive, disk_min_free_pct, disk_min_free_gb, disk_volumes_fora
  into v_c
  from public.machines_status where machine_id = v_maq;

  if v_c.disk_worst_drive is not null or v_c.disk_min_free_pct is not null then
    raise exception 'FALHOU 5: com tudo desmarcado ainda veio % (%%% livre) -- o escape da 0036 vazou',
      v_c.disk_worst_drive, v_c.disk_min_free_pct;
  end if;
  if v_c.disk_volumes_fora <> 3 then
    raise exception 'FALHOU 5: esperava 3 volumes fora, veio %', v_c.disk_volumes_fora;
  end if;
  if coalesce(v_r->>'aviso', '') = '' then
    raise exception 'FALHOU 5: desmarcar o ultimo volume tem de AVISAR, e veio sem aviso';
  end if;
  raise notice 'ok  5  tudo desmarcado: sem numero de disco, e com aviso';

  -- =========================================================== 6 e 7
  perform public.definir_volume_acompanhado(v_maq, 'C:', true);
  perform public.definir_volume_acompanhado(v_maq, 'D:', true);

  -- A gaveta devolve um OBJETO com medido_em e discos, nao um array: e a forma
  -- que a 0042 fixou e que o painel le. Este teste falhou na primeira versao
  -- justamente por eu ter mudado a forma sem querer.
  v_r := public.discos_da_maquina(v_maq);

  if v_r->>'medido_em' is null then
    raise exception 'FALHOU 6: a gaveta veio sem medido_em -- o painel mostra essa hora';
  end if;
  if jsonb_array_length(v_r->'discos') <> 3 then
    raise exception 'FALHOU 6: a gaveta devia mostrar os 3 volumes, veio %',
      jsonb_array_length(v_r->'discos');
  end if;

  select x into v_item from jsonb_array_elements(v_r->'discos') x where x->>'drive' = 'E:';
  if (v_item->>'acompanhando')::boolean is not false then
    raise exception 'FALHOU 6: E: esta desmarcado e a gaveta diz acompanhando=%',
      v_item->>'acompanhando';
  end if;
  raise notice 'ok  6  a gaveta mostra os 3, com o desmarcado visivel para remarcar';

  if (v_item->>'pequeno')::boolean is not true then
    raise exception 'FALHOU 7: E: tem 1 GB e devia vir pequeno=true';
  end if;
  select x into v_item from jsonb_array_elements(v_r->'discos') x where x->>'drive' = 'C:';
  if (v_item->>'pequeno')::boolean is not false then
    raise exception 'FALHOU 7: C: tem 240 GB e nao e pequeno';
  end if;
  -- Os nomes que o painel le, conferidos por nome: se um deles mudar, a gaveta
  -- fica vazia sem erro no console -- e foi o que quase aconteceu.
  if not (v_item ? 'free_gb' and v_item ? 'saude_ok' and v_item ? 'desgaste_pct'
          and v_item ? 'horas_ligado' and v_item ? 'etiqueta') then
    raise exception 'FALHOU 7: a gaveta perdeu um campo que o painel le (%)',
      (select string_agg(k, ', ') from jsonb_object_keys(v_item) k);
  end if;
  raise notice 'ok  7  a gaveta separa pequeno de desmarcado, e mantem os campos do painel';

  -- =========================================================== 8
  begin
    perform public.definir_volume_acompanhado(v_maq, 'X:', false);
    raise exception 'FALHOU 8: aceitou um volume que a maquina nao reportou';
  exception when sqlstate 'MON01' then
    raise notice 'ok  8  volume nao reportado e recusado';
  end;

  -- =========================================================== 9
  perform set_config('request.jwt.claim.sub', v_ze::text, true);
  begin
    perform public.definir_volume_acompanhado(v_maq, 'C:', false);
    raise exception 'FALHOU 9: viewer desmarcou um volume';
  exception when sqlstate 'MON09' then
    raise notice 'ok  9  nao-admin nao escolhe';
  end;
  perform set_config('request.jwt.claim.sub', v_admin::text, true);

  -- =========================================================== 10
  select count(*) into v_n from public.events
  where kind = 'volume_watch_changed' and machine_id = v_maq;

  if v_n < 1 then
    raise exception 'FALHOU 10: nenhuma trilha de mudanca de volume';
  end if;

  select payload->>'drive' into v_txt from public.events
  where kind = 'volume_watch_changed' and machine_id = v_maq
  order by id desc limit 1;
  if v_txt is null then
    raise exception 'FALHOU 10: a trilha nao diz qual volume';
  end if;
  raise notice 'ok 10  a mudanca deixa trilha (% evento(s))', v_n;

  raise notice '';
  raise notice 'Teste 15: a escolha de volumes vale, e nao tem escape.';
end $$;

rollback;
