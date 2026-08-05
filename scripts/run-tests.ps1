<#
.SYNOPSIS
  Roda a suíte de testes SQL da Fase 1.

.DESCRIPTION
  Cada arquivo em supabase/tests é executado com ON_ERROR_STOP=1. Os testes
  assertam com RAISE EXCEPTION: se o arquivo termina, passou.

  Os testes 02 e 03 dependem do seed de exemplo (seed_demo.sql) e desfazem tudo
  com ROLLBACK — não deixam resíduo no banco.

.EXAMPLE
  $env:MONITOR_DB_URL = 'postgresql://...'
  .\scripts\run-tests.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$testsDir = Join-Path $repoRoot 'supabase\tests'

$psql = Get-Command psql -ErrorAction SilentlyContinue
if ($null -eq $psql) {
  Write-Host 'psql nao encontrado no PATH. Veja as instrucoes em .\scripts\apply-migrations.ps1' -ForegroundColor Red
  exit 1
}

if ([string]::IsNullOrWhiteSpace($env:MONITOR_DB_URL)) {
  Write-Host 'MONITOR_DB_URL nao definida.' -ForegroundColor Red
  exit 1
}

$files = Get-ChildItem -Path $testsDir -Filter '*.sql' | Sort-Object Name
$falhas = @()

foreach ($f in $files) {
  Write-Host ''
  Write-Host "===== $($f.Name) =====" -ForegroundColor Cyan

  # Sem --single-transaction: os arquivos de teste gerenciam begin/rollback
  # por conta propria, para poder trocar de role no meio.
  & $psql.Source `
      --dbname=$env:MONITOR_DB_URL `
      --no-psqlrc `
      --set=ON_ERROR_STOP=1 `
      --file=$f.FullName

  if ($LASTEXITCODE -ne 0) {
    $falhas += $f.Name
    Write-Host "FALHOU: $($f.Name)" -ForegroundColor Red
  }
}

# ---------------------------------------------------------------------------
# Lógica pura da Edge Function (não precisa de banco nem de Deno)
# ---------------------------------------------------------------------------
$libTest = Join-Path $repoRoot 'supabase\functions\ingest\lib.test.mjs'
if (Test-Path $libTest) {
  $node = Get-Command node -ErrorAction SilentlyContinue
  if ($null -eq $node) {
    Write-Host ''
    Write-Host 'node ausente: testes da Edge Function ignorados.' -ForegroundColor Yellow
    Write-Host 'Instale Node 22+ (remocao nativa de tipos) para rodar lib.test.mjs.' -ForegroundColor Yellow
  } else {
    Write-Host ''
    Write-Host '===== supabase/functions/ingest/lib.test.mjs =====' -ForegroundColor Cyan
    & $node.Source $libTest
    if ($LASTEXITCODE -ne 0) { $falhas += 'lib.test.mjs' }
  }
}

Write-Host ''
if ($falhas.Count -gt 0) {
  Write-Host "TESTES COM FALHA ($($falhas.Count)):" -ForegroundColor Red
  foreach ($x in $falhas) { Write-Host "  $x" -ForegroundColor Red }
  Write-Host ''
  exit 1
}

Write-Host 'TODOS OS TESTES PASSARAM.' -ForegroundColor Green
Write-Host ''
Write-Host 'A Edge Function em si (HTTP) so pode ser testada depois de publicada:' -ForegroundColor DarkGray
Write-Host '  supabase functions deploy ingest --no-verify-jwt' -ForegroundColor DarkGray
Write-Host '  .\scripts\test-ingest-http.ps1 -FunctionUrl ... -SharedSecret ...' -ForegroundColor DarkGray
Write-Host ''
