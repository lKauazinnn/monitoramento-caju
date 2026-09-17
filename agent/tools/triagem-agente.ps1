<#
.SYNOPSIS
  Diz por que ESTA maquina parou de reportar, e conserta o caso mais comum.

.DESCRIPTION
  Sem parametro ele so OLHA e da um veredito. Com -Consertar ele age.

  O caso que este script existe para pegar: o agente rodando SEM tarefa
  agendada. A maquina funciona perfeitamente ate alguem desligar o PC -- e ai
  nao existe nada que traga o agente de volta. Foi assim que 27 maquinas
  sumiram no MESMO minuto, no fim de um expediente, sem deixar um unico rastro
  no servidor: nao houve falha nenhuma, so nao houve retorno.

  A tarefa criada aqui conserta tres coisas que a partida manual nao tem:

    -AtStartup            volta sozinha depois de reiniciar o PC
    ExecutionTimeLimit 0  sem isto o Windows MATA a tarefa em 72 h, e um
                          agente que e um laco infinito morre no terceiro dia
    RestartCount 3        se o processo cair, o Windows o levanta de novo

  Somente leitura sem -Consertar: nenhum arquivo e tocado, nenhuma tarefa e
  criada. Nunca imprime o sharedSecret do config.json.

.PARAMETER Consertar
  Cria a tarefa agendada se faltar e inicia o agente. Precisa de terminal
  ELEVADO.

.PARAMETER Pasta
  Onde o agente vive. Padrao: %ProgramData%\MonitorAgent

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\triagem-agente.ps1

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\triagem-agente.ps1 -Consertar

.EXAMPLE
  # Varias maquinas de uma vez, quando ha WinRM ate elas
  Invoke-Command -ComputerName KDS-PRINCIPAL,PARILLA-02 -FilePath .\agent\tools\triagem-agente.ps1 |
    Format-Table maquina, veredito, acao -AutoSize
#>
[CmdletBinding()]
param(
  [switch] $Consertar,
  [string] $Pasta = (Join-Path $env:ProgramData 'MonitorAgent')
)

$ErrorActionPreference = 'Stop'

$arqConfig = Join-Path $Pasta 'config.json'
$arqScript = Join-Path $Pasta 'agente-powershell.ps1'
$arqLog    = Join-Path $Pasta 'agente-ps.log'
$arqSpool  = Join-Path $Pasta 'spool.jsonl'
$NOME      = 'MonitorAgent'
$cfg       = $null

$r = [ordered]@{
  maquina      = $env:COMPUTERNAME
  rotulo       = $null
  tem_config   = $false
  tem_script   = $false
  tarefa       = 'ausente'
  processo     = $false
  log_minutos  = $null
  spool_linhas = $null
  alcanca      = $null
  veredito     = $null
  acao         = $null
}

# --- 1. A identidade da maquina -------------------------------------------
# O machineId do config.json E o cadastro. Enquanto este arquivo existir, a
# maquina volta para o MESMO registro do painel -- nao ha o que recadastrar.
if (Test-Path $arqConfig) {
  $r.tem_config = $true
  try {
    $cfg = Get-Content $arqConfig -Raw | ConvertFrom-Json
    if ($cfg.machineLabel) { $r.rotulo = $cfg.machineLabel } else { $r.rotulo = $cfg.label }
  } catch { $r.rotulo = '(config ilegivel)' }
}
$r.tem_script = Test-Path $arqScript

# --- 2. A tarefa agendada, que e o ponto todo ------------------------------
# SEM ELEVACAO NAO DA PARA CONCLUIR NADA AQUI. Tarefa registrada para SYSTEM
# nao aparece para sessao comum -- nem em Get-ScheduledTask sem filtro. Logo
# "nao achei" e "nao existe" chegam iguais, e tratar os dois como ausencia faz
# este script mandar consertar maquina SAUDAVEL: o conserto mata o agente que
# estava rodando para registrar uma tarefa que ja existia.
# Medido: mesma maquina, no mesmo minuto, sessao elevada via Running e sessao
# comum viu nada.
$idAtual = [Security.Principal.WindowsIdentity]::GetCurrent()
$elevado = ([Security.Principal.WindowsPrincipal]$idAtual).IsInRole(
             [Security.Principal.WindowsBuiltInRole]::Administrator)
