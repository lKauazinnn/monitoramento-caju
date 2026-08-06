<#
  Instalador do agente de monitoramento — baixado e executado em UMA linha.

  Servido pelo proprio endpoint de ingestao, e o dashboard monta o comando com o
  token da maquina ja preenchido. O objetivo e nao precisar copiar pasta nenhuma:
  no PC novo, cola uma linha no PowerShell e acabou.

  O comando que o dashboard gera tem esta forma:

    & ([scriptblock]::Create((irm 'http://SERVIDOR:PORTA/instalar.ps1'))) `
        -Servidor 'http://SERVIDOR:PORTA' -Token 'mon_...' -Segredo '...'

  scriptblock::Create em vez de `iex` direto porque so assim da para PASSAR
  ARGUMENTOS para um script baixado — com `iex` os parametros seriam ignorados em
  silencio e o instalador rodaria sem token.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string] $Servidor,
  [Parameter(Mandatory = $true)][string] $Token,
  [Parameter(Mandatory = $true)][string] $Segredo,

  [int]      $IntervaloSegundos = 60,
  [string[]] $Servicos = @(),

  # Registra tarefa agendada para o agente voltar sozinho apos reiniciar. Exige
  # terminal ELEVADO — e, rodando como SYSTEM, temperatura e SMART tambem passam
  # a ser coletados.
  [switch]   $ComTarefa,

  [switch]   $Parar
)

$ErrorActionPreference = 'Stop'

# TLS 1.2/1.3 antes de qualquer requisicao. O PowerShell 5.1 herda o padrao do
# .NET Framework, que em Windows sem atualizacao ainda negocia SSL3/TLS 1.0, e o
# Supabase recusa. Sem isto o instalador falharia ja no /healthz com "a conexao
# subjacente foi fechada" — mensagem que joga o diagnostico para firewall e
# certificado, quando o problema e a versao do protocolo.
foreach ($nome in @('Tls12', 'Tls13')) {
  try {
    $valor = [Enum]::Parse([Net.SecurityProtocolType], $nome)
    [Net.ServicePointManager]::SecurityProtocol =
      [Net.ServicePointManager]::SecurityProtocol -bor $valor
  } catch { }
}

$dirDados = Join-Path $env:ProgramData 'MonitorAgent'
$pidFile = Join-Path $dirDados 'agente.pid'
$agentePath = Join-Path $dirDados 'agente-powershell.ps1'
$configPath = Join-Path $dirDados 'config.json'

function Passo { param([string]$T) Write-Host ''; Write-Host "== $T ==" -ForegroundColor Cyan }
function Ok    { param([string]$T) Write-Host "   $T" -ForegroundColor Green }
function Info  { param([string]$T) Write-Host "   $T" -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
if ($Parar) {
  if (Test-Path $pidFile) {
    try { Stop-Process -Id ([int](Get-Content $pidFile)) -Force -ErrorAction Stop; Ok 'agente encerrado' }
    catch { Info 'agente nao estava rodando' }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
  } else { Info 'nenhum agente registrado' }
  try { Unregister-ScheduledTask -TaskName 'MonitorAgent' -Confirm:$false -ErrorAction Stop; Ok 'tarefa agendada removida' } catch { }
  exit 0
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host " Instalando o agente de monitoramento em $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan

$Servidor = $Servidor.TrimEnd('/')

# ---------------------------------------------------------------------------
Passo 'Testando a conexao com o servidor'
# ---------------------------------------------------------------------------
# ANTES de instalar qualquer coisa. Descobrir aqui que o firewall bloqueia e muito
# melhor que instalar, subir o agente e ele ficar mudo sem ninguem saber.
try {
  $h = Invoke-RestMethod -Uri "$Servidor/healthz" -TimeoutSec 10
  if (-not $h.ok) { throw 'servidor respondeu, mas nao esta saudavel' }
  Ok "servidor respondeu: $Servidor"
} catch {
  Write-Host ''
  Write-Host "   NAO CONSEGUI FALAR COM $Servidor" -ForegroundColor Red
  Write-Host "   $($_.Exception.Message)" -ForegroundColor Red
  Write-Host ''

  # As duas situacoes pedem verificacoes OPOSTAS, e dar a lista errada custa
  # horas: numa loja remota nao existe "libere a porta no servidor", e na LAN nao
  # existe problema de DNS publico.
  if (([uri]$Servidor).Scheme -eq 'https') {
    Write-Host '   Endereco publico (HTTPS). Verifique, na ordem:' -ForegroundColor Yellow
    Write-Host '    1. esta maquina tem internet:'
    Write-Host '       Test-NetConnection 1.1.1.1 -Port 443' -ForegroundColor DarkGray
    Write-Host '    2. o nome resolve:'
    Write-Host "       Resolve-DnsName $(([uri]$Servidor).Host)" -ForegroundColor DarkGray
    Write-Host '    3. a rede da loja nao bloqueia a saida na 443 nem exige proxy'
    Write-Host '    4. o TLS desta maquina fecha com o servidor:'
    Write-Host "       Invoke-RestMethod '$Servidor/healthz'" -ForegroundColor DarkGray
    Write-Host '       (se falhar so aqui, o Windows esta sem atualizacao de TLS)'
    Write-Host '    5. a funcao de ingestao esta publicada e com os segredos definidos'
  } else {
    Write-Host '   Endereco de rede local (HTTP). Verifique, na ordem:' -ForegroundColor Yellow
    Write-Host '    1. o PC servidor esta ligado e a stack no ar'
    Write-Host '    2. as duas maquinas estao na MESMA rede'
    Write-Host '    3. o Firewall do Windows no servidor libera a porta:'
    Write-Host "       New-NetFirewallRule -DisplayName 'Monitoramento' -Direction Inbound -Protocol TCP -LocalPort $(([uri]$Servidor).Port) -Action Allow" -ForegroundColor DarkGray
    Write-Host '    4. o IP do servidor nao mudou (gere o comando de novo no dashboard)'
  }

  Write-Host ''
  exit 1
}

# ---------------------------------------------------------------------------
Passo 'Baixando o agente'
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $dirDados | Out-Null

try {
  $script = Invoke-RestMethod -Uri "$Servidor/agente.ps1" -TimeoutSec 30
} catch {
  Write-Host "   nao foi possivel baixar o agente: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}

# BOM UTF-8 de proposito: o PowerShell 5.1 le .ps1 como ANSI quando nao ha BOM, e
# um acento no arquivo viraria caractere de aspas que quebra a analise sintatica.
[System.IO.File]::WriteAllText($agentePath, $script, (New-Object System.Text.UTF8Encoding($true)))
Ok "agente em $agentePath"

# ---------------------------------------------------------------------------
Passo 'Detectando a rede desta maquina'
# ---------------------------------------------------------------------------
$gateway = ''
try {
  $rota = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Sort-Object RouteMetric | Select-Object -First 1
  if ($rota -and $rota.NextHop -ne '0.0.0.0') { $gateway = $rota.NextHop }
} catch { }

if ($gateway) { Ok "gateway: $gateway" } else { Info 'gateway nao detectado (latencia da LAN ficara desligada)' }

# ---------------------------------------------------------------------------
Passo 'Gravando a configuracao'
# ---------------------------------------------------------------------------
$listaServicos = @($Servicos | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($listaServicos.Count -eq 0) { $listaServicos = @('Spooler', 'Dhcp', 'Dnscache') }

$config = [ordered]@{
  localRpc         = $false
  ingestUrl        = $Servidor
  sharedSecret     = $Segredo
  token            = $Token
  machineLabel     = $env:COMPUTERNAME
  intervalSeconds  = $IntervaloSegundos
  batchSize        = 200
  gatewayIp        = $gateway
  criticalServices = $listaServicos
  spool            = @{ maxRows = 20000; maxAgeHours = 72 }
}

# UTF-8 SEM BOM: JSON com BOM e recusado por parser estrito.
[System.IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 6),
  (New-Object System.Text.UTF8Encoding($false)))

Ok "configuracao em $configPath"
Info "servicos vigiados: $($listaServicos -join ', ')"

# ---------------------------------------------------------------------------
Passo 'Coleta de teste'
# ---------------------------------------------------------------------------
& powershell -NoProfile -ExecutionPolicy Bypass -File "$agentePath" -UmaVez
if ($LASTEXITCODE -ne 0) {
  Write-Host ''
  Write-Host '   a coleta de teste falhou — veja a mensagem acima' -ForegroundColor Red
  exit 1
}

# ---------------------------------------------------------------------------
Passo 'Subindo o agente'
# ---------------------------------------------------------------------------
if (Test-Path $pidFile) {
  try { Stop-Process -Id ([int](Get-Content $pidFile)) -Force -ErrorAction Stop; Info 'agente anterior encerrado' } catch { }
}

$ehAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)

if ($ComTarefa -and $ehAdmin) {
  # Tarefa agendada como SYSTEM: sobrevive a reinicio e a logoff, e coleta
  # temperatura e SMART, que exigem privilegio.
  try { Unregister-ScheduledTask -TaskName 'MonitorAgent' -Confirm:$false -ErrorAction Stop } catch { }

  $acao = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$agentePath`""
  $gatilho = New-ScheduledTaskTrigger -AtStartup
  $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
  $cfgTarefa = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                 -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)

  Register-ScheduledTask -TaskName 'MonitorAgent' -Action $acao -Trigger $gatilho `
    -Principal $principal -Settings $cfgTarefa -Description 'Agente de monitoramento de infraestrutura' | Out-Null

  Start-ScheduledTask -TaskName 'MonitorAgent'
  Ok 'tarefa agendada criada (roda como SYSTEM, volta apos reiniciar)'
  Info 'como SYSTEM elevado, temperatura e SMART tambem sao coletados'
} else {
  if ($ComTarefa -and -not $ehAdmin) {
    Write-Host '   -ComTarefa exige terminal ELEVADO; subindo apenas nesta sessao' -ForegroundColor Yellow
  }

  # Caminho ENTRE ASPAS: Start-Process junta os argumentos sem citar, e
  # %ProgramData% pode conter espaco.
  $proc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $dirDados 'agente.out.log') `
            -RedirectStandardError  (Join-Path $dirDados 'agente.err.log') `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$agentePath`"")

  $proc.Id | Out-File -FilePath $pidFile -Encoding ascii
  Start-Sleep -Seconds 4

  if (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) {
    Ok "agente no ar (PID $($proc.Id))"
  } else {
    Write-Host '   o agente morreu ao iniciar:' -ForegroundColor Red
    Get-Content (Join-Path $dirDados 'agente.err.log') -Tail 10 -ErrorAction SilentlyContinue |
      ForEach-Object { Write-Host "     $_" -ForegroundColor Red }
    exit 1
  }
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Green
Write-Host " $env:COMPUTERNAME ESTA SENDO MONITORADA" -ForegroundColor Green
Write-Host '============================================================' -ForegroundColor Green
Write-Host "  Log   : $dirDados\agente.out.log"
Write-Host "  Parar : & ([scriptblock]::Create((irm '$Servidor/instalar.ps1'))) -Servidor '$Servidor' -Token x -Segredo x -Parar"
if (-not $ComTarefa) {
  Write-Host ''
  Write-Host '  O agente NAO volta sozinho apos reiniciar o Windows.' -ForegroundColor Yellow
  Write-Host '  Para isso, rode o mesmo comando com -ComTarefa num terminal ELEVADO.' -ForegroundColor Yellow
}
Write-Host '============================================================' -ForegroundColor Green
Write-Host ''
