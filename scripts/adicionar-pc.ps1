<#
.SYNOPSIS
  Cadastra OUTRO PC no monitoramento e gera um pacote pronto para copiar para ele.

.DESCRIPTION
  Roda NESTA maquina (a que tem a stack). Ele nao toca no PC remoto — produz uma
  pasta que voce copia para la e executa.

  O pacote leva:
    - agente-powershell.ps1
    - config.json com SOMENTE o token daquela maquina
    - instalar.ps1, que copia o config para %ProgramData% e sobe o agente
    - LEIA-ME.txt

  O QUE ELE NAO LEVA, e isso e o ponto: nenhuma credencial de servidor. O agente
  fala com o endpoint de ingestao usando o token da propria maquina, e esse token e
  revogavel individualmente. A chave de service_role fica no container de
  ingestao, desta maquina, e nunca sai daqui.

.PARAMETER Rotulo
  Nome da maquina no dashboard. Obrigatorio.

.PARAMETER Loja
  Codigo da loja. Criada se nao existir. Padrao LOCAL-PC.

.PARAMETER Perfil
  pdv, server ou admin. Padrao pdv.

.PARAMETER Servicos
  Servicos criticos, por NOME CURTO. Padrao: Spooler, Dhcp, Dnscache.

.PARAMETER Destino
  Onde gerar o pacote. Padrao: .\pacotes\<Rotulo>

.PARAMETER Servidor
  Endereco desta maquina que o outro PC vai usar. Detectado automaticamente;
  informe se a deteccao errar (por exemplo, se houver mais de uma rede).

.EXAMPLE
  .\scripts\adicionar-pc.ps1 -Rotulo 'PDV-CAIXA-02'

.EXAMPLE
  .\scripts\adicionar-pc.ps1 -Rotulo 'SRV-LOJA' -Loja BSB-001 -Perfil server -Servicos Spooler,MSSQLSERVER
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string] $Rotulo,
  [string]   $Loja = 'LOCAL-PC',
  [ValidateSet('pdv','server','admin')][string] $Perfil = 'pdv',
  [string[]] $Servicos = @('Spooler', 'Dhcp', 'Dnscache'),
  [string]   $Destino = '',
  [string]   $Servidor = '',
  [int]      $IntervaloSegundos = 60,
  [string]   $Container = 'monitor-db'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

function Passo { param([string]$T) Write-Host ''; Write-Host "== $T ==" -ForegroundColor Cyan }
function Ok    { param([string]$T) Write-Host "   $T" -ForegroundColor Green }
function Info  { param([string]$T) Write-Host "   $T" -ForegroundColor DarkGray }
function EscSql { param([string]$V) return $V.Replace("'", "''") }

# ---------------------------------------------------------------------------
Passo 'Pre-requisitos'
# ---------------------------------------------------------------------------
$rodando = & docker ps --filter "name=$Container" --format '{{.Names}}' 2>$null
if ($rodando -notcontains $Container) {
  Write-Host 'A stack local nao esta no ar. Rode: .\scripts\dev-up.ps1' -ForegroundColor Red
  exit 1
}

$ingestOk = & docker ps --filter 'name=monitor-ingest' --format '{{.Names}}' 2>$null
if ($ingestOk -notcontains 'monitor-ingest') {
  Write-Host 'O container de ingestao nao esta no ar. Rode: .\scripts\dev-up.ps1' -ForegroundColor Red
  exit 1
}
Ok 'stack e ingestao no ar'

$envPath = Join-Path $repoRoot '.env'
$vars = @{}
foreach ($l in Get-Content $envPath) {
  if ($l -match '^\s*([A-Z_]+)\s*=\s*(.+)\s*$') { $vars[$Matches[1]] = $Matches[2] }
}

$segredo = $vars['INGEST_SHARED_SECRET']
$portaIngest = $vars['INGEST_PORT']
if (-not $segredo -or -not $portaIngest) {
  Write-Host 'INGEST_SHARED_SECRET ou INGEST_PORT ausentes. Rode .\scripts\dev-up.ps1' -ForegroundColor Red
  exit 1
}

# ---------------------------------------------------------------------------
Passo 'Endereco que o outro PC vai usar'
# ---------------------------------------------------------------------------
if (-not $Servidor) {
  try {
    $rota = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
              Sort-Object RouteMetric | Select-Object -First 1
    if ($rota) {
      $Servidor = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $rota.InterfaceIndex -ErrorAction Stop |
                 Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
                 Select-Object -First 1).IPAddress
    }
  } catch { }
}

