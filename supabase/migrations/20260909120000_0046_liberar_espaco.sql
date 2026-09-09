-- =============================================================================
-- 0046 — Liberar espaço: o banco estourou a cota de tamanho
-- =============================================================================
-- Sintoma: HTTP 402 `exceed_db_size_quota`. A API do projeto foi restringida, os
-- agentes pararam de conseguir gravar e 41 de 45 máquinas apareceram offline
-- estando ligadas. O painel também não carrega.
--
-- Causa: volume de dado bruto. 45 máquinas reportando a cada 60 s alimentam três
-- tabelas por ciclo -- `metrics`, `metrics_disks` e `metrics_services` --, e a
-- retenção estava em 30 dias com partição MENSAL, o que na prática guardava dois
-- a três meses.
--
-- POR QUE ISTO LIBERA DE VERDADE
--
-- `drop_old_partitions` calcula o corte com `date_trunc('month', now() -
-- retenção)`: ele remove a PARTIÇÃO inteira, e só de meses anteriores. Rodando
-- isto em setembro com retenção de 7 dias, o corte cai em 01/09 e as partições de
-- julho e agosto saem inteiras.
--
-- Derrubar partição é `drop table`: o arquivo sai do disco na hora. É diferente de
-- `delete`, que marca linha como morta e só devolve espaço ao sistema com
-- `vacuum full` -- que precisa de lock exclusivo e do DOBRO do espaço livre, ou
-- seja, exatamente o que não existe num banco que estourou a cota.
--
-- O QUE NÃO SE PERDE, e não é promessa minha
--
-- O rollup por hora roda de hora em hora (`rollup-horario`, migração 0022) e é
-- guardado 400 dias. E `drop_old_partitions` tem uma trava: ele RECUSA derrubar a
-- partição de um mês que não foi consolidado no rollup, e registra o motivo em
-- `events`. Ou seja, esta migração não consegue apagar histórico não agregado nem
-- se alguém quisesse.
--
-- O que sai: o minuto a minuto de julho e agosto.
-- O que fica: a média por hora de cada máquina, por 400 dias -- que é a fonte do
-- relatório mensal.
--
-- A RETENÇÃO FICA CURTA PARA SEMPRE, e isso é a parte estrutural: 7 dias de bruto
-- com 400 de agregado é a arquitetura pretendida desde a 0007. Trinta dias de
-- bruto era o que empurrava o banco para a cota a cada dois meses.
--
-- O QUE ESTA MIGRAÇÃO NÃO RESOLVE
--
-- O volume gravado por ciclo. Isto libera espaço uma vez e mantém a faxina em dia,
-- mas com 45 máquinas a cada 60 s o bruto volta a crescer no mesmo ritmo. A
-- correção estrutural é espaçar a coleta (`intervalSeconds` no agente, 60 -> 180)
-- e gravar disco/serviço a cada N ciclos em vez de todos -- e as duas exigem tocar
-- no agente, não no banco.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Antes: o retrato, para o depois ter com o que ser comparado
-- -----------------------------------------------------------------------------
do $do$
declare
  v_antes    bigint := pg_database_size(current_database());
  v_retencao text;
  v_corte    date   := date_trunc('month', now() - interval '7 days')::date;
  r          record;
begin
  select value into v_retencao from public.app_settings
  where key = 'metrics_retention_days';

  raise notice '';
  raise notice '=== ANTES ===';
  raise notice 'banco: %', pg_size_pretty(v_antes);
  raise notice 'retencao do bruto: % dia(s)', coalesce(v_retencao, '(nao definida)');
  raise notice 'corte que sera aplicado: particao de mes anterior a %', v_corte;
  raise notice '';

  -- O rótulo sai da MESMA regra da função, e não de comparação de texto.
  --
  -- A primeira versão comparava o nome com to_char(now(), 'YYYY_MM'), mas a
  -- partição se chama metrics_202609 -- sem o underscore. A comparação nunca
  -- casava, e a saída marcava "sai" na partição do mês CORRENTE e nas FUTURAS. Um
  -- relatório que promete apagar o mês corrente assusta em vez de informar, e eu
  -- vi isso na tela local antes de mandar para produção.
  for r in
    select c.relname as particao,
           pg_total_relation_size(c.oid) as bytes,
           -- O mês da partição, dos seis dígitos finais do nome.
           to_date(substring(c.relname from '[0-9]{6}$'), 'YYYYMM') as mes
    from pg_class c
    join pg_inherits i on i.inhrelid = c.oid
    join pg_class pai on pai.oid = i.inhparent
    where pai.relname in ('metrics', 'metrics_disks', 'metrics_services')
      and c.relname ~ '[0-9]{6}$'
    order by pg_total_relation_size(c.oid) desc
  loop
    raise notice '  %  %  %', rpad(r.particao, 34), lpad(pg_size_pretty(r.bytes), 10),
      case
        when r.mes < v_corte then 'SAI'
        when r.mes = date_trunc('month', now())::date then 'mes corrente (fica)'
        else 'futura (fica)'
      end;
  end loop;

  -- Guardado para o bloco 3 comparar. `set_config` com is_local = false sobrevive
  -- aos blocos seguintes na MESMA sessão, que é o que o psql dá.
  perform set_config('meu.tamanho_antes', v_antes::text, false);
