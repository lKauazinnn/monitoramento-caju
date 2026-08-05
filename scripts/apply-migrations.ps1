<#
.SYNOPSIS
  Aplica as migrations da Fase 1 em ordem, opcionalmente duas vezes seguidas
  para provar idempotência.

.DESCRIPTION
  Aplica direto via psql, sem passar pelo registro de migrations do Supabase CLI.
  Isso é o que permite testar o critério de aceite "rodar do zero duas vezes
  seguidas sem erro" — o CLI pularia a segunda execução e o teste não valeria
  nada.

  A string de conexão vem SEMPRE de variável de ambiente. Nenhuma credencial
  neste arquivo (regra 1).

.PARAMETER Twice
  Aplica todo o conjunto duas vezes. É o teste de idempotência.

.PARAMETER Seed
  Aplica supabase/seed/seed_demo.sql depois das migrations.

.PARAMETER SyntheticMetrics
  Aplica também 24h de métricas sintéticas. NUNCA use em produção.

.EXAMPLE
  $env:MONITOR_DB_URL = 'postgresql://postgres.abcdefgh:SENHA@aws-0-sa-east-1.pooler.supabase.com:5432/postgres'
  .\scripts\apply-migrations.ps1 -Twice -Seed
#>
[CmdletBinding()]
param(
  [switch] $Twice,
  [switch] $Seed,
  [switch] $SyntheticMetrics
)

$ErrorActionPreference = 'Stop'

$repoRoot      = Split-Path -Parent $PSScriptRoot
$migrationsDir = Join-Path $repoRoot 'supabase\migrations'
$seedDir       = Join-Path $repoRoot 'supabase\seed'

# ---------------------------------------------------------------------------
# Pré-requisitos
# ---------------------------------------------------------------------------
$psql = Get-Command psql -ErrorAction SilentlyContinue
if ($null -eq $psql) {
  Write-Host ''
  Write-Host 'psql nao encontrado no PATH.' -ForegroundColor Red
  Write-Host ''
  Write-Host 'Opcoes, em ordem de preferencia:' -ForegroundColor Yellow
  Write-Host '  1) winget install -e --id PostgreSQL.PostgreSQL.16'
  Write-Host '     (ou baixe apenas os Command Line Tools do instalador EDB)'
  Write-Host '     Depois adicione C:\Program Files\PostgreSQL\16\bin ao PATH.'
  Write-Host ''
  Write-Host '  2) Aplicar manualmente pelo SQL Editor do Supabase, colando os'
  Write-Host '     arquivos NA ORDEM do nome. Funciona, mas o teste de'
  Write-Host '     idempotencia fica manual (colar tudo duas vezes).'
  Write-Host ''
  Write-Host '  3) Supabase CLI: npm i -g supabase; supabase db push'
  Write-Host '     ATENCAO: o CLI registra o que aplicou e NAO reexecuta,'
  Write-Host '     entao ele nao serve para o teste de idempotencia.'
  Write-Host ''
  exit 1
}

if ([string]::IsNullOrWhiteSpace($env:MONITOR_DB_URL)) {
  Write-Host ''
  Write-Host 'Variavel de ambiente MONITOR_DB_URL nao definida.' -ForegroundColor Red
  Write-Host ''
  Write-Host 'Pegue a connection string em:'
  Write-Host '  Supabase > Project Settings > Database > Connection string > URI'
  Write-Host ''
  Write-Host 'Defina somente na sessao atual (nao persista em arquivo):'
  Write-Host '  $env:MONITOR_DB_URL = ''postgresql://...'''
  Write-Host ''
  exit 1
}

if (-not (Test-Path $migrationsDir)) {
  throw "Diretorio de migrations nao encontrado: $migrationsDir"
}

$files = Get-ChildItem -Path $migrationsDir -Filter '*.sql' | Sort-Object Name
if ($files.Count -eq 0) {
  throw "Nenhuma migration encontrada em $migrationsDir"
}

Write-Host ''
Write-Host "Migrations encontradas: $($files.Count)" -ForegroundColor Cyan
foreach ($f in $files) { Write-Host "  $($f.Name)" }
Write-Host ''

# ---------------------------------------------------------------------------
# Aplicação
# ---------------------------------------------------------------------------
function Invoke-SqlFile {
  param(
    [Parameter(Mandatory = $true)][string] $Path,
    [Parameter(Mandatory = $true)][string] $Rotulo
  )

  Write-Host "-> $Rotulo" -ForegroundColor DarkCyan

  # --single-transaction: a migration inteira aplica ou nenhuma parte aplica.
  # ON_ERROR_STOP=1: psql sai com codigo != 0 no primeiro erro.
  & $psql.Source `
      --dbname=$env:MONITOR_DB_URL `
      --no-psqlrc `
      --quiet `
      --single-transaction `
      --set=ON_ERROR_STOP=1 `
      --file=$Path

  if ($LASTEXITCODE -ne 0) {
    throw "FALHOU em $Rotulo (psql exit $LASTEXITCODE)"
  }
}

$passes = 1
if ($Twice) { $passes = 2 }

for ($pass = 1; $pass -le $passes; $pass++) {
  if ($Twice) {
    Write-Host ''
    Write-Host "===== PASSAGEM $pass de $passes =====" -ForegroundColor Green
    Write-Host ''
  }

  foreach ($f in $files) {
    Invoke-SqlFile -Path $f.FullName -Rotulo $f.Name
  }
}

if ($Seed) {
  Write-Host ''
  Write-Host '===== SEED =====' -ForegroundColor Green
  Invoke-SqlFile -Path (Join-Path $seedDir 'seed_demo.sql') -Rotulo 'seed_demo.sql'
}

if ($SyntheticMetrics) {
  Write-Host ''
  Write-Host 'ATENCAO: gerando metricas SINTETICAS (agent_version = seed-0.0.0).' -ForegroundColor Yellow
  Write-Host 'Isto e material de desenvolvimento do dashboard. Nao use em producao.' -ForegroundColor Yellow
  Invoke-SqlFile -Path (Join-Path $seedDir 'seed_metrics_sinteticas.sql') -Rotulo 'seed_metrics_sinteticas.sql'
}

Write-Host ''
if ($Twice) {
  Write-Host 'IDEMPOTENCIA CONFIRMADA: as migrations aplicaram duas vezes sem erro.' -ForegroundColor Green
} else {
  Write-Host 'Migrations aplicadas.' -ForegroundColor Green
  Write-Host 'Rode com -Twice para provar idempotencia.' -ForegroundColor DarkGray
}
Write-Host ''
Write-Host 'Proximo passo: .\scripts\run-tests.ps1' -ForegroundColor Cyan
Write-Host ''