try {
  $t = Get-ScheduledTask -TaskName $NOME -ErrorAction Stop
  $r.tarefa = [string]$t.State
} catch {
  if ($elevado) { $r.tarefa = 'ausente' } else { $r.tarefa = 'indeterminado' }
}

# --- 3. O processo esta vivo AGORA? ---------------------------------------
# Procura pela LINHA DE COMANDO: powershell.exe sozinho nao diz nada numa
# maquina que roda outros scripts.
# CUIDADO: sem elevacao o Windows ESCONDE a CommandLine de processo de outro
# usuario -- e o agente roda como SYSTEM. Perguntar so por aqui devolve "nao"
# para maquina saudavel, e isso mandaria alguem viajar ate a loja a toa.
# Por isso este campo tem TRES valores, e 'indeterminado' e um deles.
$r.processo = 'indeterminado'
try {
  $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop)
  $comLinha = @($procs | Where-Object { $_.CommandLine })
  $achou    = @($comLinha | Where-Object { $_.CommandLine -like '*agente-powershell*' })
  if ($achou.Count -gt 0) { $r.processo = 'sim' }
  elseif ($comLinha.Count -eq $procs.Count) { $r.processo = 'nao' }
} catch { }

# --- 4. Ha quanto tempo o log respira -------------------------------------
# O BATIMENTO. A regra 16 manda gravar no spool ANTES de tentar enviar, entao
# spool.jsonl e tocado em TODO ciclo -- inclusive quando o envio falha. E o
# sinal de vida mais honesto que existe aqui, e qualquer usuario o le.
$marcas = @()
foreach ($f in @($arqLog, $arqSpool)) {
  if (Test-Path $f) { $marcas += (Get-Item $f).LastWriteTime }
}
if ($marcas.Count -gt 0) {
  $ultima = ($marcas | Sort-Object -Descending)[0]
  $r.log_minutos = [int]((Get-Date) - $ultima).TotalMinutes
}
if (Test-Path $arqSpool) {
  try { $r.spool_linhas = @(Get-Content $arqSpool -ErrorAction Stop).Count } catch { }
}

# --- 5. A rede alcanca o destino? -----------------------------------------
# Qualquer resposta HTTP serve de prova: 401 e 405 tambem provam DNS, rota e
# TLS. So a EXCECAO sem resposta significa "nao alcanca".
if ($r.tem_config -and $cfg -and $cfg.ingestUrl) {
  try {
    Invoke-WebRequest -Uri $cfg.ingestUrl -Method Get -TimeoutSec 8 -UseBasicParsing | Out-Null
    $r.alcanca = $true
  } catch {
    $r.alcanca = ($null -ne $_.Exception.Response)
  }
}

# --- 6. Veredito -----------------------------------------------------------
# Vivo = bateu ha pouco OU o processo foi visto. O agente escreve a cada ciclo
# (60 s por padrao), entao 3 minutos e folga de tres ciclos.
$vivo = (($null -ne $r.log_minutos) -and ($r.log_minutos -le 3)) -or ($r.processo -eq 'sim')
# A ordem importa: a primeira condicao verdadeira e a causa RAIZ. Consertar
# qualquer outra antes dela nao adianta.
if (-not $r.tem_config) {
  $r.veredito = 'SEM_CONFIG'
  $r.acao = 'Reprovisione com a MESMA loja e o MESMO rotulo do painel. Rotulo diferente cria maquina DUPLICADA.'
}
elseif (-not $r.tem_script) {
  $r.veredito = 'SEM_SCRIPT'
  $r.acao = 'O cadastro sobreviveu, o agente nao. Reinstale o agente; nada a recadastrar.'
}
elseif ($r.tarefa -eq 'ausente') {
  if ($vivo) { $r.veredito = 'RODANDO_SEM_TAREFA' } else { $r.veredito = 'PARADO_SEM_TAREFA' }
  $r.acao = 'Rode de novo com -Consertar, em terminal ELEVADO. Sem tarefa o agente nao volta depois de reiniciar o PC.'
}
elseif (-not $vivo) {
  $r.veredito = 'TAREFA_PARADA'
  $r.acao = 'Rode de novo com -Consertar, em terminal ELEVADO.'
}
elseif ($r.alcanca -eq $false) {
  $r.veredito = 'SEM_REDE'
  $r.acao = 'O agente roda e nao alcanca o destino. Veja firewall, proxy e DNS desta loja.'
}
elseif ($r.processo -eq 'sim' -and $null -ne $r.log_minutos -and $r.log_minutos -gt 10) {
  $r.veredito = 'TRAVADO'
  $r.acao = 'O processo existe mas o log nao escreve ha ' + $r.log_minutos + ' min. Use -Consertar para reiniciar.'
}
else {
  $r.veredito = 'SAUDAVEL'
  $r.acao = 'Nada a fazer.'
}