if (-not $Servidor) {
  Write-Host 'nao consegui detectar o IP desta maquina na LAN.' -ForegroundColor Red
  Write-Host 'Informe com -Servidor <ip>. Veja os candidatos:' -ForegroundColor Yellow
  Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
    Select-Object IPAddress, InterfaceAlias | Format-Table | Out-String | Write-Host
  exit 1
}

$ingestUrl = "http://${Servidor}:$portaIngest"
Ok "ingestao: $ingestUrl"

# Confirma que o endpoint responde NESSE endereco, nao so em 127.0.0.1. Um
# firewall bloqueando a porta e o motivo numero um de o agente remoto ficar mudo,
# e descobrir isso agora e muito melhor que descobrir na outra maquina.
try {
  $h = Invoke-RestMethod -Uri "$ingestUrl/healthz" -TimeoutSec 8
  if ($h.ok) { Ok 'endpoint respondeu no IP da LAN' }
} catch {
  Write-Host "   AVISO: $ingestUrl nao respondeu daqui." -ForegroundColor Yellow
  Write-Host '   O Firewall do Windows provavelmente esta bloqueando a porta.' -ForegroundColor Yellow
  Write-Host '   Libere com (terminal ELEVADO):' -ForegroundColor Yellow
  Write-Host "     New-NetFirewallRule -DisplayName 'Monitoramento ingest' -Direction Inbound -Protocol TCP -LocalPort $portaIngest -Action Allow" -ForegroundColor DarkGray
  Write-Host ''
  $r = Read-Host '   Gerar o pacote mesmo assim? (s/N)'
  if ($r -ne 's') { exit 1 }
}

