<#
.SYNOPSIS
  Contorna o limite do Supabase. Sem parametro, so MEDE e recomenda.

.DESCRIPTION
  Tres alavancas, com efeitos diferentes. Sem parametro nenhum este script nao
  muda nada: mede e diz qual alavanca resolve o SEU caso.

  -EspacarAvaliador   CPU/conexao. Reversivel, nao perde dado.
      O job que avalia alertas roda a cada minuto sobre machines_status, uma view
      com cinco laterais por maquina. Fui eu que o agendei. Passar para 5 minutos
      corta a carga dele em 80% e o custo e o alerta demorar ate 5 min a mais para
      abrir -- a DETECCAO de offline nao muda, ela e do banco.

  -PurgarMetricas N   DISCO. IRREVERSIVEL para o periodo removido.
      Baixa metrics_retention_days para N e roda a manutencao.

      LEIA ISTO ANTES: o expurgo remove particao por MES INTEIRO
      (date_trunc('month')). Com N=7 hoje, ele apaga tudo ANTES do mes corrente e
      mantem o mes corrente inteiro. Se o volume esta quase todo no mes atual,
      isso libera pouco -- o script mostra o tamanho por mes justamente para voce
      decidir com numero, e nao com esperanca.

      O historico NAO se perde por completo: existe rollup por hora guardado 400
      dias (metrics_hourly_retention_days). O que sai e o dado BRUTO minuto a
      minuto do periodo antigo. Retencao curta no bruto e longa no agregado e a
      arquitetura pretendida, nao um remendo.

      Minimo de 7 dias, imposto pelo proprio banco (drop_old_partitions recusa
      menos que isso).

  O QUE ESTE SCRIPT NAO RESOLVE, e e a causa de fundo:

      O volume gravado por ciclo. 45 maquinas reportando a cada 60 s geram
      milhoes de linhas por mes em metrics, metrics_disks e metrics_services.
      Purgar libera espaco uma vez; o volume volta. A correcao estrutural e
      espacar a coleta (intervalSeconds no agente) ou reduzir o pulso -- e as duas
      exigem tocar nos agentes, nao no banco.

.EXAMPLE
  .\scripts\contornar-limite-supabase.ps1

.EXAMPLE
  .\scripts\contornar-limite-supabase.ps1 -EspacarAvaliador

.EXAMPLE
  .\scripts\contornar-limite-supabase.ps1 -PurgarMetricas 7
#>
[CmdletBinding()]
param(
  [switch] $EspacarAvaliador,
  [ValidateRange(7, 365)]
  [int]    $PurgarMetricas = 0,
  [int]    $MinutosDoAvaliador = 5,
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

function Rodar([string] $arquivo) {
  $antes = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($viaDocker) {
      docker cp $arquivo monitor-db:/tmp/lim.sql | Out-Null
      docker exec -e PGPASSWORD=$senhaNua monitor-db psql $UrlBanco -f /tmp/lim.sql
    } else {
      $env:PGPASSWORD = $senhaNua
      & $psql.Source $UrlBanco -f $arquivo
    }
  } finally { $ErrorActionPreference = $antes }
}

# =============================================================================
# 1. MEDIR (sempre)
# =============================================================================
$medir = @'
\pset border 2
\pset null '—'

\echo ''
\echo '=== O BANCO ==='
select pg_size_pretty(pg_database_size(current_database())) as tamanho,
       current_setting('default_transaction_read_only') as somente_leitura;

\echo ''
\echo '=== ONDE O ESPACO ESTA (por tabela) ==='
select c.relname as tabela, pg_size_pretty(pg_total_relation_size(c.oid)) as tamanho
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind in ('r', 'p')
order by pg_total_relation_size(c.oid) desc
limit 6;

\echo ''
\echo '=== AS PARTICOES DE METRICS, POR MES ==='
\echo '(o expurgo remove MES INTEIRO: so o que estiver em mes anterior sai)'
select c.relname as particao,
       pg_size_pretty(pg_total_relation_size(c.oid)) as tamanho,
       case when c.relname ~ to_char(now(), 'YYYY_MM') then 'MES CORRENTE (nao sai)'
            else 'mes anterior' end as situacao
from pg_class c
join pg_inherits i on i.inhrelid = c.oid
join pg_class pai on pai.oid = i.inhparent
where pai.relname in ('metrics', 'metrics_disks', 'metrics_services')
order by pg_total_relation_size(c.oid) desc
limit 12;

\echo ''
\echo '=== RETENCAO CONFIGURADA ==='
select key, value from public.app_settings
where key like '%retention%' order by key;

\echo ''
\echo '=== O AVALIADOR ==='
select coalesce((select schedule from cron.job where jobname = 'monitor_avaliar_alertas'),
                'AUSENTE') as agendamento,
       (select round(avg(extract(epoch from (end_time - start_time)))::numeric, 1)
        from cron.job_run_details
        where jobname = 'monitor_avaliar_alertas'
          and start_time > now() - interval '2 hours') as media_segundos,
       (select count(*) from cron.job_run_details
        where jobname = 'monitor_avaliar_alertas'
          and start_time > now() - interval '2 hours' and status <> 'succeeded') as falhas_2h;
