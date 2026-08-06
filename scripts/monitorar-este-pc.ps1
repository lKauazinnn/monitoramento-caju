<#
.SYNOPSIS
  Cadastra ESTA maquina no monitoramento e comeca a coletar dados REAIS dela.

.DESCRIPTION
  Os dados que o dashboard mostra por padrao sao do simulador
  (agent_version = 'sim-1.0.0') — maquinas ficticias em lojas ficticias. Este
  script coloca a SUA maquina no sistema, com metricas medidas de verdade por
  consulta CIM.

  Faz:
    1. cria (se preciso) a marca e a loja para maquinas locais
    2. cadastra esta maquina com o hostname e o perfil reais
    3. emite um token para ela
    4. grava o config.json
    5. sobe o agente PowerShell em segundo plano

  Usa o agente em PowerShell e nao o .NET porque o Smart App Control desta
  maquina bloqueia binario sem assinatura reputavel (ver docs/FASE-3.md). O
  agente PowerShell nao passa por essa politica.

.PARAMETER Loja
  Codigo da loja. Padrao LOCAL-PC, criada se nao existir.

.PARAMETER Rotulo
  Nome da maquina no dashboard. Padrao: o hostname.

.PARAMETER Perfil
  pdv, server ou admin. Padrao admin.

.PARAMETER Servicos
  Servicos criticos a vigiar, por NOME CURTO. Padrao: Spooler, Dhcp, Dnscache.

.PARAMETER IntervaloSegundos
  Padrao 60, igual ao agente real.

.PARAMETER Parar
  Encerra o agente que estiver rodando e sai.

.EXAMPLE
  .\scripts\monitorar-este-pc.ps1

.EXAMPLE
  .\scripts\monitorar-este-pc.ps1 -Servicos Spooler,Dhcp,MSSQLSERVER

.EXAMPLE
  .\scripts\monitorar-este-pc.ps1 -Parar
#>
[CmdletBinding()]
param(
  [string]   $Loja = 'LOCAL-PC',
  [string]   $Rotulo = $env:COMPUTERNAME,
  [ValidateSet('pdv','server','admin')][string] $Perfil = 'admin',
  [string[]] $Servicos = @('Spooler', 'Dhcp', 'Dnscache'),
  [int]      $IntervaloSegundos = 60,
  [switch]   $Parar,
  [string]   $Container = 'monitor-db'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

function Passo { param([string]$T) Write-Host ''; Write-Host "== $T ==" -ForegroundColor Cyan }
function Ok    { param([string]$T) Write-Host "   $T" -ForegroundColor Green }
function Info  { param([string]$T) Write-Host "   $T" -ForegroundColor DarkGray }

$pidFile = Join-Path $repoRoot '.agente-ps.pid'
$dirDados = Join-Path $env:ProgramData 'MonitorAgent'
$configPath = Join-Path $dirDados 'config.json'

# ---------------------------------------------------------------------------
if ($Parar) {
  if (Test-Path $pidFile) {
    $p = Get-Content $pidFile
    try {
      Stop-Process -Id ([int]$p) -Force -ErrorAction Stop
      Ok "agente encerrado (PID $p)"
    } catch {
      Info "PID $p nao esta mais rodando"
    }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
  } else {
    Info 'nenhum agente registrado'
  }
  exit 0
}

# ---------------------------------------------------------------------------
Passo 'Pre-requisitos'
# ---------------------------------------------------------------------------
$existe = & docker ps --filter "name=$Container" --format '{{.Names}}' 2>$null
if ($existe -notcontains $Container) {
  Write-Host "A stack local nao esta no ar. Rode primeiro: .\scripts\dev-up.ps1" -ForegroundColor Red
  exit 1
}
Ok 'stack local no ar'

$devCfgPath = Join-Path $repoRoot 'dashboard\dev-config.json'
if (-not (Test-Path $devCfgPath)) {
  Write-Host 'dashboard/dev-config.json ausente. Rode .\scripts\dev-up.ps1' -ForegroundColor Red
  exit 1
}
$devCfg = Get-Content $devCfgPath -Raw | ConvertFrom-Json
$restUrl = $devCfg.restUrl
Ok "API $restUrl"

# Endereco e segredo da INGESTAO, do .env que o dev-up escreveu. O agente usa
# 127.0.0.1 porque roda nesta mesma maquina; agentes remotos recebem o IP da LAN
# via adicionar-pc.ps1.
$vars = @{}
foreach ($l in Get-Content (Join-Path $repoRoot '.env')) {
  if ($l -match '^\s*([A-Z_]+)\s*=\s*(.+)\s*$') { $vars[$Matches[1]] = $Matches[2] }
}

$ingestSecret = $vars['INGEST_SHARED_SECRET']
$portaIngest  = $vars['INGEST_PORT']

if (-not $ingestSecret -or -not $portaIngest) {
  Write-Host 'INGEST_SHARED_SECRET ou INGEST_PORT ausentes. Rode .\scripts\dev-up.ps1' -ForegroundColor Red
  exit 1
}

$ingestUrl = "http://127.0.0.1:$portaIngest"

$rodandoIngest = & docker ps --filter 'name=monitor-ingest' --format '{{.Names}}' 2>$null
if ($rodandoIngest -notcontains 'monitor-ingest') {
  Write-Host 'O container de ingestao nao esta no ar. Rode .\scripts\dev-up.ps1' -ForegroundColor Red
  exit 1
}
Ok "ingestao $ingestUrl"

# ---------------------------------------------------------------------------
Passo 'Cadastrando esta maquina'
# ---------------------------------------------------------------------------
# Via arquivo, nao por -c: o rotulo pode ter acento, e argumento de processo
# atravessa camadas com codificacao diferente. Ja criou maquina fantasma antes.
function EscSql { param([string]$V) return $V.Replace("'", "''") }

$sql = @"
\set ON_ERROR_STOP on
insert into public.brands (code, name)
values ('LOCAL', 'Maquinas locais')
on conflict do nothing;

insert into public.sites (brand_id, code, name, city, state)
select b.id, '$(EscSql $Loja)', 'Estacoes locais', 'local', 'DF'
from public.brands b where upper(b.code) = 'LOCAL'
on conflict do nothing;

select machine_id, token, token_prefix
from public.provision_machine('$(EscSql $Loja)', '$(EscSql $Rotulo)', '$Perfil', 'agente PowerShell nesta maquina', true);
"@

$tmpSql = Join-Path $env:TEMP 'monitor-cadastro.sql'
[System.IO.File]::WriteAllText($tmpSql, ($sql -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))

& docker cp $tmpSql "${Container}:/tmp/cadastro.sql" | Out-Null
Remove-Item $tmpSql -Force -ErrorAction SilentlyContinue

$env:PGCLIENTENCODING = 'UTF8'
$saida = & docker exec $Container psql -U postgres -q -t -A -F '|' -f /tmp/cadastro.sql
if ($LASTEXITCODE -ne 0) {
  Write-Host 'cadastro falhou:' -ForegroundColor Red
  $saida | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }
  exit 1
}