# --- 7. Conserto -----------------------------------------------------------
$consertaveis = @('RODANDO_SEM_TAREFA','PARADO_SEM_TAREFA','TAREFA_PARADA','TRAVADO')
if ($Consertar -and ($consertaveis -contains $r.veredito)) {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $elevado = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

  if (-not $elevado) {
    $r.acao = 'PRECISA DE TERMINAL ELEVADO: abra o PowerShell como administrador e rode de novo com -Consertar.'
  }
  else {
    try {
      if ($r.tarefa -eq 'ausente') {
        $argumento = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $arqScript + '"'
        $pAcao = @{ Execute = 'powershell.exe'; Argument = $argumento }
        # ExecutionTimeLimit zero = SEM PRAZO. O padrao do Windows e 72 h, e um
        # agente que e laco infinito seria morto no terceiro dia -- exatamente o
        # tipo de sumico que ninguem liga a um prazo de tarefa agendada.
        $pCfg = @{
          MultipleInstances        = 'IgnoreNew'
          ExecutionTimeLimit       = [TimeSpan]::Zero
          RestartCount             = 3
          RestartInterval          = (New-TimeSpan -Minutes 1)
          AllowStartIfOnBatteries  = $true
          DontStopIfGoingOnBatteries = $true
        }
        $pTarefa = @{
          TaskName  = $NOME
          Action    = (New-ScheduledTaskAction @pAcao)
          Trigger   = (New-ScheduledTaskTrigger -AtStartup)
          Principal = (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest)
          Settings  = (New-ScheduledTaskSettingsSet @pCfg)
          Force     = $true
        }
        Register-ScheduledTask @pTarefa | Out-Null
      }

      # Mata a instancia solta ANTES de iniciar pela tarefa: duas copias
      # enviando a mesma maquina dobram o volume gravado e confundem o painel.
      try {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
          Where-Object { $_.CommandLine -like '*agente-powershell*' } |
          ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
      } catch { }

      Start-ScheduledTask -TaskName $NOME
      Start-Sleep -Seconds 4
      $r.tarefa = [string](Get-ScheduledTask -TaskName $NOME).State
      $r.acao = 'CONSERTADO: tarefa ' + $r.tarefa + '. Agora ela volta sozinha depois de reiniciar o PC.'
    }
    catch {
      $r.acao = 'FALHOU o conserto: ' + $_.Exception.Message
    }
  }
}

# --- 8. Saida --------------------------------------------------------------
if ($r.rotulo) { $nome = $r.rotulo } else { $nome = 'sem rotulo' }
if ($null -ne $r.log_minutos) { $vLog = "$($r.log_minutos) min" } else { $vLog = 'sem log' }
if ($null -ne $r.spool_linhas) { $vSpool = "$($r.spool_linhas) linha(s)" } else { $vSpool = '-' }
if ($null -eq $r.alcanca) { $vRede = '(nao testado)' } elseif ($r.alcanca) { $vRede = 'sim' } else { $vRede = 'NAO' }
if ($r.tem_config) { $vCfg = 'presente' } else { $vCfg = 'AUSENTE' }
$vProc = $r.processo

Write-Host ''
Write-Host ('=== ' + $r.maquina + ' (' + $nome + ') ===')
Write-Host ('  cadastro (config.json) : ' + $vCfg)
Write-Host ('  tarefa agendada        : ' + $r.tarefa)
Write-Host ('  agente vivo            : ' + $vProc)
Write-Host ('  ultimo batimento ha    : ' + $vLog)
Write-Host ('  spool (nao enviado)    : ' + $vSpool)
Write-Host ('  alcanca o servidor     : ' + $vRede)
Write-Host ''
if ($r.veredito -eq 'SAUDAVEL') { $cor = 'Green' }
elseif ($r.veredito -eq 'SEM_CONFIG') { $cor = 'Red' }
else { $cor = 'Yellow' }
Write-Host ('  VEREDITO: ' + $r.veredito) -ForegroundColor $cor
Write-Host ('  ' + $r.acao)
Write-Host ''

[pscustomobject]$r
