<#
.SYNOPSIS
  Mantem o endereco publico do DuckDNS apontando para o IP desta rede, e prepara
  a maquina para receber o encaminhamento do roteador. Roda NA MAQUINA SERVIDORA.

.DESCRIPTION
  O QUE ESTE CAMINHO E, EM UMA FRASE

    Em vez de alugar um tunel de terceiro, o endereco publico passa a ser um
    hostname gratuito do DuckDNS apontando para o IP desta rede, e o trafego
    entra pelo link da propria empresa. Custo zero e sem teto de trafego -- o que
    importa aqui, porque 45 agentes a 4 requisicoes por minuto dao ~7,8 milhoes
    de chamadas e uns 15 GB por mes. Foi essa conta que estourou o Supabase, e e
    ela que elimina os planos gratuitos com franquia.

  O QUE ELE EXIGE, E NAO DA PARA CONTORNAR

    1. O roteador precisa encaminhar TCP 443 de FORA para 192.168.14.56 na
       porta 2222. As portas sao diferentes dos dois lados de proposito: a 80 e
       a 443 desta maquina ja tem dono, e a publica TEM de ser a 443, porque o
       Let's Encrypt so valida certificado na 80 (HTTP-01) ou na 443
       (TLS-ALPN-01). Endereco publico numa porta 2222 nunca receberia
       certificado -- e o agente recusa endereco sem HTTPS.

    2. O link precisa ter IP publico de verdade. Se o roteador mostrar WAN na
       faixa 100.64.x.x ate 100.127.x.x, o IP e compartilhado pela operadora
       (CGNAT) e NENHUM encaminhamento funciona -- nem aqui, nem com outro
       provedor de DNS. Nesse caso o caminho e tunel, e nao ha meio-termo.

  O QUE ESTE SCRIPT FAZ

    - atualiza o registro agora e CONFERE lendo de um DNS publico, nao do cache
      desta maquina;
    - registra a atualizacao como tarefa do Windows rodando como SYSTEM, a cada
      5 minutos e tambem na partida. Como SYSTEM, ela nao depende de ninguem
      logar -- ao contrario do Docker, que continua dependendo;
    - libera as portas 80 e 443 no firewall do Windows.

  O TOKEN nunca entra em linha de comando nem aparece no log: ele e digitado
  escondido e guardado no .env.selfhost, que ja e o arquivo de segredos desta
  maquina e ja esta fora do git.

.PARAMETER Instalar
  Registra a tarefa agendada e libera o firewall. Precisa de terminal ELEVADO.

.PARAMETER Conferir
  So mede e relata. Nao atualiza, nao instala, nao muda nada.

.EXAMPLE
  .\scripts\duckdns.ps1

.EXAMPLE
  .\scripts\duckdns.ps1 -Instalar
#>
[CmdletBinding()]
param(
  [switch] $Instalar,
  [switch] $Conferir,
  [string] $Raiz
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Raiz)) { $Raiz = Split-Path -Parent $PSScriptRoot }

$envPath = Join-Path $Raiz '.env.selfhost'
$logDir  = Join-Path $Raiz 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$log = Join-Path $logDir 'duckdns.log'

function Registrar {
  param([string] $Nivel, [string] $Texto)
  $linha = '{0} {1} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Nivel, $Texto
  $cor = switch ($Nivel) { 'ERRO' { 'Red' } 'AVI' { 'Yellow' } 'OK' { 'Green' } default { 'Gray' } }
  Write-Host $linha -ForegroundColor $cor
  try { Add-Content -Path $log -Value $linha -Encoding utf8 } catch { }
}

# ---------------------------------------------------------------------------
# Ler o .env.selfhost sem interpretar nada alem do que interessa
# ---------------------------------------------------------------------------
function LerEnv([string] $chave) {
  if (-not (Test-Path $envPath)) { return $null }
  foreach ($linha in (Get-Content $envPath)) {
    if ($linha -match "^\s*$chave\s*=\s*(.+?)\s*$") { return $Matches[1] }
  }
  return $null
}

# Append SEM BOM, de proposito. Set-Content/Add-Content do PowerShell 5.1 podem
# escrever BOM, e um BOM no meio de um arquivo .env vira parte do NOME da
# variavel seguinte -- o docker compose passa a nao enxergar a variavel, e o
# sintoma e "defina DOMINIO_PUBLICO" mesmo com a linha visivelmente la.
function GravarEnv([string] $chave, [string] $valor) {
  $utf8SemBom = New-Object System.Text.UTF8Encoding($false)
  $texto = ''
  if (Test-Path $envPath) {
    $texto = [System.IO.File]::ReadAllText($envPath, $utf8SemBom)
    if ($texto.Length -gt 0 -and -not $texto.EndsWith("`n")) { $texto += "`r`n" }
  }
  $texto += ('{0}={1}{2}' -f $chave, $valor, "`r`n")
  [System.IO.File]::WriteAllText($envPath, $texto, $utf8SemBom)
}