$linha = ($saida | Where-Object { $_ -match 'mon_' } | Select-Object -First 1)
if (-not $linha) {
  Write-Host 'nao obtive token. Saida:' -ForegroundColor Red
  $saida | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }
  exit 1
}

$c = $linha.Split('|')
$machineId = $c[0]
$token = $c[1]
$prefixo = $c[2]

Ok "maquina cadastrada: $Loja / $Rotulo"
Info "GUID    : $machineId"
Info "token   : $prefixo..."

# Recarrega o cache do PostgREST: a loja e a maquina sao novas.
& docker exec $Container psql -U postgres -q -c "notify pgrst, 'reload schema';" | Out-Null

# ---------------------------------------------------------------------------
Passo 'Descobrindo o gateway desta maquina'
# ---------------------------------------------------------------------------
$gateway = ''
try {
  $rota = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Sort-Object RouteMetric | Select-Object -First 1
  if ($rota -and $rota.NextHop -ne '0.0.0.0') { $gateway = $rota.NextHop }
} catch { }

if ($gateway) { Ok "gateway: $gateway" }
else { Info 'gateway nao detectado; a latencia da LAN ficara desligada' }

# ---------------------------------------------------------------------------
Passo 'Gravando o config.json'
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $dirDados | Out-Null

$config = [ordered]@{
  # localRpc = false, e sem serviceToken.
  #
  # A versao anterior falava direto com o PostgREST e por isso precisava de um
  # token de service_role NO CONFIG — credencial de acesso total ao banco no disco
  # de uma maquina monitorada. Passava na stack local porque a maquina era esta
  # mesma, mas era o padrao errado: ao adicionar um segundo PC, cada loja
  # receberia essa chave.
  #
  # Agora esta maquina usa o MESMO caminho que qualquer outra: o endpoint de
  # ingestao, com o segredo compartilhado e o token da propria maquina. A chave de
  # service_role fica no container e nao sai dele.
  localRpc         = $false
  ingestUrl        = $ingestUrl
  sharedSecret     = $ingestSecret
  token            = $token
  machineId        = $machineId
  siteCode         = $Loja
  machineLabel     = $Rotulo
  role             = $Perfil
  intervalSeconds  = $IntervaloSegundos
  batchSize        = 200
  gatewayIp        = $gateway
  criticalServices = @($Servicos | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  spool            = @{ maxRows = 20000; maxAgeHours = 72 }
}

# UTF-8 SEM BOM.
#
# `Out-File -Encoding utf8` no PowerShell 5.1 grava BOM, e JSON com BOM e recusado
# por parser estrito — o JSON.parse do Node falha com "Unexpected token" apontando
# para um caractere invisivel. O ConvertFrom-Json do PowerShell tolera, então o
# agente funcionava e qualquer outra ferramenta quebrava.
[System.IO.File]::WriteAllText(
  $configPath,
  ($config | ConvertTo-Json -Depth 6),
  (New-Object System.Text.UTF8Encoding($false)))

# SEM endurecimento de ACL aqui, e de proposito.
#
# A versao anterior fazia `icacls /inheritance:r /grant ...` e conseguiu: removeu
# a heranca e concedeu tao pouco que o proprio agente perdeu acesso ao
# config.json — a coleta de teste falhou com "acesso negado" no arquivo que o
# script tinha acabado de escrever.
#
# Restringir ACL corretamente exige elevacao e conhecer a conta sob a qual o
# servico vai rodar. Isso e trabalho do instalador de producao
# (agent/tools/instalar-servico.ps1), que roda elevado e sabe que o servico e
# LocalSystem. Aqui, numa stack de loopback, herdar as permissoes do
# %ProgramData% e o comportamento correto.
Info 'permissoes: herdadas do %ProgramData% (endurecimento fica no instalador de producao)'

Ok "config em $configPath"
Info "servicos vigiados: $($config.criticalServices -join ', ')"

# ---------------------------------------------------------------------------
Passo 'Coleta de teste (dados REAIS desta maquina)'
# ---------------------------------------------------------------------------
$agente = Join-Path $repoRoot 'agent\agente-powershell.ps1'
& powershell -NoProfile -ExecutionPolicy Bypass -File "$agente" -UmaVez
if ($LASTEXITCODE -ne 0) {
  Write-Host 'a coleta de teste falhou' -ForegroundColor Red
  exit 1
}

# ---------------------------------------------------------------------------
Passo 'Subindo o agente em segundo plano'
# ---------------------------------------------------------------------------
if (Test-Path $pidFile) {
  $antigo = Get-Content $pidFile
  try { Stop-Process -Id ([int]$antigo) -Force -ErrorAction Stop; Info "agente anterior (PID $antigo) encerrado" } catch { }
}

$logOut = Join-Path $repoRoot 'agente-ps.out.log'
$logErr = Join-Path $repoRoot 'agente-ps.err.log'

# Caminho ENTRE ASPAS: o caminho deste projeto tem espaco, e Start-Process junta
# os argumentos sem citar. Foi o que matou o simulador em segundo plano antes.
$proc = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
          -RedirectStandardOutput $logOut -RedirectStandardError $logErr `
          -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$agente`"")

