<#
.SYNOPSIS
  Por que a frota inteira ficou offline. SOMENTE LEITURA.

.DESCRIPTION
  Roda quando muitas maquinas caem de uma vez. Queda em massa quase nunca e das
  maquinas: e do servidor nao aceitar o que elas mandam. Este script separa as
  causas possiveis, em ordem de probabilidade, e cada bloco responde uma pergunta.

  A pergunta que vale mais: QUANDO foi a ultima gravacao bem-sucedida. Se a
  ingestao parou num minuto especifico, esse minuto e a pista -- da para cruzar
  com o que mudou naquele horario.

  Nao altera nada. Nenhum insert, update ou delete.

.PARAMETER UrlBanco
  URL do Postgres. Padrao: o pooler de supabase\.temp\pooler-url.

.EXAMPLE
  .\scripts\diagnosticar-frota-offline.ps1
#>
[CmdletBinding()]
param(
  [string] $UrlBanco,
  [System.Security.SecureString] $Senha
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot

if ([string]::IsNullOrWhiteSpace($UrlBanco)) {
  $arq = Join-Path $raiz 'supabase\.temp\pooler-url'
  if (-not (Test-Path $arq)) {
    Write-Host 'Passe -UrlBanco: nao achei supabase\.temp\pooler-url.' -ForegroundColor Red
    exit 1
  }
  $UrlBanco = (Get-Content $arq -Raw).Trim()
}

if ($null -eq $Senha) { $Senha = Read-Host -Prompt 'Senha do banco de producao' -AsSecureString }
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Senha)
try { $senhaNua = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

. (Join-Path $PSScriptRoot '_docker.ps1')
$psql = Get-Command psql -ErrorAction SilentlyContinue
$viaDocker = $null -eq $psql
if (-not (Assert-PsqlDisponivel)) { exit 1 }

$sql = @'
\timing off
\pset border 2
\pset null '—'

\echo ''
\echo '=== 1. QUANDO A INGESTAO PAROU ==='
\echo '(se ha um minuto exato, ele e a pista: cruze com o que mudou naquela hora)'
select to_char(max(ingested_at) at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI:SS') as ultima_gravacao,
       extract(epoch from now() - max(ingested_at))::int / 60 as minutos_atras,
       count(*) filter (where ingested_at > now() - interval '10 minutes')  as nos_ultimos_10min,
       count(*) filter (where ingested_at > now() - interval '60 minutes') as na_ultima_hora
from public.metrics
where "time" > now() - interval '2 days';

\echo ''
\echo '=== 2. A FROTA AGORA ==='
select status, count(*) as maquinas,
       to_char(max(last_contact_at) at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') as contato_mais_recente
from public.machines_status
where is_active
group by status
order by 2 desc;

\echo ''
\echo '=== 2b. QUEM CAIU: POR LOJA E POR VERSAO DO AGENTE ==='
\echo '(concentrado numa loja = link dela; espalhado e casado com a versao = atualizacao)'
select coalesce(site_code, '(sem loja)') as loja,
       coalesce(agent_version, '(nunca reportou)') as versao,
       count(*) filter (where status = 'online')  as online,
       count(*) filter (where status <> 'online') as fora,
       to_char(max(last_contact_at) at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') as ultimo_contato
from public.machines_status
where is_active
group by 1, 2
order by fora desc, loja;

\echo ''
\echo '=== 2c. O MINUTO EXATO EM QUE CADA UMA CALOU ==='
\echo '(se todas param no mesmo minuto, a causa e comum e externa a elas)'
select to_char(date_trunc('minute', last_contact_at) at time zone 'America/Sao_Paulo',
               'DD/MM HH24:MI') as minuto,
       count(*) as maquinas
from public.machines_status
where is_active
  and status <> 'online'
  and last_contact_at is not null
group by 1
order by 2 desc, 1 desc
limit 12;

\echo ''
\echo '=== 2d. O QUE ACONTECEU NO MINUTO DA MAIOR QUEDA ==='
\echo '(queda simultanea tem causa comum; o que a causou deixou rastro nessa janela)'
with pico as (
  select date_trunc('minute', last_contact_at) as minuto, count(*) as quantas
  from public.machines_status
  where is_active and status <> 'online' and last_contact_at is not null
  group by 1
  order by 2 desc
  limit 1
)
select 'evento' as origem,
       to_char(e.opened_at at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') as quando,
       e.kind,
       left(coalesce(e.message, ''), 60) as detalhe,
       count(*) over (partition by e.kind) as vezes_no_periodo
from public.events e, pico
where e.opened_at between pico.minuto - interval '30 minutes'
                      and pico.minuto + interval '30 minutes'
union all
select 'comando' as origem,
       to_char(c.created_at at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
       c.kind,
       left(coalesce(c.result_text, c.status), 60),
       count(*) over (partition by c.kind)
from public.agent_commands c, pico
where c.created_at between pico.minuto - interval '30 minutes'
                       and pico.minuto + interval '30 minutes'
order by quando
limit 25;

\echo ''
\echo '=== 3. O BANCO ESTA EM SOMENTE-LEITURA? ==='
\echo '(limite de disco estourado deixa a leitura funcionando e mata a gravacao)'
select current_setting('default_transaction_read_only') as transacao_somente_leitura,
       pg_size_pretty(pg_database_size(current_database())) as tamanho_do_banco,
       (select pg_size_pretty(sum(pg_total_relation_size(c.oid)))
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind = 'r') as tamanho_das_tabelas;

\echo ''
\echo '=== 4. AS MAIORES TABELAS ==='
select c.relname as tabela,
       pg_size_pretty(pg_total_relation_size(c.oid)) as tamanho
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname in ('public') and c.relkind in ('r', 'p')
order by pg_total_relation_size(c.oid) desc
limit 8;

\echo ''
\echo '=== 5. CONEXOES ==='
\echo '(esgotar conexao faz a funcao de ingestao falhar sem o banco estar fora)'
select (select setting::int from pg_settings where name = 'max_connections') as maximo,
       count(*) as em_uso,
       count(*) filter (where state = 'active') as ativas,
       count(*) filter (where state = 'idle in transaction') as presas_em_transacao,
       count(*) filter (where wait_event_type = 'Lock') as esperando_lock
from pg_stat_activity;

\echo ''
\echo '=== 6. O AVALIADOR DE ALERTAS (avaliar-alertas, cada 1 min) ==='
\echo '(se ele demora mais que 60 s, as execucoes se empilham)'
select to_char(d.start_time at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI:SS') as inicio,
       d.status,
       round(extract(epoch from (d.end_time - d.start_time))::numeric, 1) as segundos,
       left(coalesce(d.return_message, ''), 60) as mensagem
-- Filtro pelo COMANDO, e nao pelo nome do job: cron.job_run_details nao tem
-- coluna jobname (so jobid), e o jobid MUDA a cada unschedule/schedule. Juntar
-- por nome perderia justamente o historico de antes do reagendamento, que e o
-- que se quer olhar depois de mexer no intervalo.
from cron.job_run_details d
where d.command like '%avaliar_alertas%'
order by d.start_time desc
limit 10;

\echo ''
\echo '=== 7. QUANTO TEMPO O AVALIADOR LEVA, EM MEDIA ==='
select count(*) as execucoes,
       round(avg(extract(epoch from (d.end_time - d.start_time)))::numeric, 1) as media_s,
       round(max(extract(epoch from (d.end_time - d.start_time)))::numeric, 1) as pior_s,
       count(*) filter (where d.status <> 'succeeded') as falhas
from cron.job_run_details d
where d.command like '%avaliar_alertas%'
  and d.start_time > now() - interval '2 hours';

\echo ''
\echo '=== 8. ERROS QUE AS MAQUINAS REPORTARAM ==='
select to_char(e.opened_at at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') as hora,
       e.kind, left(coalesce(e.message, ''), 70) as mensagem, count(*) as vezes
from public.events e
where e.opened_at > now() - interval '6 hours'
  and e.kind in ('agent_error', 'agent_stop', 'agent_update')
group by 1, 2, 3
order by 1 desc
limit 10;

\echo ''
\echo '=== 9. ALERTAS ABERTOS AGORA ==='
select severity, count(*) from public.open_alerts group by 1 order by 1;
'@

$tmp = Join-Path $env:TEMP 'diag-offline.sql'
Set-Content -Path $tmp -Value $sql -Encoding utf8

$antes = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  if ($viaDocker) {
    docker cp $tmp monitor-db:/tmp/diag.sql | Out-Null
    docker exec -e PGPASSWORD=$senhaNua monitor-db psql $UrlBanco -f /tmp/diag.sql
  } else {
    $env:PGPASSWORD = $senhaNua
    & $psql.Source $UrlBanco -f $tmp
  }
  $saiu = $LASTEXITCODE
} finally { $ErrorActionPreference = $antes }

Remove-Item $tmp -ErrorAction SilentlyContinue

if ($saiu -ne 0) {
  Write-Host ''
  Write-Host "A CONSULTA FALHOU (codigo $saiu) -- e isso ja e uma resposta." -ForegroundColor Red
  Write-Host 'Se nem o psql conecta, o problema nao e o agente: e o banco.' -ForegroundColor Yellow
  exit 1
}

Write-Host ''
Write-Host 'COMO LER:' -ForegroundColor Yellow
Write-Host '  1  "minutos_atras" alto com "nos_ultimos_10min" em 0 = a gravacao parou.'
Write-Host '     O horario da ultima gravacao e a pista principal.'
Write-Host '  3  transacao_somente_leitura = on significa limite de disco estourado:'
Write-Host '     leitura funciona, gravacao nao, e a frota toda "cai" de uma vez.'
Write-Host '  5  "em_uso" perto do "maximo" = a funcao de ingestao nao consegue'
Write-Host '     conexao e falha, sem o banco estar fora do ar.'
Write-Host '  6/7 se o avaliador leva mais de 60 s, as execucoes se empilham e ele'
Write-Host '     mesmo vira a causa. Foi ele que eu agendei hoje.'
Write-Host ''
