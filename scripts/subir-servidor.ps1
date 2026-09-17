<#
.SYNOPSIS
  Sobe a stack de producao e CONFERE que ela esta servindo. Feito para rodar
  sozinho depois que a maquina reinicia.

.DESCRIPTION
  Este script existe por causa de um incidente concreto: 27 maquinas sumiram do
  monitoramento no mesmo minuto, no fim de um expediente, porque o agente delas
  tinha sido iniciado A MAO e nao havia nada que o trouxesse de volta depois do
  desligamento. Ninguem percebeu por duas semanas -- nao houve erro, so ausencia.
  Repetir esse desenho no SERVIDOR seria criar o mesmo ponto cego uma camada
  acima, e com muito mais consequencia.

  O QUE ELE FAZ, em ordem:

    1. ESPERA o Docker responder. Esta e a parte que nao pode faltar: o Docker
       Desktop leva de 1 a 3 minutos para ficar pronto depois do login, e um
       `compose up` disparado antes disso falha e desiste. Um script de boot que
       nao espera e um script que funciona quando testado a mao e falha no boot
       de verdade.

    2. Sobe a stack.

    3. CONFERE SERVINDO, e nao apenas "container de pe". Container pode estar
       `Up` com a aplicacao quebrada -- aconteceu aqui: o PostgREST caiu por
       credencial e o nginx entrou em laco de reinicio junto. `docker ps` diria
       que estava tudo bem.

    4. Registra tudo num log com data. Se falhar as 3 da manha, ninguem esta
       olhando o console -- e a unica coisa pior que a falha e a falha sem
       rastro.

  TUNEL: se `cloudflared` estiver instalado como SERVICO do Windows, ele sobe
  sozinho no boot e este script apenas confere. Tunel rapido (trycloudflare) NAO
  sobrevive a reinicio, por natureza: e temporario e vive numa janela aberta.
  Enquanto o tunel permanente nao existir, o script avisa em vez de fingir que
  esta tudo resolvido.

.PARAMETER Raiz
  Pasta do projeto. Padrao: a pasta acima deste script.

.PARAMETER ArquivoEnv
  Arquivo de ambiente. Padrao: .env.selfhost

.PARAMETER EsperaDockerSegundos
  Quanto esperar o Docker ficar pronto. Padrao: 300 (5 min).

.PARAMETER Instalar
  Registra este script como tarefa agendada, para rodar sozinho no logon.

.EXAMPLE
  .\scripts\subir-servidor.ps1

.EXAMPLE
  # uma vez so, em terminal ELEVADO:
  .\scripts\subir-servidor.ps1 -Instalar
#>
[CmdletBinding()]
param(
  [string] $Raiz,
  [string] $ArquivoEnv = '.env.selfhost',
  [int]    $EsperaDockerSegundos = 300,
  [switch] $Instalar
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Raiz)) { $Raiz = Split-Path -Parent $PSScriptRoot }
$compose = Join-Path $Raiz 'docker-compose.producao.yml'
$envPath = Join-Path $Raiz $ArquivoEnv
$logDir  = Join-Path $Raiz 'logs'
$log     = Join-Path $logDir 'subir-servidor.log'

if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }

function Registrar {
  param([string] $Nivel, [string] $Texto)
  $linha = '{0} {1} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Nivel, $Texto
  Write-Host $linha
  try { Add-Content -Path $log -Value $linha -Encoding utf8 } catch { }
}