$proc.Id | Out-File -FilePath $pidFile -Encoding ascii
Start-Sleep -Seconds 4

if (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) {
  Ok "agente no ar (PID $($proc.Id)), coletando a cada ${IntervaloSegundos}s"
} else {
  Write-Host '   o agente morreu ao iniciar:' -ForegroundColor Red
  if (Test-Path $logErr) { Get-Content $logErr -Tail 10 | ForEach-Object { Write-Host "     $_" -ForegroundColor Red } }
  exit 1
}

Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Green
Write-Host "   $Rotulo ESTA SENDO MONITORADA DE VERDADE" -ForegroundColor Green
Write-Host '  ============================================================' -ForegroundColor Green
Write-Host "   Loja no dashboard : $Loja"
Write-Host "   agent_version     : ps-1.0.0  (o simulador usa sim-1.0.0)"
Write-Host ''
Write-Host "   Log do agente : $logOut"
Write-Host "   Spool         : $dirDados\spool.jsonl"
Write-Host "   Ver o JSON    : .\agent\agente-powershell.ps1 -MostrarJson"
Write-Host "   Parar         : .\scripts\monitorar-este-pc.ps1 -Parar"
Write-Host '  ============================================================' -ForegroundColor Green
Write-Host ''
Write-Host '   Filtre por LOCAL-PC no dashboard para ver so esta maquina.' -ForegroundColor Cyan
Write-Host '   Temperatura e SMART exigem terminal ELEVADO — sem isso vem nulos.' -ForegroundColor DarkGray
Write-Host ''
