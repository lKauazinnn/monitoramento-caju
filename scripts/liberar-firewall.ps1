<#
.SYNOPSIS
  Libera a porta da ingestao no Firewall do Windows, para os PCs da loja
  alcancarem este servidor.

.DESCRIPTION
  Sem esta regra o agente de outro PC nao consegue nem baixar o instalador, e o
  erro que aparece la e "Impossivel conectar-se ao servidor remoto" — que nao diz
  nada sobre firewall e manda procurar no lugar errado.

  A regra e restrita a SUA REDE LOCAL (o /24 do IP desta maquina). A porta nao
  fica aberta para tudo, so para quem esta na mesma rede.

  PRECISA DE TERMINAL ELEVADO. Regra de firewall e uma alteracao no sistema, e o
  Windows exige administrador — nao ha como contornar, nem deveria haver.

  Depois de criar, ele CONFERE: verifica que a regra existe, que o Docker esta
  escutando e que o endpoint responde pelo IP da rede.

.PARAMETER Porta
  Porta da ingestao. Padrao: lida do .env, ou 3010.

.PARAMETER Remover
  Remove a regra em vez de criar.

.EXAMPLE
  # Clique com o botao direito no arquivo > "Executar com o PowerShell" (como admin)
  .\scripts\liberar-firewall.ps1

.EXAMPLE
  .\scripts\liberar-firewall.ps1 -Remover
#>
[CmdletBinding()]
param(
  [int]    $Porta,
  [switch] $Remover
)

$ErrorActionPreference = 'Stop'
$NOME = 'Monitoramento Cajupar - ingestao'

function Ok    { param([string]$T) Write-Host "   $T" -ForegroundColor Green }
function Info  { param([string]$T) Write-Host "   $T" -ForegroundColor DarkGray }
function Aviso { param([string]$T) Write-Host "   $T" -ForegroundColor Yellow }
function Erro  { param([string]$T) Write-Host "   $T" -ForegroundColor Red }
function Passo { param([string]$T) Write-Host ''; Write-Host "== $T ==" -ForegroundColor Cyan }

$repoRoot = Split-Path -Parent $PSScriptRoot

# ---------------------------------------------------------------------------
Passo 'Verificando privilegio'
# ---------------------------------------------------------------------------
$ehAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $ehAdmin) {
  Erro 'este script precisa de PowerShell COMO ADMINISTRADOR.'
  Write-Host ''
  Aviso 'Jeito mais simples: clique duas vezes em'
  Write-Host "     $repoRoot\scripts\liberar-firewall.cmd" -ForegroundColor White
  Write-Host '   (ele pede a elevacao e ja contorna a politica de execucao)'
  Write-Host ''
  Aviso 'Ou, num PowerShell aberto COMO ADMINISTRADOR:'
  Write-Host "     cd '$repoRoot'" -ForegroundColor White
  # -ExecutionPolicy Bypass no comando, e nao `.\script.ps1` puro: a politica
  # padrao do Windows recusa .ps1 com "a execucao de scripts foi desabilitada
  # neste sistema", e sugerir o comando que falha e pior que nao sugerir nada.
  Write-Host '     powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\liberar-firewall.ps1' -ForegroundColor White
  Write-Host ''
  exit 1
}
Ok 'rodando como administrador'

# ---------------------------------------------------------------------------
Passo 'Descobrindo porta e rede'
# ---------------------------------------------------------------------------
if (-not $Porta) {
  $envFile = Join-Path $repoRoot '.env'
  if (Test-Path $envFile) {
    $m = Select-String -Path $envFile -Pattern '^INGEST_PORT=(\d+)' -ErrorAction SilentlyContinue
    if ($m) { $Porta = [int]$m.Matches.Groups[1].Value }
  }
  if (-not $Porta) { $Porta = 3010 }
}
Ok "porta da ingestao: $Porta"

$cfg = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1
if (-not $cfg) { Erro 'nao encontrei interface de rede com rota padrao.'; exit 1 }

$ip = $cfg.IPv4Address.IPAddress
$prefixo = $cfg.IPv4Address.PrefixLength
# Sub-rede a partir do IP e do prefixo, em vez de assumir /24: numa rede /22 ou
# /16 um /24 chutado deixaria metade das maquinas de fora, e o sintoma seria
# "funciona num PC e no outro nao".
$bytes = ([System.Net.IPAddress]::Parse($ip)).GetAddressBytes()
[Array]::Reverse($bytes)
$ipNum = [System.BitConverter]::ToUInt32($bytes, 0)
$mascara = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $prefixo))
$redeNum = $ipNum -band $mascara
$redeBytes = [System.BitConverter]::GetBytes($redeNum)
[Array]::Reverse($redeBytes)
$rede = "$([System.Net.IPAddress]::new($redeBytes))/$prefixo"

