<#
.SYNOPSIS
  Atualiza o agente DESTA maquina para a versao mais nova, mantendo o token.

.DESCRIPTION
  A auto-atualizacao ainda nao existe (Fase 6). Ate la, um agente instalado nao
  se atualiza sozinho — e a diferenca entre versoes importa:

    ps-1.1.0  nao executa comando nenhum
    ps-1.2.0  executa comandos, mas nao reporta o MAC (nao da para ligar)
    ps-1.3.0  reporta o MAC e sabe suspender

  Reinstalar do zero funcionaria, mas gera um TOKEN NOVO e deixa o antigo
  pendurado. Este script troca so o codigo: o config.json, o token e o historico
  da maquina ficam como estao.

  Ele nao inventa o endereco: le do proprio config.json. Uma maquina que ja
  reporta sabe de onde baixar.

.PARAMETER Config
  Caminho do config.json. Padrao: %ProgramData%\MonitorAgent\config.json

.EXAMPLE
  # Na maquina a ser atualizada, como Administrador:
  .\atualizar-agente.ps1
#>
[CmdletBinding()]
param(
  [string] $Config = (Join-Path $env:ProgramData 'MonitorAgent\config.json')
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# =============================================================================
# POR QUE O CORPO INTEIRO E UMA FUNCAO
# =============================================================================
# Este script e feito para ser executado de uma linha so:
#
#   & ([scriptblock]::Create((irm 'https://.../atualizar.ps1')))
#
# E nesse modo a instrucao de saida NAO encerra o script: encerra a SESSAO do
# PowerShell. A janela simplesmente fecha, antes de a pessoa ler o que
# aconteceu — inclusive quando tudo deu certo. Foi o que aconteceu na primeira
# versao: o comando rodava, a janela sumia, e nao havia como saber o resultado.
#
# Com o corpo dentro de uma funcao, `return` sai apenas da funcao. O codigo de
# saida so vira encerramento de processo la embaixo, e SO quando o script veio
# de um arquivo (-File), onde isso e o comportamento certo.
# =============================================================================
function Invoke-AtualizacaoDoAgente {
  param([string] $Config)

  $ErrorActionPreference = 'Stop'
  [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

  foreach ($nome in @('Tls12', 'Tls13')) {
    try {
      $v = [Enum]::Parse([Net.SecurityProtocolType], $nome)
      [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor $v
    } catch { }
  }

  if (-not (Test-Path $Config)) {
    Write-Host "config.json nao encontrado em $Config" -ForegroundColor Red
    Write-Host 'Esta maquina nao tem o agente instalado. Use o comando de "Adicionar PC" do painel.' -ForegroundColor Yellow
    return 1
  }

  $cfg = Get-Content $Config -Raw | ConvertFrom-Json
  $dir = Split-Path -Parent $Config

  # QUAL arquivo o agente roda de verdade.
  #
  # Isto foi um defeito na primeira versao: eu chutei 'agente.ps1', mas o
  # instalador grava 'agente-powershell.ps1'. O script baixava, gravava, dizia
  # "atualizado para ps-1.3.0" — e criava um arquivo que NADA executa. O agente
  # real continuava na versao antiga, e a unica pista era o painel insistindo na
  # versao velha.
  #
  # A correcao nao e trocar um nome chutado por outro: e PERGUNTAR a tarefa
  # agendada qual caminho ela executa. Se um dia o instalador mudar o nome de
  # novo, isto continua certo.
  $alvo = $null
  try {
    $acao = (Get-ScheduledTask -TaskName 'MonitorAgent' -ErrorAction Stop).Actions |
              Select-Object -First 1
    if ($acao.Arguments -match '-File\s+"?([^"]+\.ps1)"?') {
      $alvo = $Matches[1]
    }
  } catch { }

  if (-not $alvo) {
    # Sem tarefa agendada (instalacao em primeiro plano): o instalador tambem usa
    # este nome. Nao inventa um terceiro.
    $alvo = Join-Path $dir 'agente-powershell.ps1'
  }

  if (-not (Test-Path $alvo)) {
    Write-Host "nao encontrei o agente em $alvo" -ForegroundColor Red
    Write-Host 'Arquivos .ps1 nesta pasta:' -ForegroundColor Yellow
    Get-ChildItem $dir -Filter *.ps1 | ForEach-Object { Write-Host "  $($_.Name)" }
    return 1
  }

  # O endereco da ingestao ja aponta para quem serve o agente: em producao a
  # propria Edge Function, na LAN o shim local. `/ingest` no fim vira `/agente.ps1`
  # no mesmo prefixo.
  # SEM remover nada do endereco. Os scripts sao servidos POR DENTRO da funcao
  # de ingestao — o instalador sempre fez "$Servidor/agente.ps1" — entao o certo
  # e acrescentar ao endereco inteiro:
  #
  #   producao: https://xxx.supabase.co/functions/v1/ingest  + /agente.ps1
  #   LAN:      http://192.168.0.10:3010                     + /agente.ps1
  #
  # A primeira versao tirava o "/ingest" do fim, e ai producao virava
  # .../functions/v1/agente.ps1 -> 404. Passou no teste local porque o endereco
  # da LAN nao tem esse sufixo: o caso quebrado era justamente o que nao era
  # testado.
  $url = $cfg.ingestUrl.TrimEnd('/') + '/agente.ps1'

  Write-Host ''
  Write-Host "Baixando de $url" -ForegroundColor Cyan

  try {
    $novo = Invoke-RestMethod -Uri $url -TimeoutSec 30
  } catch {
    Write-Host "falhou: $($_.Exception.Message)" -ForegroundColor Red
    return 1
  }

  if ([string]::IsNullOrWhiteSpace($novo) -or $novo.Length -lt 5000) {
    # Um proxy de hotel devolvendo pagina de login tem 200 e corpo curto. Gravar
    # isso por cima do agente derrubaria o monitoramento da loja.
    Write-Host "o que voltou nao parece o agente ($($novo.Length) bytes)" -ForegroundColor Red
    return 1
  }

  if ($novo -notmatch '\$VERSAO\s*=\s*''(ps-[0-9.]+)''') {
    Write-Host 'o que voltou nao tem versao reconhecivel; nada foi alterado' -ForegroundColor Red
    return 1
  }
  $versaoNova = $Matches[1]

  $versaoAtual = 'nenhuma'
  if (Test-Path $alvo) {
    $atual = Get-Content $alvo -Raw
    if ($atual -match '\$VERSAO\s*=\s*''(ps-[0-9.]+)''') { $versaoAtual = $Matches[1] }
  }

  Write-Host "atual: $versaoAtual  ->  nova: $versaoNova" -ForegroundColor Cyan

  if ($versaoAtual -eq $versaoNova) {
    Write-Host 'ja esta na versao mais nova. Nada a fazer.' -ForegroundColor Green
    return 0
  }

  # BOM obrigatorio: o PowerShell 5.1 le .ps1 SEM BOM como ANSI, e ai um acento
  # vira caractere que quebra a analise sintatica. Vale para arquivo em DISCO —
  # servido por HTTP para [scriptblock]::Create seria o contrario.
  [IO.File]::WriteAllText($alvo, $novo, [Text.UTF8Encoding]::new($true))
  Write-Host "gravado em $alvo" -ForegroundColor Green

  # Reinicia a tarefa. Sem isto, o processo antigo continua rodando com o codigo
  # antigo em memoria ate a maquina reiniciar, e a atualizacao parece nao ter
  # funcionado.
  # Duas formas de instalacao, e as duas precisam ser tratadas: tarefa agendada
  # (o padrao) e processo em primeiro plano com um .pid (o caminho sem permissao
  # de administrador). Reiniciar so uma delas deixaria o processo velho vivo com o
  # codigo velho em memoria, e a atualizacao pareceria nao ter funcionado.
  $reiniciou = $false

  try {
    Get-ScheduledTask -TaskName 'MonitorAgent' -ErrorAction Stop | Out-Null
    Stop-ScheduledTask -TaskName 'MonitorAgent' -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-ScheduledTask -TaskName 'MonitorAgent' -ErrorAction Stop
    Write-Host 'tarefa MonitorAgent reiniciada' -ForegroundColor Green
    $reiniciou = $true
  } catch { }

  $pidFile = Join-Path $dir 'agente.pid'
  if (-not $reiniciou -and (Test-Path $pidFile)) {
    try {
      $velho = [int](Get-Content $pidFile -Raw).Trim()
      Stop-Process -Id $velho -Force -ErrorAction SilentlyContinue
      Start-Sleep -Seconds 2

      $proc = Start-Process powershell.exe -PassThru -WindowStyle Hidden `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$alvo`"")
      $proc.Id | Out-File -FilePath $pidFile -Encoding ascii
      Write-Host "agente reiniciado (pid $($proc.Id))" -ForegroundColor Green
      $reiniciou = $true
    } catch {
      Write-Host "nao consegui reiniciar o processo: $($_.Exception.Message)" -ForegroundColor Yellow
    }
  }

  if (-not $reiniciou) {
    Write-Host 'o arquivo foi trocado, mas o processo antigo continua rodando.' -ForegroundColor Yellow
    Write-Host 'Reinicie a maquina para a versao nova entrar em uso.' -ForegroundColor Yellow
  }

  Write-Host ''
  Write-Host "Agente atualizado para $versaoNova." -ForegroundColor Green
  Write-Host 'Em ate 2 min o painel deve mostrar a versao nova e o MAC da placa.' -ForegroundColor DarkGray
  Write-Host ''

}

$codigo = Invoke-AtualizacaoDoAgente -Config $Config
if ($null -eq $codigo) { $codigo = 0 }

# $PSCommandPath so tem valor quando isto veio de um ARQUIVO. Como scriptblock
# ele e vazio, e ai nao ha processo proprio para encerrar — terminar aqui
# fecharia a janela de quem colou o comando.
if (-not [string]::IsNullOrEmpty($PSCommandPath)) { exit $codigo }
