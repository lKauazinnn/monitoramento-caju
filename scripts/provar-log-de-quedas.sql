-- =============================================================================
-- Prova do ramo de quedas FECHADAS do relatorio
-- =============================================================================
-- Os dados locais nao tem buraco nenhum (maior intervalo: 72 s), entao o ramo
-- principal do relatorio nunca foi exercitado. Aqui eu crio um buraco de 90 min
-- de proposito e confiro que o relatorio o encontra, com a hora certa e repartido
-- entre as horas que ele atravessa.
--
-- Tudo em transacao com rollback: nao deixa maquina de teste na base.
--
-- COMO RODAR (contra a base LOCAL, nunca producao -- ele escreve):
--   node -e "..." para extrair o SQL do relatorio de quedas-de-hoje.ps1 em
--   /tmp/q.sql, ou simplesmente rode o relatorio uma vez com -Vigiar:false para
--   ele deixar o arquivo. Depois:
--     docker cp scripts/provar-log-de-quedas.sql monitor-db:/tmp/prova.sql
--     docker exec -e PGPASSWORD=<senha local> monitor-db --       psql -U postgres -d postgres -v padrao='%BURACO%' -v dias=1 -f /tmp/prova.sql
--
-- Por que existe: os dados locais nao tem buraco nenhum (maior intervalo 72 s),
-- entao o ramo principal do relatorio passaria por 'testado' sem nunca ter sido
-- executado. Foi assim que dois defeitos serios chegaram longe -- a coluna errada
-- de events e a queda em curso invisivel quando a maquina caiu antes da janela.
-- =============================================================================
begin;

create temporary table _alvo (id uuid);

do $$
declare
  v_brand uuid;
  v_site  uuid;
  v_maq   uuid;
  v_base  timestamptz;
  v_t     timestamptz;
begin
  insert into public.brands (code, name) values ('ZZQUEDA', 'queda') returning id into v_brand;
  insert into public.sites (brand_id, code, name, timezone)
  values (v_brand, 'ZZQUEDA', 'Loja da queda', 'America/Sao_Paulo') returning id into v_site;
  insert into public.machines (site_id, label, role_code, is_active)
  values (v_site, 'PC-BURACO', 'server', true) returning id into v_maq;

  insert into _alvo values (v_maq);

  -- Hoje as 08:00 no fuso de Brasilia, para o relatorio de 1 dia alcancar.
  v_base := ((now() at time zone 'America/Sao_Paulo')::date + interval '8 hours')
            at time zone 'America/Sao_Paulo';

  -- Amostras de 60 em 60 s das 08:00 as 09:00.
  v_t := v_base;
  while v_t <= v_base + interval '1 hour' loop
    insert into public.metrics (machine_id, "time", ingested_at, agent_version, cpu_pct)
    values (v_maq, v_t, v_t, 'ps-1.8.0', 5);
    v_t := v_t + interval '60 seconds';
  end loop;

  -- BURACO de 90 min: nada entre 09:01 e 10:31.
  -- Depois, amostras de 60 em 60 s das 10:31 as 11:00.
  v_t := v_base + interval '2 hours 31 minutes';
  while v_t <= v_base + interval '3 hours' loop
    insert into public.metrics (machine_id, "time", ingested_at, agent_version, cpu_pct)
    values (v_maq, v_t, v_t, 'ps-1.8.0', 5);
    v_t := v_t + interval '60 seconds';
  end loop;

  -- A maquina "esta viva agora" para o ramo EM CURSO nao disparar e poluir a
  -- prova: quero medir so a queda fechada.
  update public.machines
  set last_seen_at = now(), last_contact_at = now()
  where id = v_maq;

  raise notice 'preparado: buraco de 90 min a partir das 09:01';
end $$;

\echo ''
\echo '--- o relatorio, rodando sobre esses dados ---'
\i /tmp/q.sql

\echo ''
\echo '--- conferencia automatica ---'
do $$
declare
  v_maq   uuid;
  v_lim   integer;
  v_ini   timestamptz;
  v_n     integer;
  v_seg   integer;
  v_hora  text;
  v_fora  integer;
begin
  select id into v_maq from _alvo;
  select coalesce((select value::integer from public.app_settings
                   where key = 'offline_timeout_seconds'), 180) into v_lim;
  v_ini := ((now() at time zone 'America/Sao_Paulo')::date) at time zone 'America/Sao_Paulo';

  -- 1. Uma queda fechada, de 90 min.
  with am as (
    select m.ingested_at t, lag(m.ingested_at) over (order by m.ingested_at) ant
    from public.metrics m
    where m.machine_id = v_maq and m.ingested_at >= v_ini
  )
  select count(*), max(extract(epoch from t - ant))::int into v_n, v_seg
  from am where ant is not null and t - ant > make_interval(secs => v_lim);

  if v_n <> 1 then
    raise exception 'FALHOU 1: esperava 1 queda fechada, achei %', v_n;
  end if;
  -- 5460 e nao 5400: o laco insere a amostra das 09:00:00 inclusive, entao o
  -- buraco vai das 09:00 as 10:31 -- 91 min. O relatorio disse 1h31 e estava
  -- certo; era a minha conta aqui que estava errada.
  if v_seg <> 5460 then
    raise exception 'FALHOU 1: esperava 5460 s (91 min), achei %', v_seg;
  end if;
  raise notice 'ok  1  uma queda fechada de % min', v_seg / 60;

  -- 2. A hora das 09h leva 60 min de fora, e a das 10h leva 31.
  --    (o buraco vai das 09:00 as 10:31)
  for v_hora, v_fora in
    select to_char(h at time zone 'America/Sao_Paulo', 'HH24'),
           coalesce((select sum(extract(epoch from
                       least(q.voltou, h + interval '1 hour') - greatest(q.calou, h)))
                     from (
                       select ant as calou, t as voltou from (
                         select m.ingested_at t, lag(m.ingested_at) over (order by m.ingested_at) ant
                         from public.metrics m
                         where m.machine_id = v_maq and m.ingested_at >= v_ini
                       ) x where ant is not null and t - ant > make_interval(secs => v_lim)
                     ) q
                     where q.calou < h + interval '1 hour' and q.voltou > h), 0)::int / 60
    from generate_series(v_ini, v_ini + interval '23 hours', interval '1 hour') h
    where to_char(h at time zone 'America/Sao_Paulo', 'HH24') in ('09', '10')
  loop
    if v_hora = '09' and v_fora <> 60 then
      raise exception 'FALHOU 2: as 09h esperava 60 min de fora, achei %', v_fora;
    end if;
    if v_hora = '10' and v_fora <> 31 then
      raise exception 'FALHOU 2: as 10h esperava 31 min de fora, achei %', v_fora;
    end if;
    raise notice 'ok  2  %h leva % min de fora', v_hora, v_fora;
  end loop;

  raise notice '';
  raise notice 'O ramo de quedas fechadas e a reparticao por hora estao certos.';
end $$;

rollback;
