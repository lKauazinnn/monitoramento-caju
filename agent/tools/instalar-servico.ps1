<#
.SYNOPSIS
  Publica e instala o MonitorAgent como servico do Windows.

.DESCRIPTION
  Exige terminal ELEVADO.

  Publica self-contained: a maquina alvo nao precisa ter runtime .NET instalado.
  Num parque de dezenas de lojas, depender de runtime pre-instalado significa
  descobrir na hora da instalacao que 30% das maquinas nao tem.

  ANTES DE USAR: rode .\verificar-app-control.ps1 na maquina alvo. Se o Smart
  App Control estiver em imposicao, o servico instala e FALHA AO INICIAR com
  0x800711C7 — e nenhuma permissao de pasta resolve.

.PARAMETER ConfigPath
  config.json gerado por provision-machine.ps1. Copiado para %ProgramData%.

.PARAMETER InstallDir
  Destino do binario. Padrao: %ProgramFiles%\MonitorAgent

.PARAMETER SkipPublish
  Usa o conteudo de PublishDir sem republicar (para implantacao em massa a
  partir de um build unico).

.PARAMETER PublishDir
  Origem dos binarios quando -SkipPublish. Padrao: .\publish

.EXAMPLE
  .\agent\tools\instalar-servico.ps1 -ConfigPath C:\temp\config-pdv01.json

.EXAMPLE
  # Build uma vez, instala em muitas maquinas a partir de um compartilhamento
  .\agent\tools\instalar-servico.ps1 -SkipPublish -PublishDir \\srv\deploy\monitoragent -ConfigPath C:\temp\config.json
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string] $ConfigPath,
  [string] $InstallDir = (Join-Path $env:ProgramFiles 'MonitorAgent'),
  [switch] $SkipPublish,
  [string] $PublishDir = ''
)

$ErrorActionPreference = 'Stop'

$ehAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $ehAdmin) {
  Write-Host 'Este script exige terminal ELEVADO (Executar como administrador).' -ForegroundColor Red
  exit 1
}

if (-not (Test-Path $ConfigPath)) {
  Write-Host "config.json nao encontrado: $ConfigPath" -ForegroundColor Red
  Write-Host 'Gere com: .\scripts\provision-machine.ps1 ... -OutConfig <caminho>' -ForegroundColor Yellow
  exit 1
}

$ServiceName = 'MonitorAgent'
$dataDir = Join-Path $env:ProgramData 'MonitorAgent'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== 1. Verificando Controle de Aplicativo ==' -ForegroundColor Cyan
# ---------------------------------------------------------------------------
$verificador = Join-Path $PSScriptRoot 'verificar-app-control.ps1'
if (Test-Path $verificador) {
  & $verificador | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host 'AVISO: esta maquina tem Smart App Control ou WDAC em imposicao.' -ForegroundColor Yellow
    Write-Host 'O servico vai instalar e FALHAR AO INICIAR (0x800711C7) sem' -ForegroundColor Yellow
    Write-Host 'assinatura reputavel. Detalhes: .\verificar-app-control.ps1' -ForegroundColor Yellow
    Write-Host ''
    $r = Read-Host 'Continuar mesmo assim? (s/N)'
    if ($r -ne 's') { exit 1 }
  } else {
    Write-Host '  livre para executar binario nao assinado' -ForegroundColor Green
  }
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== 2. Publicando ==' -ForegroundColor Cyan
# ---------------------------------------------------------------------------
if ($SkipPublish) {
  if ([string]::IsNullOrWhiteSpace($PublishDir)) { $PublishDir = Join-Path $repoRoot 'publish' }
  if (-not (Test-Path (Join-Path $PublishDir 'MonitorAgent.exe'))) {
    Write-Host "MonitorAgent.exe nao encontrado em $PublishDir" -ForegroundColor Red
    exit 1
  }
  Write-Host "  usando build existente: $PublishDir"
} else {
  $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
  if ($null -eq $dotnet) {
    $candidato = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
    if (Test-Path $candidato) { $dotnet = @{ Source = $candidato } }
  }
  if ($null -eq $dotnet) {
    Write-Host 'dotnet nao encontrado. Instale o SDK 8 ou use -SkipPublish.' -ForegroundColor Red
    exit 1
  }

  $PublishDir = Join-Path $repoRoot 'publish'
  $csproj = Join-Path $repoRoot 'src\MonitorAgent\MonitorAgent.csproj'

  # Self-contained: nao depende de runtime na maquina alvo.
  # PublishSingleFile=false de proposito: arquivo unico extrai para temp a cada
  # partida, o que atrasa o start do servico e complica a auto-atualizacao.
  & $dotnet.Source publish $csproj `
      --configuration Release `
      --runtime win-x64 `
      --self-contained true `
      --output $PublishDir `
      -p:PublishSingleFile=false `
      -p:DebugType=none

  if ($LASTEXITCODE -ne 0) { Write-Host 'publish falhou' -ForegroundColor Red; exit 1 }
  Write-Host "  publicado em $PublishDir" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== 3. Parando servico anterior, se existir ==' -ForegroundColor Cyan
# ---------------------------------------------------------------------------
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
  if ($svc.Status -ne 'Stopped') {
    Write-Host '  parando...'
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    # Espera o processo liberar os binarios antes de sobrescrever.
    for ($i = 0; $i -lt 30; $i++) {
      if ((Get-Service -Name $ServiceName).Status -eq 'Stopped') { break }
      Start-Sleep -Milliseconds 500
    }
  }
  Write-Host '  servico existente sera atualizado no lugar'
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== 4. Copiando binarios e configuracao ==' -ForegroundColor Cyan
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item (Join-Path $PublishDir '*') $InstallDir -Recurse -Force
Write-Host "  binarios em $InstallDir"

New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $dataDir 'logs') | Out-Null