# ---------------------------------------------------------------------------
# -Instalar: registra a tarefa agendada e sai
# ---------------------------------------------------------------------------
if ($Instalar) {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $elevado = ([Security.Principal.WindowsPrincipal]$id).IsInRole(
               [Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $elevado) {
    Registrar 'ERRO' 'PRECISA DE TERMINAL ELEVADO para registrar a tarefa.'
    exit 1
  }

  # AO LOGON, e nao ao boot, e o motivo e uma limitacao real do Windows: o
  # Docker Desktop e um aplicativo de USUARIO, nao um servico. Sem sessao
  # iniciada nao existe engine, e uma tarefa "ao iniciar o sistema" rodaria
  # contra um Docker que nunca vai subir.
  #
  # Para a maquina voltar sozinha sem ninguem digitar senha, isto precisa de
  # logon automatico numa conta dedicada -- e ai a tela deve ser bloqueada em
  # seguida. E o preco de rodar Docker Desktop no Windows; num Linux, ou numa VM
  # Linux dentro desta maquina, o Docker e servico e este problema nao existe.
  $argumento = ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Raiz "{1}" -ArquivoEnv "{2}"' -f `
                $PSCommandPath, $Raiz, $ArquivoEnv)

  $pAcao = @{ Execute = 'powershell.exe'; Argument = $argumento }
  $pCfg = @{
    MultipleInstances          = 'IgnoreNew'
    ExecutionTimeLimit         = ([TimeSpan]::Zero)
    RestartCount               = 3
    RestartInterval            = (New-TimeSpan -Minutes 2)
    AllowStartIfOnBatteries    = $true
    DontStopIfGoingOnBatteries = $true
    StartWhenAvailable         = $true
  }
  $pTarefa = @{
    TaskName  = 'MonitorServidor'
    Action    = (New-ScheduledTaskAction @pAcao)
    Trigger   = (New-ScheduledTaskTrigger -AtLogOn)
    Principal = (New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest)
    Settings  = (New-ScheduledTaskSettingsSet @pCfg)
    Force     = $true
  }
  Register-ScheduledTask @pTarefa | Out-Null
  Registrar 'OK' "tarefa MonitorServidor registrada (ao logon de $env:USERNAME)."
  Registrar 'INF' 'Para voltar SEM ninguem logar, ligue o logon automatico numa conta dedicada.'
  exit 0
}

# ---------------------------------------------------------------------------
# 1. Conferencias basicas
# ---------------------------------------------------------------------------
Registrar 'INF' "iniciando | raiz=$Raiz"

foreach ($f in @($compose, $envPath)) {
  if (-not (Test-Path $f)) {
    Registrar 'ERRO' "nao achei $f"
    exit 1
  }
}

$porta = 8080
foreach ($linha in (Get-Content $envPath)) {
  if ($linha -match '^\s*WEB_PORT\s*=\s*(\d+)') { $porta = [int]$Matches[1] }
}
Registrar 'INF' "porta do painel: $porta"

# ---------------------------------------------------------------------------
# 2. Esperar o Docker
# ---------------------------------------------------------------------------
# NADA DE `2>&1` EM EXECUTAVEL NATIVO AQUI.
#
# No PowerShell 5.1, redirecionar o stderr de um .exe embrulha cada linha num
# ErrorRecord -- e com ErrorActionPreference = 'Stop' isso vira erro FATAL mesmo
# quando o comando terminou com sucesso. O docker escreve rotina no stderr, entao
# o script morria logo depois de "Docker respondendo", sem explicar nada.
#
# Quem decide sucesso aqui e o $LASTEXITCODE, que e o unico sinal confiavel de
# comando nativo.
$eapAntes = $ErrorActionPreference
$ErrorActionPreference = 'Continue'

$prazo = (Get-Date).AddSeconds($EsperaDockerSegundos)
$pronto = $false
while ((Get-Date) -lt $prazo) {
  docker info | Out-Null
  if ($LASTEXITCODE -eq 0) { $pronto = $true; break }
  Start-Sleep -Seconds 5
}

if (-not $pronto) {
  Registrar 'ERRO' "Docker nao respondeu em $EsperaDockerSegundos s. A stack NAO subiu."
  Registrar 'ERRO' 'Se isto acontece sempre no boot: o Docker Desktop so sobe com usuario logado.'
  exit 1
}
Registrar 'OK' 'Docker respondendo.'

# ---------------------------------------------------------------------------
# 3. Subir
# ---------------------------------------------------------------------------
Push-Location $Raiz
try {
  $saida = docker compose -f $compose --env-file $envPath up -d
  foreach ($l in @($saida)) { if ($l) { Registrar 'INF' $l } }
  if ($LASTEXITCODE -ne 0) {
    Registrar 'ERRO' "compose up falhou (codigo $LASTEXITCODE)."
    $ErrorActionPreference = $eapAntes
    exit 1
  }
} finally { Pop-Location }

$ErrorActionPreference = $eapAntes

