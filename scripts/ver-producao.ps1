<#
.SYNOPSIS
  Mostra o estado das maquinas em producao, pelo terminal.

.DESCRIPTION
  Serve para a pergunta que aparece cinco minutos depois de instalar o agente numa
  loja: "chegou?". Responder isso nao deveria exigir abrir navegador, trocar a
  configuracao do dashboard e fazer login.

  Le direto da producao com a service_role key. Nao altera nada.

.PARAMETER ChaveServiceRole
  service_role key. Tenta SUPABASE_SERVICE_ROLE_KEY e depois pergunta.

.PARAMETER Loja
  Filtra por codigo de loja.

.PARAMETER Vigiar
  Reconsulta a cada 15 segundos, ate Ctrl+C. Use enquanto instala numa loja.

.PARAMETER UrlRest
  Endereco do PostgREST, quando nao e o do Supabase. Serve para instalacao
  self-hosted e para apontar a stack local. Padrao: <SUPABASE_URL>/rest/v1.

.EXAMPLE
  .\scripts\ver-producao.ps1

.EXAMPLE
  .\scripts\ver-producao.ps1 -Loja BSB-003 -Vigiar
#>
[CmdletBinding()]
param(
  [string] $ChaveServiceRole,
  [string] $Loja,
  [switch] $Vigiar,
  [string] $UrlRest
)

$ErrorActionPreference = 'Stop'