# ---------------------------------------------------------------------------
Passo 'Cadastrando a maquina'
# ---------------------------------------------------------------------------
$listaServicos = @($Servicos | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$sql = @"
\set ON_ERROR_STOP on
insert into public.brands (code, name) values ('LOCAL', 'Maquinas locais')
on conflict do nothing;

insert into public.sites (brand_id, code, name, city, state)
select b.id, '$(EscSql $Loja)', 'Estacoes locais', 'local', 'DF'
from public.brands b where upper(b.code) = 'LOCAL'
on conflict do nothing;

select machine_id, token, token_prefix
from public.provision_machine('$(EscSql $Loja)', '$(EscSql $Rotulo)', '$Perfil',
                              'agente PowerShell remoto', true);
"@

$tmpSql = Join-Path $env:TEMP "monitor-add-$([guid]::NewGuid().ToString('N').Substring(0,8)).sql"
[System.IO.File]::WriteAllText($tmpSql, ($sql -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
& docker cp $tmpSql "${Container}:/tmp/add.sql" | Out-Null
Remove-Item $tmpSql -Force -ErrorAction SilentlyContinue

$env:PGCLIENTENCODING = 'UTF8'
$saida = & docker exec $Container psql -U postgres -q -t -A -F '|' -f /tmp/add.sql
if ($LASTEXITCODE -ne 0) {
  Write-Host 'cadastro falhou:' -ForegroundColor Red
  $saida | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }
  exit 1
}

$linha = ($saida | Where-Object { $_ -match 'mon_' } | Select-Object -First 1)
if (-not $linha) {
  Write-Host 'nao obtive token:' -ForegroundColor Red
  $saida | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }
  exit 1
}

$c = $linha.Split('|')
$machineId = $c[0]
$token = $c[1]
$prefixo = $c[2]

& docker exec $Container psql -U postgres -q -c "notify pgrst, 'reload schema';" | Out-Null

Ok "$Loja / $Rotulo cadastrada"
Info "GUID  : $machineId"
Info "token : $prefixo..."

# ---------------------------------------------------------------------------
Passo 'Montando o pacote'
# ---------------------------------------------------------------------------
if (-not $Destino) { $Destino = Join-Path $repoRoot "pacotes\$($Rotulo -replace '[^A-Za-z0-9._-]', '_')" }
New-Item -ItemType Directory -Force -Path $Destino | Out-Null

Copy-Item (Join-Path $repoRoot 'agent\agente-powershell.ps1') $Destino -Force

# localRpc = false: usa o contrato REAL da Fase 2 — segredo compartilhado no
# header e o token DA MAQUINA como Bearer. Nenhuma credencial de servidor aqui.
$config = [ordered]@{
  localRpc         = $false
  ingestUrl        = $ingestUrl
  sharedSecret     = $segredo
  token            = $token
  machineId        = $machineId
  siteCode         = $Loja
  machineLabel     = $Rotulo
  role             = $Perfil
  intervalSeconds  = $IntervaloSegundos
  batchSize        = 200
  gatewayIp        = ''      # o instalador detecta no PC de destino
  criticalServices = $listaServicos
  spool            = @{ maxRows = 20000; maxAgeHours = 72 }
}

# UTF-8 SEM BOM: JSON com BOM e recusado por parser estrito. O ConvertFrom-Json
# do PowerShell tolera, então o agente funcionaria e qualquer outra ferramenta
# quebraria — o pior tipo de defeito, o que só aparece para o proximo.
[System.IO.File]::WriteAllText(
  (Join-Path $Destino 'config.json'),
  ($config | ConvertTo-Json -Depth 6),
  (New-Object System.Text.UTF8Encoding($false)))

# ---------------------------------------------------------------------------
# Instalador para rodar NO PC de destino
# ---------------------------------------------------------------------------
$instalador = @'
<#
  Instala o agente de monitoramento NESTA maquina.

  Rode do proprio diretorio do pacote:
    powershell -ExecutionPolicy Bypass -File .\instalar.ps1
#>
[CmdletBinding()]
param([switch] $Parar)

$ErrorActionPreference = 'Stop'
$aqui = Split-Path -Parent $MyInvocation.MyCommand.Path
$dirDados = Join-Path $env:ProgramData 'MonitorAgent'
$pidFile = Join-Path $dirDados 'agente.pid'

if ($Parar) {
  if (Test-Path $pidFile) {
    try { Stop-Process -Id ([int](Get-Content $pidFile)) -Force -ErrorAction Stop; Write-Host 'agente encerrado' -ForegroundColor Green }
    catch { Write-Host 'agente nao estava rodando' -ForegroundColor DarkGray }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
  } else { Write-Host 'nenhum agente registrado' -ForegroundColor DarkGray }
  exit 0
}

Write-Host ''
Write-Host '== Instalando o agente de monitoramento ==' -ForegroundColor Cyan

New-Item -ItemType Directory -Force -Path $dirDados | Out-Null

# Gateway detectado AQUI, no PC de destino: cada maquina tem o seu.
$cfg = Get-Content (Join-Path $aqui 'config.json') -Raw | ConvertFrom-Json
try {
  $rota = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Sort-Object RouteMetric | Select-Object -First 1
  if ($rota -and $rota.NextHop -ne '0.0.0.0') {
    $cfg.gatewayIp = $rota.NextHop
    Write-Host "   gateway detectado: $($cfg.gatewayIp)" -ForegroundColor DarkGray
  }
} catch { }

$destinoCfg = Join-Path $dirDados 'config.json'
# UTF-8 sem BOM: JSON com BOM e recusado por parser estrito.
[System.IO.File]::WriteAllText($destinoCfg, ($cfg | ConvertTo-Json -Depth 6),
  (New-Object System.Text.UTF8Encoding($false)))
Write-Host "   config em $destinoCfg" -ForegroundColor DarkGray

Copy-Item (Join-Path $aqui 'agente-powershell.ps1') $dirDados -Force
$agente = Join-Path $dirDados 'agente-powershell.ps1'

Write-Host ''
Write-Host '== Teste de conectividade e coleta ==' -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File "$agente" -UmaVez
if ($LASTEXITCODE -ne 0) {
  Write-Host ''
  Write-Host 'A coleta de teste falhou.' -ForegroundColor Red
  Write-Host 'Causas comuns:' -ForegroundColor Yellow
  Write-Host "  - firewall na maquina do servidor bloqueando $($cfg.ingestUrl)"
  Write-Host '  - o servidor mudou de IP (regenere o pacote com adicionar-pc.ps1)'
  Write-Host '  - token revogado'
  exit 1
}

if (Test-Path $pidFile) {
  try { Stop-Process -Id ([int](Get-Content $pidFile)) -Force -ErrorAction Stop } catch { }
}

Write-Host ''
Write-Host '== Subindo em segundo plano ==' -ForegroundColor Cyan

# Caminho ENTRE ASPAS: Start-Process junta os argumentos sem citar, e
# %ProgramData% pode conter espaco.
$proc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
          -RedirectStandardOutput (Join-Path $dirDados 'agente.out.log') `
          -RedirectStandardError  (Join-Path $dirDados 'agente.err.log') `
          -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$agente`"")

$proc.Id | Out-File -FilePath $pidFile -Encoding ascii
Start-Sleep -Seconds 4

if (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) {
  Write-Host "   agente no ar (PID $($proc.Id))" -ForegroundColor Green
} else {
  Write-Host '   o agente morreu ao iniciar:' -ForegroundColor Red
  Get-Content (Join-Path $dirDados 'agente.err.log') -Tail 10 -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host "     $_" -ForegroundColor Red }
  exit 1
}

Write-Host ''
Write-Host "  $env:COMPUTERNAME esta sendo monitorada." -ForegroundColor Green
Write-Host "  Log    : $dirDados\agente.out.log"
Write-Host "  Parar  : .\instalar.ps1 -Parar"
Write-Host ''
Write-Host '  Para o agente voltar sozinho depois de reiniciar o Windows,' -ForegroundColor DarkGray
Write-Host '  crie uma tarefa agendada (veja LEIA-ME.txt).' -ForegroundColor DarkGray
Write-Host ''
'@

$instalador | Out-File -FilePath (Join-Path $Destino 'instalar.ps1') -Encoding utf8

# BOM no instalador: PowerShell 5.1 le .ps1 como ANSI sem BOM, e um acento
# viraria caractere de aspas que quebra a analise sintatica.
$fpInst = Join-Path $Destino 'instalar.ps1'
$bytes = [System.IO.File]::ReadAllBytes($fpInst)
if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF)) {
  [System.IO.File]::WriteAllText($fpInst,
    [System.Text.UTF8Encoding]::new($false).GetString($bytes),
    [System.Text.UTF8Encoding]::new($true))
}

# ---------------------------------------------------------------------------
$leiaMe = @"
MONITORAMENTO — pacote para $Rotulo
=====================================================================

Maquina  : $Rotulo
Loja     : $Loja
Perfil   : $Perfil
Servidor : $ingestUrl
Servicos : $($listaServicos -join ', ')

COMO INSTALAR
---------------------------------------------------------------------
1. Copie ESTA PASTA INTEIRA para o PC de destino.
2. Abra o PowerShell nessa pasta.
3. Rode:

     powershell -ExecutionPolicy Bypass -File .\instalar.ps1

   Ele testa a conexao, faz uma coleta e sobe o agente em segundo plano.

PARA VOLTAR SOZINHO APOS REINICIAR O WINDOWS
---------------------------------------------------------------------
O agente nao e servico do Windows. Crie uma tarefa agendada
(terminal ELEVADO no PC de destino):

  \$a = New-ScheduledTaskAction -Execute 'powershell.exe' ``
        -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\ProgramData\MonitorAgent\agente-powershell.ps1"'
  \$g = New-ScheduledTaskTrigger -AtStartup
  \$p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
  Register-ScheduledTask -TaskName 'MonitorAgent' -Action \$a -Trigger \$g -Principal \$p

Rodando como SYSTEM em nivel elevado, temperatura e SMART tambem passam a
ser coletados — sem elevacao eles vem nulos, com a flag temp_denied.

DIAGNOSTICO
---------------------------------------------------------------------
  Ver o que a maquina coleta, sem enviar:
    powershell -ExecutionPolicy Bypass -File C:\ProgramData\MonitorAgent\agente-powershell.ps1 -MostrarJson

  Log:
    Get-Content C:\ProgramData\MonitorAgent\agente.out.log -Tail 30 -Wait

  Amostras pendentes de envio:
    Get-Content C:\ProgramData\MonitorAgent\spool.jsonl | Measure-Object -Line

SEGURANCA
---------------------------------------------------------------------
O config.json contem o token DESTA maquina em texto claro. Ele da acesso
apenas para ENVIAR metricas desta maquina — nao le dado de ninguem e nao
escreve em mais nada.

Se este PC for comprometido ou substituido, revogue so ele, no servidor:

  .\scripts\revoke-token.ps1 -Prefix $prefixo -Reason 'maquina substituida'

Nenhuma credencial de servidor acompanha este pacote.

SE O SERVIDOR TROCAR DE IP
---------------------------------------------------------------------
O endereco $ingestUrl esta fixo no config.json. Mudando o IP da maquina
servidora, gere o pacote de novo e reinstale, ou edite ingestUrl no
C:\ProgramData\MonitorAgent\config.json e reinicie o agente.
"@

$leiaMe | Out-File -FilePath (Join-Path $Destino 'LEIA-ME.txt') -Encoding utf8

Ok "pacote em $Destino"
Get-ChildItem $Destino | ForEach-Object { Info "  $($_.Name)" }

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Green
Write-Host "   PACOTE PRONTO PARA $Rotulo" -ForegroundColor Green
Write-Host '  ============================================================' -ForegroundColor Green
Write-Host "   Pasta    : $Destino"
Write-Host "   Servidor : $ingestUrl"
Write-Host ''
Write-Host '   No PC de destino, dentro da pasta copiada:'
Write-Host '     powershell -ExecutionPolicy Bypass -File .\instalar.ps1' -ForegroundColor Cyan
Write-Host ''
Write-Host '   Nenhuma credencial de servidor vai no pacote — so o token'
Write-Host "   desta maquina, revogavel com: .\scripts\revoke-token.ps1 -Prefix $prefixo"
Write-Host '  ============================================================' -ForegroundColor Green
Write-Host ''
