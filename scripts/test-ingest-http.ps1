<#
.SYNOPSIS
  Testa a Edge Function de ingestão já publicada, pelo HTTP real.

.DESCRIPTION
  Cobre o critério de aceite da Fase 2 na camada de rede:
    - token válido grava              -> 200 com contagem
    - reenviar o mesmo lote           -> 200 com accepted=0 (idempotência)
    - token revogado                  -> 401
    - token inexistente               -> 401
    - sem o segredo compartilhado     -> 401 (regra 6)
    - payload malformado              -> 400
    - timestamp fora da janela        -> 422
    - lote acima do teto              -> 400
    - healthz sem segredo             -> 200 só com liveness
    - healthz com segredo             -> 200 com diagnóstico

  Este script NÃO revoga o token que você passar: ele provisiona uma máquina
  descartável para os testes destrutivos, usando MONITOR_DB_URL.

.PARAMETER FunctionUrl
  Ex.: https://SEUPROJETO.supabase.co/functions/v1/ingest

.PARAMETER SharedSecret
  Valor de INGEST_SHARED_SECRET configurado na função.

.PARAMETER SiteCode
  Loja onde a máquina de teste será criada. Padrão: BSB-001.

.EXAMPLE
  $env:MONITOR_DB_URL = 'postgresql://...'
  .\scripts\test-ingest-http.ps1 `
      -FunctionUrl 'https://abc.supabase.co/functions/v1/ingest' `
      -SharedSecret 'o-segredo-configurado-na-function'
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string] $FunctionUrl,
  [Parameter(Mandatory = $true)][string] $SharedSecret,
  [string] $SiteCode = 'BSB-001'
)

$ErrorActionPreference = 'Stop'

if ($FunctionUrl -notmatch '^https://') {
  Write-Host 'FunctionUrl deve ser HTTPS (regra 9).' -ForegroundColor Red
  exit 1
}

$psql = Get-Command psql -ErrorAction SilentlyContinue
if ($null -eq $psql) { Write-Host 'psql ausente.' -ForegroundColor Red; exit 1 }
if ([string]::IsNullOrWhiteSpace($env:MONITOR_DB_URL)) {
  Write-Host 'MONITOR_DB_URL nao definida (necessaria para provisionar a maquina de teste).' -ForegroundColor Red
  exit 1
}

$script:passou = 0
$script:falhas = @()