foreach ($nome in @('Tls12', 'Tls13')) {
  try {
    $valor = [Enum]::Parse([Net.SecurityProtocolType], $nome)
    [Net.ServicePointManager]::SecurityProtocol =
      [Net.ServicePointManager]::SecurityProtocol -bor $valor
  } catch { }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$envProducao = Join-Path $repoRoot '.env.producao'

if (-not (Test-Path $envProducao)) {
  Write-Host '   .env.producao nao existe. Publique primeiro:' -ForegroundColor Red
  Write-Host '     .\scripts\publicar-supabase.ps1 -ProjetoRef SEU_REF' -ForegroundColor DarkGray
  exit 1
}

$cfg = @{}
Get-Content $envProducao | ForEach-Object {
  if ($_ -match '^\s*([A-Z_]+)=(.*)$') { $cfg[$Matches[1]] = $Matches[2].Trim() }
}

if ([string]::IsNullOrWhiteSpace($ChaveServiceRole)) {
  $ChaveServiceRole = $env:SUPABASE_SERVICE_ROLE_KEY
}
if ([string]::IsNullOrWhiteSpace($ChaveServiceRole)) {
  Write-Host '   service_role key (Settings > API). Nao aparece na tela.' -ForegroundColor DarkGray
  $seguro = Read-Host -Prompt '   service_role key' -AsSecureString
  $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($seguro)
  try { $ChaveServiceRole = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

if ([string]::IsNullOrWhiteSpace($UrlRest)) {
  $UrlRest = "$($cfg['SUPABASE_URL'])/rest/v1"
}
$urlRest = $UrlRest.TrimEnd('/')
$cab = @{ apikey = $ChaveServiceRole; Authorization = "Bearer $ChaveServiceRole" }

# A view ja calcula status e ultimo contato com o mesmo criterio do dashboard.
# Refazer essa conta aqui produziria duas verdades sobre "esta offline?".
$campos = 'site_code,label,status,seconds_since_seen,cpu_pct,mem_pct,disk_min_free_pct,services_down,agent_version'
$consulta = "$urlRest/machines_status?select=$campos&order=site_code,label"
if ($Loja) { $consulta += "&site_code=eq.$($Loja.ToUpperInvariant())" }

<#
  Normaliza a resposta do PostgREST numa lista de verdade.

  O Invoke-RestMethod do PowerShell 5.1 pode devolver um array JSON como UM item
  que CONTEM o array. Nesse caso `@($resposta).Count` da 1 mesmo com sete linhas,
  e `$resposta.label` devolve os sete rotulos concatenados por enumeracao de
  membro — que foi exatamente o sintoma aqui: uma linha so, com todos os nomes
  colados, e "nao e possivel converter System.Object[] em System.Double".

  A canalizacao desembrulha um nivel, e o @() recolhe. Funciona igual quando a
  resposta ja vem desembrulhada.
#>
function Lista {
  param($Resposta)
  if ($null -eq $Resposta) { return @() }
  return @($Resposta | ForEach-Object { $_ })
}

function Desde {
  param($Segundos, $Status)
  if ($Status -eq 'never_seen') { return 'nunca' }
  if ($null -eq $Segundos) { return '-' }
  $s = [double]$Segundos
  if ($s -lt 90) { return "$([math]::Round($s))s" }
  if ($s -lt 5400) { return "$([math]::Round($s / 60))min" }
  if ($s -lt 172800) { return "$([math]::Round($s / 3600))h" }
  return "$([math]::Round($s / 86400))d"
}

function Mostrar {
  try {
    $maquinas = Lista (Invoke-RestMethod -Uri $consulta -Headers $cab -TimeoutSec 30)
  } catch {
    Write-Host ''
    Write-Host "   nao foi possivel consultar: $($_.Exception.Message)" -ForegroundColor Red
    return $false
  }

  Write-Host ''
  Write-Host "  $($cfg['SUPABASE_URL'])   $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor DarkGray
  Write-Host ''

  if ($maquinas.Count -eq 0) {
    Write-Host '   nenhuma maquina cadastrada' -ForegroundColor Yellow
    Write-Host '   cadastre com: .\scripts\comando-para-loja.ps1 -Loja X -Rotulo "PDV 01"' -ForegroundColor DarkGray
    return $true
  }

  $fmt = '  {0,-10} {1,-22} {2,-9} {3,-8} {4,6} {5,6} {6,7}  {7}'
  Write-Host ($fmt -f 'LOJA', 'MAQUINA', 'STATUS', 'CONTATO', 'CPU', 'MEM', 'DISCO', 'AGENTE') -ForegroundColor DarkGray

  foreach ($m in $maquinas) {
    $cor = switch ($m.status) {
      'online'     { 'Green' }
      'offline'    { 'Red' }
      'never_seen' { 'Yellow' }
      default      { 'DarkGray' }
    }

    $pct = { param($v) if ($null -eq $v) { '-' } else { "$([math]::Round([double]$v))%" } }

    Write-Host ($fmt -f `
      $m.site_code, `
      $m.label, `
      $m.status, `
      (Desde $m.seconds_since_seen $m.status), `
      (& $pct $m.cpu_pct), `
      (& $pct $m.mem_pct), `
      (& $pct $m.disk_min_free_pct), `
      $(if ($m.agent_version) { $m.agent_version } else { 'sem agente' })
    ) -ForegroundColor $cor

    if ([int]$m.services_down -gt 0) {
      Write-Host ("      $($m.services_down) servico(s) parado(s)") -ForegroundColor Red
    }
  }

  $online = @($maquinas | Where-Object { $_.status -eq 'online' }).Count
  $offline = @($maquinas | Where-Object { $_.status -eq 'offline' }).Count
  $nunca = @($maquinas | Where-Object { $_.status -eq 'never_seen' }).Count

  Write-Host ''
  Write-Host "  $($maquinas.Count) maquina(s): $online online, $offline offline, $nunca nunca vista(s)" -ForegroundColor DarkGray
  return $true
}

if (-not $Vigiar) {
  $ok = Mostrar
  Write-Host ''
  exit $(if ($ok) { 0 } else { 1 })
}

Write-Host ''
Write-Host '  Ctrl+C para sair' -ForegroundColor DarkGray
while ($true) {
  Clear-Host
  Mostrar | Out-Null
  Write-Host ''
  Write-Host '  atualizando a cada 15s - Ctrl+C para sair' -ForegroundColor DarkGray
  Start-Sleep -Seconds 15
}