$destinoConfig = Join-Path $dataDir 'config.json'
if (Test-Path $destinoConfig) {
  $backup = "$destinoConfig.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
  Copy-Item $destinoConfig $backup
  Write-Host "  config anterior preservado em $backup" -ForegroundColor DarkGray
}
Copy-Item $ConfigPath $destinoConfig -Force
Write-Host "  configuracao em $destinoConfig"

# O config.json contem o token em texto claro: so SYSTEM e Administradores.
# Sem isto, qualquer usuario logado no PDV pode ler a credencial da maquina.
icacls $dataDir /inheritance:r /grant 'SYSTEM:(OI)(CI)F' 'Administradores:(OI)(CI)F' /T /Q 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  # Windows em ingles usa "Administrators".
  icacls $dataDir /inheritance:r /grant 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' /T /Q 2>$null | Out-Null
}
Write-Host '  permissoes restritas a SYSTEM e Administradores' -ForegroundColor Green

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== 5. Registrando origem no Log de Eventos ==' -ForegroundColor Cyan
# ---------------------------------------------------------------------------
# Feito aqui porque exige elevacao: o servico rodando como LocalSystem tem
# privilegio, mas criar a origem na primeira execucao seria uma corrida.
if (-not [System.Diagnostics.EventLog]::SourceExists($ServiceName)) {
  New-EventLog -LogName Application -Source $ServiceName
  Write-Host '  origem criada' -ForegroundColor Green
} else {
  Write-Host '  origem ja existia'
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== 6. Criando/atualizando o servico ==' -ForegroundColor Cyan
# ---------------------------------------------------------------------------
$exe = Join-Path $InstallDir 'MonitorAgent.exe'

if ($svc) {
  sc.exe config $ServiceName binPath= "`"$exe`"" start= delayed-auto | Out-Null
} else {
  # delayed-auto: o PDV nao disputa CPU e rede com o software de venda durante o
  # boot, que e exatamente quando o operador esta esperando para abrir o caixa.
  sc.exe create $ServiceName binPath= "`"$exe`"" start= delayed-auto obj= 'LocalSystem' DisplayName= 'Monitor de Infraestrutura' | Out-Null
  if ($LASTEXITCODE -ne 0) { Write-Host 'sc create falhou' -ForegroundColor Red; exit 1 }
}

sc.exe description $ServiceName 'Coleta metricas de CPU, memoria, disco, temperatura e servicos criticos e envia para a central de monitoramento.' | Out-Null

# Reinicio automatico: 5s, 30s, 2min; contador zera depois de 1 dia. Um agente
# que morre e nao volta e pior que agente nenhum, porque a maquina aparece
# offline e a TI vai procurar problema de rede.
sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/30000/restart/120000 | Out-Null

Write-Host '  servico configurado (inicio automatico atrasado, reinicio em falha)' -ForegroundColor Green

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== 7. Iniciando ==' -ForegroundColor Cyan
# ---------------------------------------------------------------------------
try {
  Start-Service -Name $ServiceName -ErrorAction Stop
  Start-Sleep -Seconds 3
  $st = (Get-Service -Name $ServiceName).Status
  Write-Host "  status: $st" -ForegroundColor $(if ($st -eq 'Running') { 'Green' } else { 'Red' })
} catch {
  Write-Host "  FALHOU ao iniciar: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host ''
  Write-Host '  Diagnostico:' -ForegroundColor Yellow
  Write-Host "   1. Log do agente : $dataDir\logs\agent.log"
  Write-Host '   2. Log de Eventos: Get-EventLog -LogName Application -Source MonitorAgent -Newest 5'
  Write-Host "   3. Config        : & '$exe' --check"
  Write-Host ''
  Write-Host '  Se o erro mencionar 0x800711C7 ou "politica de Controle de Aplicativo",'
  Write-Host '  o problema e Smart App Control. Rode .\verificar-app-control.ps1'
  exit 1
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Green
Write-Host ' INSTALADO' -ForegroundColor Green
Write-Host '============================================================' -ForegroundColor Green
Write-Host "  binarios : $InstallDir"
Write-Host "  dados    : $dataDir"
Write-Host "  logs     : $dataDir\logs\agent.log"
Write-Host ''
Write-Host '  Verificar:'
Write-Host "    & '$exe' --check"
Write-Host "    Get-Content '$dataDir\logs\agent.log' -Tail 30 -Wait"
Write-Host ''
Write-Host '  Desinstalar:'
Write-Host "    Stop-Service $ServiceName; sc.exe delete $ServiceName"
Write-Host ''