function Invoke-Ingest {
  param(
    [hashtable] $Body,
    [string] $Token,
    [string] $Secret = $SharedSecret,
    [switch] $OmitSecret,
    [string] $Method = 'POST',
    [string] $Path = ''
  )

  $headers = @{}
  if (-not $OmitSecret) { $headers['x-monitor-secret'] = $Secret }
  if ($Token) { $headers['Authorization'] = "Bearer $Token" }

  $uri = $FunctionUrl + $Path
  $json = $null
  if ($Body) { $json = ($Body | ConvertTo-Json -Depth 10 -Compress) }

  try {
    $r = Invoke-WebRequest -Uri $uri -Method $Method -Headers $headers `
           -ContentType 'application/json' -Body $json -UseBasicParsing
    return @{ Status = [int]$r.StatusCode; Body = ($r.Content | ConvertFrom-Json) }
  } catch {
    $resp = $_.Exception.Response
    if ($null -eq $resp) { throw }
    $status = [int]$resp.StatusCode
    $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
    $texto = $reader.ReadToEnd()
    $obj = $null
    try { $obj = $texto | ConvertFrom-Json } catch { $obj = $texto }
    return @{ Status = $status; Body = $obj }
  }
}

function Assert-Status {
  param([string] $Nome, [hashtable] $Resposta, [int] $Esperado)

  if ($Resposta.Status -eq $Esperado) {
    Write-Host ("  ok    {0}  (HTTP {1})" -f $Nome, $Resposta.Status) -ForegroundColor Green
    $script:passou++
  } else {
    $detalhe = ($Resposta.Body | ConvertTo-Json -Compress -Depth 5)
    Write-Host ("  FALHA {0}  esperado HTTP {1}, veio {2}" -f $Nome, $Esperado, $Resposta.Status) -ForegroundColor Red
    Write-Host ("        {0}" -f $detalhe) -ForegroundColor DarkGray
    $script:falhas += $Nome
  }
}

function New-Sample {
  param([int] $OffsetSegundos = 0)
  @{
    t                = (Get-Date).ToUniversalTime().AddSeconds(-$OffsetSegundos).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    cpu_pct          = 12.5
    mem_total_mb     = 32561
    mem_used_mb      = 18194
    uptime_seconds   = 116182
    proc_count       = 282
    gw_latency_ms    = 1.2
    gw_loss_pct      = 0
    flags            = @('temp_denied')
    disks            = @(@{ drive = 'C:'; filesystem = 'NTFS'; total_gb = 237.5; free_gb = 121.0 })
    services         = @(@{ name = 'Spooler'; is_running = $true; state_raw = 'Running' })
  }
}

# ---------------------------------------------------------------------------
# Provisiona máquina descartável
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Provisionando maquina de teste...' -ForegroundColor Cyan

$rotulo = "HTTP-TESTE-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$sql = "select token, token_prefix from public.provision_machine(:'site', :'label', 'pdv', 'maquina descartavel de teste HTTP');"

$saida = & $psql.Source --dbname=$env:MONITOR_DB_URL --no-psqlrc --tuples-only --no-align `
           --field-separator='|' --set=ON_ERROR_STOP=1 -v site=$SiteCode -v label=$rotulo --command=$sql
if ($LASTEXITCODE -ne 0) { Write-Host 'Falha ao provisionar.' -ForegroundColor Red; exit 1 }

$c = ($saida | Where-Object { $_ -match '\|' } | Select-Object -First 1).Split('|')
$token = $c[0]
$prefixo = $c[1]

Write-Host ("Maquina: {0}  prefixo {1}" -f $rotulo, $prefixo) -ForegroundColor DarkGray
Write-Host ''

try {
  # -------------------------------------------------------------------------
  Write-Host '== healthz ==' -ForegroundColor Cyan
  # -------------------------------------------------------------------------
  $r = Invoke-Ingest -Method GET -Path '/healthz' -OmitSecret
  Assert-Status 'healthz sem segredo responde liveness' $r 200
  if ($r.Body.db) {
    Write-Host '  FALHA healthz sem segredo VAZOU diagnostico do parque' -ForegroundColor Red
    $script:falhas += 'healthz vazou'
  }

  $r = Invoke-Ingest -Method GET -Path '/healthz'
  Assert-Status 'healthz com segredo responde diagnostico' $r 200
  if (-not $r.Body.db) {
    Write-Host '  FALHA healthz com segredo nao trouxe diagnostico' -ForegroundColor Red
    $script:falhas += 'healthz sem db'
  } elseif ([int]$r.Body.db.partitions_ahead -lt 1) {
    Write-Host '  AVISO: partitions_ahead = 0. A ingestao vai parar. Habilite pg_cron.' -ForegroundColor Yellow
  }

  # -------------------------------------------------------------------------
  Write-Host ''
  Write-Host '== autenticacao ==' -ForegroundColor Cyan
  # -------------------------------------------------------------------------
  $lote = @{
    agent_version = '1.0.0-httpteste'
    sent_at       = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    machine       = @{ hostname = $rotulo; os_caption = 'Microsoft Windows 11 Pro'; os_arch = '64 bits' }
    samples       = @((New-Sample -OffsetSegundos 120), (New-Sample -OffsetSegundos 60))
  }

  Assert-Status 'sem segredo compartilhado (regra 6)' (Invoke-Ingest -Body $lote -Token $token -OmitSecret) 401
  Assert-Status 'segredo errado' (Invoke-Ingest -Body $lote -Token $token -Secret 'errado-errado-errado-1234') 401
  Assert-Status 'sem Authorization' (Invoke-Ingest -Body $lote) 401
  Assert-Status 'token inexistente' (Invoke-Ingest -Body $lote -Token ('mon_' + ('0' * 64))) 401

  # -------------------------------------------------------------------------
  Write-Host ''
  Write-Host '== gravacao e idempotencia ==' -ForegroundColor Cyan
  # -------------------------------------------------------------------------
  $r = Invoke-Ingest -Body $lote -Token $token
  Assert-Status 'token valido grava' $r 200
  if ($r.Status -eq 200) {
    if ([int]$r.Body.accepted -ne 2) {
      Write-Host ("  FALHA accepted = {0}, esperado 2" -f $r.Body.accepted) -ForegroundColor Red
      $script:falhas += 'accepted != 2'
    } else {
      Write-Host ("        accepted={0} disk_rows={1} service_rows={2} drift={3}s" -f `
        $r.Body.accepted, $r.Body.disk_rows, $r.Body.service_rows, $r.Body.clock_drift_seconds) -ForegroundColor DarkGray
    }
  }

  $r2 = Invoke-Ingest -Body $lote -Token $token
  Assert-Status 'reenvio do mesmo lote (regra 13)' $r2 200
  if ($r2.Status -eq 200) {
    if ([int]$r2.Body.accepted -ne 0 -or [int]$r2.Body.duplicates -ne 2) {
      Write-Host ("  FALHA reenvio: accepted={0} duplicates={1}, esperado 0 e 2" -f `
        $r2.Body.accepted, $r2.Body.duplicates) -ForegroundColor Red
      $script:falhas += 'idempotencia'
    }
  }

  # -------------------------------------------------------------------------
  Write-Host ''
  Write-Host '== validacao de payload ==' -ForegroundColor Cyan
  # -------------------------------------------------------------------------
  Assert-Status 'sem agent_version' (Invoke-Ingest -Body @{ samples = @((New-Sample)) } -Token $token) 400
  Assert-Status 'samples vazio' (Invoke-Ingest -Body @{ agent_version = '1.0.0'; samples = @() } -Token $token) 400

  $futuro = @{
    agent_version = '1.0.0-httpteste'
    sent_at       = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    samples       = @(@{ t = (Get-Date).ToUniversalTime().AddHours(5).ToString('yyyy-MM-ddTHH:mm:ss.fffZ'); cpu_pct = 10 })
  }
  Assert-Status 'lote 100% fora da janela (regra 14)' (Invoke-Ingest -Body $futuro -Token $token) 422

  $gigante = @{
    agent_version = '1.0.0-httpteste'
    sent_at       = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    samples       = @(1..600 | ForEach-Object { New-Sample -OffsetSegundos $_ })
  }
  Assert-Status 'lote acima do teto' (Invoke-Ingest -Body $gigante -Token $token) 400

  # -------------------------------------------------------------------------
  Write-Host ''
  Write-Host '== lote de 200 amostras ==' -ForegroundColor Cyan
  # -------------------------------------------------------------------------
  $lote200 = @{
    agent_version = '1.0.0-httpteste'
    sent_at       = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    samples       = @(300..499 | ForEach-Object { New-Sample -OffsetSegundos $_ })
  }
  $r = Invoke-Ingest -Body $lote200 -Token $token
  Assert-Status 'lote de 200 amostras' $r 200
  if ($r.Status -eq 200 -and [int]$r.Body.accepted -ne 200) {
    Write-Host ("  FALHA accepted = {0}, esperado 200" -f $r.Body.accepted) -ForegroundColor Red
    $script:falhas += 'lote 200'
  }

  # -------------------------------------------------------------------------
  Write-Host ''
  Write-Host '== token revogado ==' -ForegroundColor Cyan
  # -------------------------------------------------------------------------
  & $psql.Source --dbname=$env:MONITOR_DB_URL --no-psqlrc --quiet --set=ON_ERROR_STOP=1 `
    -v prefix=$prefixo --command="select public.revoke_agent_token(:'prefix', 'teste HTTP');" | Out-Null

  Assert-Status 'token revogado devolve 401' (Invoke-Ingest -Body $lote -Token $token) 401
}
finally {
  Write-Host ''
  Write-Host 'Limpando maquina de teste...' -ForegroundColor DarkGray
  & $psql.Source --dbname=$env:MONITOR_DB_URL --no-psqlrc --quiet --set=ON_ERROR_STOP=1 `
    -v label=$rotulo --command="delete from public.machines where label = :'label';" | Out-Null
}

Write-Host ''
if ($script:falhas.Count -gt 0) {
  Write-Host ("FALHARAM {0} verificacoes:" -f $script:falhas.Count) -ForegroundColor Red
  foreach ($f in $script:falhas) { Write-Host "  - $f" -ForegroundColor Red }
  exit 1
}
Write-Host ("TODAS AS {0} VERIFICACOES HTTP PASSARAM." -f $script:passou) -ForegroundColor Green
Write-Host ''