# ---------------------------------------------------------------------------
# 1. Subdominio e token
# ---------------------------------------------------------------------------
$sub = LerEnv 'DUCKDNS_SUB'
if ([string]::IsNullOrWhiteSpace($sub)) {
  if ($Conferir) { Registrar 'ERRO' 'DUCKDNS_SUB nao esta no .env.selfhost.'; exit 1 }
  Write-Host ''
  Write-Host 'Crie o subdominio em https://www.duckdns.org (entrar com GitHub/Google).' -ForegroundColor Cyan
  Write-Host 'Informe SO o nome, sem .duckdns.org -- exemplo: cajupar-monitor' -ForegroundColor Cyan
  $sub = (Read-Host -Prompt 'Subdominio DuckDNS').Trim()
  if ([string]::IsNullOrWhiteSpace($sub)) { Registrar 'ERRO' 'subdominio vazio.'; exit 1 }
  $sub = $sub -replace '\.duckdns\.org$', ''
  GravarEnv 'DUCKDNS_SUB' $sub
  GravarEnv 'DOMINIO_PUBLICO' "$sub.duckdns.org"
  Registrar 'OK' "DUCKDNS_SUB e DOMINIO_PUBLICO gravados no .env.selfhost."
}

$dominio = LerEnv 'DOMINIO_PUBLICO'
if ([string]::IsNullOrWhiteSpace($dominio)) {
  $dominio = "$sub.duckdns.org"
  GravarEnv 'DOMINIO_PUBLICO' $dominio
}
Registrar 'INF' "endereco publico: $dominio"

$token = LerEnv 'DUCKDNS_TOKEN'
if ([string]::IsNullOrWhiteSpace($token) -and -not $Conferir) {
  Write-Host ''
  Write-Host 'O token aparece no topo da pagina do DuckDNS, depois de entrar.' -ForegroundColor Cyan
  $seguro = Read-Host -Prompt 'Token do DuckDNS' -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($seguro)
  try { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
  if ([string]::IsNullOrWhiteSpace($token)) { Registrar 'ERRO' 'token vazio.'; exit 1 }
  GravarEnv 'DUCKDNS_TOKEN' $token
  Registrar 'OK' 'token guardado no .env.selfhost (fora do git).'
}

# ---------------------------------------------------------------------------
# 2. Atualizar o registro
# ---------------------------------------------------------------------------
# Sem o parametro ip: o DuckDNS usa o IP de quem chamou, que e exatamente o IP
# publico desta rede. Assim funciona igual com IP fixo ou dinamico.
if (-not $Conferir) {
  if ([string]::IsNullOrWhiteSpace($token)) { Registrar 'ERRO' 'sem DUCKDNS_TOKEN.'; exit 1 }
  try {
    $r = Invoke-RestMethod -Uri "https://www.duckdns.org/update?domains=$sub&token=$token" -TimeoutSec 20
    if ("$r".Trim() -eq 'OK') { Registrar 'OK' 'DuckDNS aceitou a atualizacao.' }
    else { Registrar 'ERRO' "DuckDNS respondeu '$r' (KO = subdominio ou token errado)."; exit 1 }
  } catch {
    Registrar 'ERRO' "nao consegui falar com o DuckDNS: $($_.Exception.Message)"
    exit 1
  }
}

# ---------------------------------------------------------------------------
# 3. Conferir no DNS PUBLICO, e nao no cache desta maquina
# ---------------------------------------------------------------------------
$ipPublico = $null
try { $ipPublico = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 15).Trim() } catch { }
if ($ipPublico) { Registrar 'INF' "IP publico desta rede: $ipPublico" }
else { Registrar 'AVI' 'nao consegui descobrir o IP publico.' }

$ipDns = $null
try {
  $resp = Resolve-DnsName -Name $dominio -Type A -Server '1.1.1.1' -ErrorAction Stop
  $ipDns = ($resp | Where-Object { $_.IPAddress } | Select-Object -First 1).IPAddress
} catch { }

