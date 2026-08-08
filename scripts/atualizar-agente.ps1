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

foreach ($nome in @('Tls12', 'Tls13')) {
  try {
    $v = [Enum]::Parse([Net.SecurityProtocolType], $nome)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor $v
  } catch { }
}

if (-not (Test-Path $Config)) {
  Write-Host "config.json nao encontrado em $Config" -ForegroundColor Red
  Write-Host 'Esta maquina nao tem o agente instalado. Use o comando de "Adicionar PC" do painel.' -ForegroundColor Yellow
  exit 1
}

$cfg = Get-Content $Config -Raw | ConvertFrom-Json
$dir = Split-Path -Parent $Config
$alvo = Join-Path $dir 'agente.ps1'

# O endereco da ingestao ja aponta para quem serve o agente: em producao a
# propria Edge Function, na LAN o shim local. `/ingest` no fim vira `/agente.ps1`
# no mesmo prefixo.
$base = ($cfg.ingestUrl -replace '/ingest/?$', '')
$url = "$base/agente.ps1"

Write-Host ''
Write-Host "Baixando de $url" -ForegroundColor Cyan

try {
  $novo = Invoke-RestMethod -Uri $url -TimeoutSec 30
} catch {
  Write-Host "falhou: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}

if ([string]::IsNullOrWhiteSpace($novo) -or $novo.Length -lt 5000) {
  # Um proxy de hotel devolvendo pagina de login tem 200 e corpo curto. Gravar
  # isso por cima do agente derrubaria o monitoramento da loja.
  Write-Host "o que voltou nao parece o agente ($($novo.Length) bytes)" -ForegroundColor Red
  exit 1
}

if ($novo -notmatch '\$VERSAO\s*=\s*''(ps-[0-9.]+)''') {
  Write-Host 'o que voltou nao tem versao reconhecivel; nada foi alterado' -ForegroundColor Red
  exit 1
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
  exit 0
}

# BOM obrigatorio: o PowerShell 5.1 le .ps1 SEM BOM como ANSI, e ai um acento
# vira caractere que quebra a analise sintatica. Vale para arquivo em DISCO —
# servido por HTTP para [scriptblock]::Create seria o contrario.
[IO.File]::WriteAllText($alvo, $novo, [Text.UTF8Encoding]::new($true))
Write-Host "gravado em $alvo" -ForegroundColor Green

# Reinicia a tarefa. Sem isto, o processo antigo continua rodando com o codigo
# antigo em memoria ate a maquina reiniciar, e a atualizacao parece nao ter
# funcionado.
try {
  Stop-ScheduledTask -TaskName 'MonitorAgent' -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  Start-ScheduledTask -TaskName 'MonitorAgent' -ErrorAction Stop
  Write-Host 'tarefa MonitorAgent reiniciada' -ForegroundColor Green
} catch {
  Write-Host "nao consegui reiniciar a tarefa: $($_.Exception.Message)" -ForegroundColor Yellow
  Write-Host 'Reinicie a maquina, ou rode: Start-ScheduledTask -TaskName MonitorAgent' -ForegroundColor Yellow
}

Write-Host ''
Write-Host "Agente atualizado para $versaoNova." -ForegroundColor Green
Write-Host 'Em ate 2 min o painel deve mostrar a versao nova e o MAC da placa.' -ForegroundColor DarkGray
Write-Host ''
