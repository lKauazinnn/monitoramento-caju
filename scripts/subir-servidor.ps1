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
$compose    = Join-Path $Raiz 'docker-compose.producao.yml'
$composeTls = Join-Path $Raiz 'docker-compose.tls.yml'
$envPath    = Join-Path $Raiz $ArquivoEnv
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

$porta   = 8080
$dominio = $null
foreach ($linha in (Get-Content $envPath)) {
  if ($linha -match '^\s*WEB_PORT\s*=\s*(\d+)')          { $porta   = [int]$Matches[1] }
  if ($linha -match '^\s*DOMINIO_PUBLICO\s*=\s*(.+?)\s*$') { $dominio = $Matches[1] }
}
Registrar 'INF' "porta do painel: $porta"

# A camada de HTTPS so entra se as DUAS coisas existirem: o arquivo e o dominio.
# Com o arquivo e sem o dominio, o compose aborta inteiro na variavel obrigatoria
# -- e levaria a stack junto, que nao tem nada a ver com isso.
$usarTls = (Test-Path $composeTls) -and -not [string]::IsNullOrWhiteSpace($dominio)
if ($usarTls) { Registrar 'INF' "camada de HTTPS ligada para $dominio" }
elseif (Test-Path $composeTls) { Registrar 'AVI' 'docker-compose.tls.yml existe mas falta DOMINIO_PUBLICO no ambiente: subindo SEM HTTPS.' }

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
  $argsCompose = @('compose', '-f', $compose)
  if ($usarTls) { $argsCompose += @('-f', $composeTls) }
  $argsCompose += @('--env-file', $envPath, 'up', '-d')
  $saida = docker @argsCompose
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
# Em 17/09 o caminho deixou de ser tunel. O endereco publico virou um hostname
# do DuckDNS apontando para o IP desta rede, com o roteador encaminhando 80 e
# 443 para esta maquina, e o Caddy terminando o HTTPS (docker-compose.tls.yml).
#
# Por que nao tunel: o rapido da Cloudflare sorteia hostname a cada partida; o
# nomeado exige dominio dentro da conta Cloudflare, que foi recusado; e o Funnel
# do Tailscale so segue gratuito num plano que a propria Tailscale descreve como
# de uso pessoal. Ver scripts\duckdns.ps1.
#
# Quem mantem o DNS em dia e a tarefa MonitorDuckDNS, rodando como SYSTEM: ela
# volta sozinha na partida, sem ninguem logar. Aqui so se CONFERE.
if ([string]::IsNullOrWhiteSpace($dominio)) {
  Registrar 'AVI' 'sem DOMINIO_PUBLICO no ambiente: a stack esta so em 127.0.0.1.'
  Registrar 'AVI' 'Rode uma vez:  .\scripts\duckdns.ps1 -Instalar'
} else {
  $tarefa = Get-ScheduledTask -TaskName 'MonitorDuckDNS' -ErrorAction SilentlyContinue
  if ($null -eq $tarefa) {
    Registrar 'AVI' 'tarefa MonitorDuckDNS nao registrada: se o IP mudar, o endereco morre.'
    Registrar 'AVI' 'Rode:  .\scripts\duckdns.ps1 -Instalar   (elevado)'
  } else {
    Registrar 'OK' "tarefa MonitorDuckDNS registrada ($($tarefa.State))."
  }

  # Container de pe nao prova HTTPS servindo -- mesma licao do PostgREST que
  # subiu quebrado com o container Up. Mas ATENCAO ao resultado: muitos
  # roteadores nao devolvem para dentro uma conexao feita ao proprio IP publico
  # (hairpin). Falhar AQUI, de dentro da rede, nao prova que esta fora do ar --
  # por isso e AVI e nao ERRO, e por isso o teste que vale e o do celular.
  $urlPublica = "https://$dominio/functions/v1/ingest/healthz"
  try {
    $rp = Invoke-WebRequest -Uri $urlPublica -TimeoutSec 20 -UseBasicParsing
    Registrar 'OK' ("endereco publico: HTTP {0}" -f [int]$rp.StatusCode)
  } catch {
    $cod = 0
    if ($_.Exception.Response) { $cod = [int]$_.Exception.Response.StatusCode }
    if ($cod -ge 500) {
      Registrar 'AVI' "o HTTPS responde mas a stack atras dele falhou (HTTP $cod)."
    } else {
      Registrar 'AVI' "sem resposta em $urlPublica -- pode ser hairpin do roteador."
      Registrar 'AVI' 'Confirme pelo celular, com dados moveis, antes de concluir que esta fora.'
    }
  }
}

if ($faltando.Count -gt 0) {
  Registrar 'ERRO' 'TERMINOU COM FALHA.'
  exit 1
}

Registrar 'OK' 'servidor no ar.'
exit 0