if ($ipDns) {
  if ($ipPublico -and $ipDns -eq $ipPublico) {
    Registrar 'OK' "$dominio -> $ipDns (bate com o IP desta rede)."
  } else {
    Registrar 'AVI' "$dominio -> $ipDns, mas o IP desta rede e $ipPublico."
    Registrar 'AVI' 'Propagacao leva ate uns minutos. Se persistir, o token e de outro subdominio.'
  }
} else {
  Registrar 'ERRO' "o DNS publico ainda nao responde por $dominio."
}

# CGNAT: o teste que decide se este caminho existe. Faixa 100.64.0.0/10 e IP
# compartilhado pela operadora -- encaminhamento de porta nao funciona, e
# nenhuma configuracao daqui muda isso.
if ($ipPublico -match '^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.') {
  Registrar 'ERRO' 'IP na faixa de CGNAT: o link nao aceita encaminhamento de porta.'
  Registrar 'ERRO' 'Este caminho nao funciona neste link. Peca IP publico a operadora ou volte para tunel.'
}

# ---------------------------------------------------------------------------
# 4. Instalar: tarefa agendada e firewall
# ---------------------------------------------------------------------------
if ($Instalar) {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $elevado = ([Security.Principal.WindowsPrincipal]$id).IsInRole(
               [Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $elevado) {
    Registrar 'ERRO' 'PRECISA DE TERMINAL ELEVADO para -Instalar.'
    exit 1
  }

  # SYSTEM, e nao o usuario: esta tarefa e a unica peca do conjunto que NAO
  # depende de alguem logar na maquina. O Docker depende; o DNS nao precisa
  # depender tambem.
  $argumento = ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Raiz "{1}"' -f `
                $PSCommandPath, $Raiz)

  $gatilhoBoot = New-ScheduledTaskTrigger -AtStartup
  $gatilhoLoop = New-ScheduledTaskTrigger -Daily -At '00:00'
  $gatilhoLoop.Repetition = (New-ScheduledTaskTrigger -Once -At '00:00' `
                              -RepetitionInterval (New-TimeSpan -Minutes 5) `
                              -RepetitionDuration (New-TimeSpan -Hours 24)).Repetition

  $pTarefa = @{
    TaskName  = 'MonitorDuckDNS'
    Action    = (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argumento)
    Trigger   = @($gatilhoBoot, $gatilhoLoop)
    Principal = (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest)
    Settings  = (New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
                   -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries)
    Force     = $true
  }
  Register-ScheduledTask @pTarefa | Out-Null
  Registrar 'OK' 'tarefa MonitorDuckDNS registrada (na partida e a cada 5 min, como SYSTEM).'

  # SO a 443. A 80 saiu do desenho em 17/09: ela ja tem dono nesta maquina, e o
  # certificado passou a sair pelo desafio TLS-ALPN-01, que acontece dentro da
  # propria conexao 443. Menos uma porta aberta e menos uma coisa exposta.
  $nome = 'Monitor publico 443'
  $existe = Get-NetFirewallRule -DisplayName $nome -ErrorAction SilentlyContinue
  if ($existe) {
    Registrar 'INF' "regra de firewall '$nome' ja existe."
  } else {
    New-NetFirewallRule -DisplayName $nome -Direction Inbound -Protocol TCP `
      -LocalPort 443 -Action Allow -Profile Any | Out-Null
    Registrar 'OK' 'firewall liberado na porta 443.'
  }

  # Limpa a regra da 80 que uma execucao anterior deste script criou. Regra de
  # firewall aberta para uma porta que ninguem usa e superficie exposta a troco
  # de nada.
  $regra80 = Get-NetFirewallRule -DisplayName 'Monitor publico 80' -ErrorAction SilentlyContinue
  if ($regra80) {
    Remove-NetFirewallRule -DisplayName 'Monitor publico 80'
    Registrar 'OK' 'regra da porta 80 removida: nao e mais usada.'
  }
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host " ENDERECO PUBLICO:  https://$dominio" -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host ' O DNS ja aponta para ca. Falta o que NAO se resolve por script:' -ForegroundColor Yellow
Write-Host '   no roteador: TCP 443 de FORA  ->  192.168.14.56 porta 2222'
Write-Host '   (a porta publica tem de ser 443: e nela que o certificado e validado)'
Write-Host ''
Write-Host ' E o teste que vale: abrir https://' -NoNewline; Write-Host $dominio -NoNewline
Write-Host ' no CELULAR, com dados moveis.'
Write-Host ' De dentro da rede o teste engana: muitos roteadores nao devolvem'
Write-Host ' a propria conexao para dentro, e o resultado nao significa nada.'
exit 0