# ---------------------------------------------------------------------------
# 4. Conferir SERVINDO, nao apenas "de pe"
# ---------------------------------------------------------------------------
# Container pode estar Up com a aplicacao quebrada. O que importa e a resposta.
$alvos = @(
  @{ nome = 'ingestao'; url = "http://127.0.0.1:$porta/functions/v1/ingest/healthz" },
  @{ nome = 'painel';   url = "http://127.0.0.1:$porta/" }
)

$prazo = (Get-Date).AddSeconds(120)
$faltando = @($alvos)

while ((Get-Date) -lt $prazo -and $faltando.Count -gt 0) {
  $ainda = @()
  foreach ($a in $faltando) {
    try {
      $r = Invoke-WebRequest -Uri $a.url -TimeoutSec 8 -UseBasicParsing
      Registrar 'OK' ("{0}: HTTP {1}" -f $a.nome, $r.StatusCode)
    } catch {
      $ainda += $a
    }
  }
  $faltando = $ainda
  if ($faltando.Count -gt 0) { Start-Sleep -Seconds 5 }
}

foreach ($a in $faltando) { Registrar 'ERRO' ("{0} NAO respondeu: {1}" -f $a.nome, $a.url) }

# ---------------------------------------------------------------------------
# 5. O tunel
# ---------------------------------------------------------------------------
# Em 17/09 o tunel passou a ser o Funnel do Tailscale, e nao mais a Cloudflare.
# O motivo nao foi preferencia: tunel rapido (trycloudflare) sorteia hostname
# novo a cada partida, e tunel NOMEADO exige um dominio dentro da conta
# Cloudflare -- comprar dominio e mexer no DNS do cajupar.com foram os dois
# recusados. Ver scripts\tunel-tailscale.ps1.
#
# A diferenca que importa aqui: o tailscaled e servico de verdade e sobe ANTES
# do login, entao o ENDERECO volta sozinho depois do reboot. A stack atras dele
# nao -- o Docker Desktop continua sendo aplicativo de usuario. Enquanto for
# assim, reboot sem ninguem logar = endereco de pe respondendo 502.
$svc = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
if ($null -eq $svc) { $svc = Get-Service -Name 'tailscaled' -ErrorAction SilentlyContinue }

if ($null -eq $svc) {
  Registrar 'AVI' 'Tailscale NAO esta instalado como servico: o endereco publico NAO volta sozinho.'
  Registrar 'AVI' 'Rode uma vez:  .\scripts\tunel-tailscale.ps1 -Instalar'
} elseif ($svc.Status -ne 'Running') {
  Registrar 'AVI' "servico $($svc.Name) existe mas esta $($svc.Status). Tentando iniciar."
  try { Start-Service $svc.Name; Registrar 'OK' 'Tailscale iniciado.' }
  catch { Registrar 'ERRO' "nao consegui iniciar o Tailscale: $($_.Exception.Message)" }
} else {
  Registrar 'OK' 'Tailscale rodando como servico.'
}

# Servico de pe nao quer dizer endereco publicado: o Funnel e configuracao
# separada, e ja aconteceu neste projeto de "container Up" nao significar
# "aplicacao servindo". Aqui a conferencia e a mesma ideia.
$ts = (Get-Command tailscale -ErrorAction SilentlyContinue).Source
if (-not $ts) {
  $p = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
  if (Test-Path $p) { $ts = $p }
}

if ($ts) {
  $eapTunel = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $funnel = & $ts funnel status
  $ErrorActionPreference = $eapTunel

  $texto = ($funnel | Out-String)
  if ($LASTEXITCODE -eq 0 -and $texto -match 'https://') {
    foreach ($l in ($texto -split "`r?`n")) {
      if ($l -match 'https://\S+') { Registrar 'OK' ("Funnel: " + $Matches[0]) ; break }
    }
  } else {
    Registrar 'AVI' 'Funnel NAO esta publicando. O endereco publico esta fora.'
    Registrar 'AVI' 'Rode:  .\scripts\tunel-tailscale.ps1'
  }
}

if ($faltando.Count -gt 0) {
  Registrar 'ERRO' 'TERMINOU COM FALHA.'
  exit 1
}

Registrar 'OK' 'servidor no ar.'
exit 0