'@

$tmp = Join-Path $env:TEMP 'lim-medir.sql'
Set-Content -Path $tmp -Value $medir -Encoding utf8
Write-Host ''
Write-Host '============================================================'
Write-Host ' MEDINDO' -ForegroundColor Cyan
Write-Host '============================================================'
Rodar $tmp
Remove-Item $tmp -ErrorAction SilentlyContinue

if (-not $EspacarAvaliador -and $PurgarMetricas -eq 0) {
  Write-Host ''
  Write-Host 'Nada foi alterado. Escolha a alavanca conforme o que voce viu:' -ForegroundColor Yellow
  Write-Host ''
  Write-Host '  somente_leitura = on  -> e DISCO. Purgue:' -ForegroundColor Yellow
  Write-Host '      .\scripts\contornar-limite-supabase.ps1 -PurgarMetricas 7'
  Write-Host '    Confira antes o tamanho das particoes de MES ANTERIOR: e so isso'
  Write-Host '    que sai. Se o mes corrente e quase tudo, purgar libera pouco e a'
  Write-Host '    saida e plano maior ou coleta mais espacada.' -ForegroundColor DarkGray
  Write-Host ''
  Write-Host '  media_segundos > 30   -> o avaliador esta pesado. Espace:' -ForegroundColor Yellow
  Write-Host '      .\scripts\contornar-limite-supabase.ps1 -EspacarAvaliador'
  Write-Host '    Reversivel, nao perde dado, e a deteccao de offline nao muda.' -ForegroundColor DarkGray
  Write-Host ''
  exit 0
}

# =============================================================================
# 2. AGIR
# =============================================================================
$acoes = @()

if ($EspacarAvaliador) {
  # cron.schedule com o MESMO nome reagenda no lugar; nao cria um segundo job.
  $acoes += "select cron.schedule('monitor_avaliar_alertas', '*/$MinutosDoAvaliador * * * *', 'select public.avaliar_alertas();');"
  $acoes += "\echo 'avaliador reagendado'"
}

if ($PurgarMetricas -gt 0) {
  Write-Host ''
  Write-Host '============================================================' -ForegroundColor Red
  Write-Host " PURGA IRREVERSIVEL: retencao do dado BRUTO vai para $PurgarMetricas dia(s)" -ForegroundColor Red
  Write-Host '============================================================' -ForegroundColor Red
  Write-Host ' Particoes de meses anteriores serao REMOVIDAS. O agregado por hora'
  Write-Host ' (400 dias) permanece, entao o historico longo nao se perde -- o que'
  Write-Host ' sai e o minuto a minuto antigo.'
  Write-Host ''
  $r = Read-Host " Digite PURGAR para confirmar"
  if ($r -ne 'PURGAR') {
    Write-Host 'Cancelado. Nada foi alterado.' -ForegroundColor Yellow
    exit 0
  }

  $acoes += "update public.app_settings set value = '$PurgarMetricas' where key = 'metrics_retention_days';"
  $acoes += "select public.run_maintenance();"
  $acoes += "\echo 'manutencao executada'"
  $acoes += "select pg_size_pretty(pg_database_size(current_database())) as tamanho_depois;"
}

$sqlAcao = ($acoes -join "`n")
$tmp2 = Join-Path $env:TEMP 'lim-agir.sql'
Set-Content -Path $tmp2 -Value $sqlAcao -Encoding utf8

Write-Host ''
Write-Host '============================================================'
Write-Host ' APLICANDO' -ForegroundColor Cyan
Write-Host '============================================================'
Rodar $tmp2
$saiu = $LASTEXITCODE
Remove-Item $tmp2 -ErrorAction SilentlyContinue

if ($saiu -ne 0) {
  Write-Host ''
  Write-Host "FALHOU (codigo $saiu). Confira a mensagem acima." -ForegroundColor Red
  exit 1
}

Write-Host ''
if ($EspacarAvaliador) {
  Write-Host "Avaliador agora roda a cada $MinutosDoAvaliador minuto(s)." -ForegroundColor Green
  Write-Host 'Para voltar a cada minuto:' -ForegroundColor DarkGray
  Write-Host "  .\scripts\contornar-limite-supabase.ps1 -EspacarAvaliador -MinutosDoAvaliador 1" -ForegroundColor DarkGray
}
if ($PurgarMetricas -gt 0) {
  Write-Host "Retencao do bruto em $PurgarMetricas dia(s) e manutencao executada." -ForegroundColor Green
}
Write-Host ''
Write-Host 'A CAUSA DE FUNDO continua: 45 maquinas a cada 60 s geram milhoes de' -ForegroundColor Yellow
Write-Host 'linhas por mes. Purgar libera espaco uma vez; o volume volta. Espacar a' -ForegroundColor Yellow
Write-Host 'coleta no agente e o que resolve de verdade.' -ForegroundColor Yellow
Write-Host ''