end
$do$;

-- -----------------------------------------------------------------------------
-- 2. A faxina
-- -----------------------------------------------------------------------------
-- 7 dias, que é o mínimo que `drop_old_partitions` aceita -- ela levanta exceção
-- abaixo disso, de propósito. Não é um número escolhido por otimismo: com partição
-- mensal, qualquer valor entre 1 e 30 produz o mesmo corte dentro do mês corrente,
-- e 7 é o que também mantém a faxina agressiva nos meses seguintes.
update public.app_settings
set value = '7'
where key = 'metrics_retention_days';

-- Não confio no update em silêncio: se a chave não existir, a linha abaixo grita.
do $do$
begin
  if not exists (select 1 from public.app_settings
                 where key = 'metrics_retention_days' and value = '7') then
    raise exception 'metrics_retention_days nao ficou em 7 -- a chave existe em app_settings?';
  end if;
  raise notice 'retencao do bruto: 7 dia(s)';
end
$do$;

-- `run_maintenance()` faz os três: cria partição futura, derruba as expiradas
-- (com a trava do rollup) e expurga os agregados velhos.
do $do$
declare
  v_r jsonb;
begin
  v_r := public.run_maintenance();
  raise notice '';
  raise notice '=== MANUTENCAO ===';
  raise notice 'criadas: %  |  derrubadas: %  |  expurgado: %',
    v_r->>'partitions_created', v_r->>'partitions_dropped', v_r->'purged';

  if (v_r->>'partitions_dropped')::int = 0 then
    raise warning '%',
      'NENHUMA particao foi derrubada. Duas explicacoes possiveis: (a) nao ha mes '
      'anterior -- todo o volume esta no mes corrente, e ai a saida e espacar a '
      'coleta ou aumentar o plano; (b) um mes nao foi consolidado no rollup e a '
      'trava o protegeu -- procure em events pelas mensagens de particao NAO '
      'removida.';
  end if;
end
$do$;

-- -----------------------------------------------------------------------------
-- 3. Depois: quanto saiu
-- -----------------------------------------------------------------------------
do $do$
declare
  v_antes  bigint := coalesce(nullif(current_setting('meu.tamanho_antes', true), ''), '0')::bigint;
  v_depois bigint := pg_database_size(current_database());
begin
  raise notice '';
  raise notice '=== DEPOIS ===';
  raise notice 'banco: %  (antes: %)', pg_size_pretty(v_depois), pg_size_pretty(v_antes);

  if v_antes > v_depois then
    raise notice 'liberado: %', pg_size_pretty(v_antes - v_depois);
  else
    raise notice 'sem reducao mensuravel agora.';
  end if;

  raise notice '';
  raise notice 'O QUE FALTA, e nao e opcional se voce nao quer repetir isto:';
  raise notice '  1. espacar a coleta do agente: intervalSeconds de 60 para 180';
  raise notice '     (corta dois tercos do volume; a deteccao de offline nao muda,';
  raise notice '      porque quem decide e este banco, pelo relogio do servidor)';
  raise notice '  2. gravar disco e servico a cada N ciclos, nao a cada ciclo:';
  raise notice '     metrics_services grava uma linha POR SERVICO por ciclo --';
  raise notice '     tres servicos x 45 maquinas x 1440 ciclos = ~194 mil linhas/dia';
  raise notice '     para dizer que o Spooler continua rodando';
  raise notice '';
  raise notice 'A API destrava quando o Supabase reavaliar o tamanho, e os agentes';
  raise notice 'voltam na proxima amostra. Nenhum PC precisa ser tocado.';
end
$do$;

-- Sem `vacuum full` aqui, de propósito, e o motivo importa: ele precisaria de lock
-- exclusivo e de espaço livre equivalente à tabela inteira -- num banco que
-- estourou a cota, é a última coisa que se deve tentar. O que libera espaço nesta
-- migração é o `drop table` das partições, que devolve o arquivo ao sistema na
-- hora e sem lock demorado.
--
-- O `delete` que o `purge_aggregates` faz em `metrics_hourly` e `events` deixa
-- espaço reutilizável DENTRO do arquivo, que o autovacuum recicla sozinho. Isso
-- não reduz o número do disco, mas impede que ele cresça -- e é o comportamento
-- correto para tabela que segue em uso.

notify pgrst, 'reload schema';