Ok "esta maquina: $ip/$prefixo"
Ok "regra sera limitada a: $rede"

$perfil = (Get-NetConnectionProfile -InterfaceAlias $cfg.InterfaceAlias -ErrorAction SilentlyContinue).NetworkCategory
Info "perfil da rede: $perfil"
if ($perfil -eq 'Public') {
  Aviso 'a rede esta marcada como PUBLICA. O Windows e mais restritivo nela.'
  Aviso 'Se for a rede da empresa, mude para Particular nas configuracoes de rede.'
}

# ---------------------------------------------------------------------------
if ($Remover) {
  Passo 'Removendo a regra'
  try {
    Remove-NetFirewallRule -DisplayName $NOME -ErrorAction Stop
    Ok 'regra removida'
  } catch {
    Info 'nao havia regra para remover'
  }
  exit 0
}

# ---------------------------------------------------------------------------
Passo 'Criando a regra'
# ---------------------------------------------------------------------------
# Remove antes de criar: rodar duas vezes nao pode acumular regra duplicada, e
# uma regra antiga com a sub-rede errada continuaria valendo junto com a nova.
try { Remove-NetFirewallRule -DisplayName $NOME -ErrorAction Stop; Info 'regra anterior removida' } catch { }

New-NetFirewallRule -DisplayName $NOME `
  -Description 'Permite que os agentes de monitoramento das lojas enviem metricas para este servidor.' `
  -Direction Inbound -Protocol TCP -LocalPort $Porta -Action Allow `
  -Profile Any -RemoteAddress $rede | Out-Null

Ok "porta $Porta liberada para $rede"

# ---------------------------------------------------------------------------
Passo 'Conferindo'
# ---------------------------------------------------------------------------
# Criar a regra nao prova que funciona. Estas tres perguntas cobrem as causas
# reais de "Impossivel conectar-se ao servidor remoto".
$falhas = 0

$regra = Get-NetFirewallRule -DisplayName $NOME -ErrorAction SilentlyContinue
if ($regra -and $regra.Enabled -eq 'True') { Ok 'regra existe e esta habilitada' }
else { Erro 'a regra nao ficou habilitada'; $falhas++ }

$escuta = Get-NetTCPConnection -State Listen -LocalPort $Porta -ErrorAction SilentlyContinue
if ($escuta) { Ok "algo esta escutando na porta $Porta" }
else {
  Erro "NADA esta escutando na porta $Porta — a stack esta no ar?"
  Aviso 'Suba com:  .\scripts\dev-up.ps1'
  $falhas++
}

try {
  $h = Invoke-RestMethod -Uri "http://${ip}:$Porta/healthz" -TimeoutSec 10
  if ($h.ok) { Ok "endpoint responde em http://${ip}:$Porta" }
  else { Erro 'endpoint respondeu, mas nao esta saudavel'; $falhas++ }
} catch {
  Erro "endpoint nao respondeu: $($_.Exception.Message)"
  $falhas++
}

Write-Host ''
if ($falhas -gt 0) {
  Write-Host '============================================================' -ForegroundColor Red
  Write-Host " $falhas verificacao(oes) falharam" -ForegroundColor Red
  Write-Host '============================================================' -ForegroundColor Red
  exit 1
}

Write-Host '============================================================' -ForegroundColor Green
Write-Host ' PORTA LIBERADA' -ForegroundColor Green
Write-Host '============================================================' -ForegroundColor Green
Write-Host "  Endereco para os agentes: http://${ip}:$Porta"
Write-Host ''
Write-Host '  TESTE A PARTIR DO OUTRO PC antes de instalar:' -ForegroundColor Cyan
Write-Host "     Invoke-RestMethod 'http://${ip}:$Porta/healthz'" -ForegroundColor DarkGray
Write-Host '  Deve responder:  ok : True'
Write-Host ''
Write-Host '  Se ainda falhar la, o bloqueio nao e deste Windows:' -ForegroundColor Yellow
Write-Host '   - os dois PCs estao na MESMA rede? (compare os IPs)'
Write-Host '   - ha isolamento de clientes no Wi-Fi / VLAN separada?'
Write-Host '   - antivirus com firewall proprio neste servidor?'
Write-Host '============================================================' -ForegroundColor Green
Write-Host ''
