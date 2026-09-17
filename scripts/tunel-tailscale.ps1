<#
.SYNOPSIS
  Poe a stack self-hosted num endereco publico FIXO, com HTTPS, que volta sozinho
  depois de reiniciar a maquina. Roda NA MAQUINA SERVIDORA.

.DESCRIPTION
  POR QUE TAILSCALE E NAO CLOUDFLARE

    O que subiu no dia 15 foi tunel RAPIDO (trycloudflare): ele sorteia um
    hostname novo a cada partida e vive numa janela aberta. Isso nao e defeito de
    configuracao, e o desenho do produto -- e por isso o subir-servidor.ps1 avisa
    em vez de fingir que resolveu.

    Tunel NOMEADO da Cloudflare resolveria, mas exige um dominio dentro da conta
    Cloudflare. Comprar dominio foi recusado e mexer no DNS do cajupar.com
    tambem, pelo risco de derrubar o e-mail da empresa. Sem uma dessas duas
    coisas, a Cloudflare nao tem como entregar endereco fixo.

    O Funnel do Tailscale entrega as tres coisas que faltam, sem dominio e sem
    tocar em DNS nenhum:

      hostname estavel   <maquina>.<tailnet>.ts.net, o mesmo depois de todo boot
      HTTPS de verdade   certificado emitido e renovado pelo proprio Tailscale,
                         e o agente RECUSA o que nao for https (AgentConfig.cs)
      servico do Windows  o tailscaled sobe ANTES do login, ao contrario do
                         Docker Desktop

  O QUE ESTE SCRIPT NAO RESOLVE, e e importante dizer com todas as letras

    O endereco volta sozinho; o que esta ATRAS dele, nao. O Docker Desktop e
    aplicativo de usuario: depois de um reboot, enquanto ninguem logar na
    maquina, o Funnel responde 502 -- de pe, porem sem nada atras. Ficou
    decidido conviver com isso por ora. Enquanto for assim, reboot ainda
    significa "alguem precisa logar", e o 502 e o sintoma que vai aparecer.

  QUEM CONSOME ESTE ENDERECO

    o painel na Vercel        dashboard/config.js -> restUrl = https://<host>/rest/v1
    os agentes da frota       %ProgramData%\MonitorAgent\config.json -> ingestUrl
                              = https://<host>/functions/v1/ingest

    Trocar de endereco significa reescrever o config.json de CADA maquina: o
    agente nao redescobre nada sozinho. E a razao de o endereco precisar ser
    fixo de uma vez, e nao "fixo ate o proximo reboot".

.PARAMETER Porta
  Porta local da stack. Padrao: o WEB_PORT do .env.selfhost, ou 2121.

.PARAMETER Instalar
  Instala o Tailscale via winget, se faltar. Precisa de terminal ELEVADO.

.PARAMETER Conferir
  So mede e relata. Nao liga nem muda nada.

.EXAMPLE
  .\scripts\tunel-tailscale.ps1 -Conferir

.EXAMPLE
  .\scripts\tunel-tailscale.ps1
#>
[CmdletBinding()]
param(
  [int]    $Porta,
  [switch] $Instalar,
  [switch] $Conferir,
  [string] $Raiz
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Raiz)) { $Raiz = Split-Path -Parent $PSScriptRoot }

$logDir = Join-Path $Raiz 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$log = Join-Path $logDir 'tunel-tailscale.log'

function Registrar {
  param([string] $Nivel, [string] $Texto)
  $linha = '{0} {1} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Nivel, $Texto
  $cor = switch ($Nivel) { 'ERRO' { 'Red' } 'AVI' { 'Yellow' } 'OK' { 'Green' } default { 'Gray' } }
  Write-Host $linha -ForegroundColor $cor
  try { Add-Content -Path $log -Value $linha -Encoding utf8 } catch { }
}

# O psql, o docker e o tailscale escrevem rotina no stderr. No PowerShell 5.1
# cada linha de stderr de programa nativo vira ErrorRecord, e com
# ErrorActionPreference='Stop' o proprio aviso de sucesso mata o script. Quem
# decide sucesso aqui e o $LASTEXITCODE.
function Invocar([scriptblock] $Bloco) {
  $antes = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $Bloco } finally { $ErrorActionPreference = $antes }
}

# ---------------------------------------------------------------------------
# 1. A porta local, lida de onde ela realmente vale
# ---------------------------------------------------------------------------
if (-not $Porta) {
  $Porta = 2121
  $envPath = Join-Path $Raiz '.env.selfhost'
  if (Test-Path $envPath) {
    foreach ($linha in (Get-Content $envPath)) {
      if ($linha -match '^\s*WEB_PORT\s*=\s*(\d+)') { $Porta = [int]$Matches[1] }
    }
  }
}
Registrar 'INF' "porta local da stack: $Porta"

# ---------------------------------------------------------------------------
# 2. O executavel
# ---------------------------------------------------------------------------
$ts = $null
$cmd = Get-Command tailscale -ErrorAction SilentlyContinue
if ($cmd) { $ts = $cmd.Source }
if (-not $ts) {
  $padrao = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
  if (Test-Path $padrao) { $ts = $padrao }
}

if (-not $ts) {
  if (-not $Instalar) {
    Registrar 'ERRO' 'Tailscale nao esta instalado nesta maquina.'
    Registrar 'INF' 'Instale e rode de novo:  .\scripts\tunel-tailscale.ps1 -Instalar'
    Registrar 'INF' 'Ou baixe de https://tailscale.com/download/windows'
    exit 1
  }
  Registrar 'INF' 'instalando o Tailscale via winget...'
  Invocar { winget install --id Tailscale.Tailscale -e --accept-source-agreements --accept-package-agreements }
  if ($LASTEXITCODE -ne 0) {
    Registrar 'ERRO' "winget falhou (codigo $LASTEXITCODE). Instale a mao: https://tailscale.com/download/windows"
    exit 1
  }
  $padrao = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
  if (-not (Test-Path $padrao)) {
    Registrar 'ERRO' 'instalou mas nao achei o tailscale.exe. Abra um terminal novo e rode de novo.'
    exit 1
  }
  $ts = $padrao
}
Registrar 'OK' "tailscale: $ts"

# ---------------------------------------------------------------------------
# 3. O servico -- e este e o item que faz o endereco voltar sozinho no boot
# ---------------------------------------------------------------------------
$svc = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
if ($null -eq $svc) { $svc = Get-Service -Name 'tailscaled' -ErrorAction SilentlyContinue }

if ($null -eq $svc) {
  Registrar 'AVI' 'nao achei o servico do Tailscale. Sem ele o tunel NAO volta sozinho.'
} else {
  Registrar 'INF' "servico $($svc.Name): $($svc.Status), inicio=$((Get-WmiObject Win32_Service -Filter "Name='$($svc.Name)'").StartMode)"
  if ($svc.Status -ne 'Running' -and -not $Conferir) {
    try { Start-Service $svc.Name; Registrar 'OK' 'servico iniciado.' }
    catch { Registrar 'ERRO' "nao consegui iniciar: $($_.Exception.Message)" }
  }
}

# ---------------------------------------------------------------------------
# 4. Esta maquina esta logada no tailnet?
# ---------------------------------------------------------------------------
$estadoJson = Invocar { & $ts status --json }
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($estadoJson | Out-String).Trim())) {
  Registrar 'ERRO' 'tailscale status nao respondeu. O servico esta rodando?'
  exit 1
}

$estado = ($estadoJson | Out-String) | ConvertFrom-Json
Registrar 'INF' "estado do backend: $($estado.BackendState)"

if ($estado.BackendState -ne 'Running') {
  Registrar 'AVI' 'esta maquina ainda NAO entrou no tailnet.'
  Registrar 'INF' 'Rode, NESTA maquina e num terminal visivel:'
  Registrar 'INF' "   & '$ts' up"
  Registrar 'INF' 'Ele imprime um endereco para autenticar no navegador. E uma vez so:'
  Registrar 'INF' 'depois disso a maquina reentra sozinha a cada boot.'
  exit 1
}

$host_ts = "$($estado.Self.DNSName)".TrimEnd('.')
if ([string]::IsNullOrWhiteSpace($host_ts)) {
  Registrar 'ERRO' 'nao consegui ler o hostname (Self.DNSName vazio).'
  exit 1
}
Registrar 'OK' "hostname fixo desta maquina: $host_ts"

# ---------------------------------------------------------------------------
# 5. Ligar o Funnel
# ---------------------------------------------------------------------------
# --bg e o que separa isto do trycloudflare: sem ele o comando fica preso no
# terminal e morre junto com a janela, que foi exatamente o problema do dia 15.
# Com --bg a configuracao fica GRAVADA no tailscaled e volta com o servico.
#
# Se o Funnel nao estiver liberado no tailnet, o proprio comando imprime o
# endereco do painel de administracao para liberar. Por isso a saida dele vai
# inteira para a tela: engolir essa mensagem seria esconder a unica instrucao
# que resolve.
if (-not $Conferir) {
  Registrar 'INF' "ligando o Funnel: publico 443 -> http://127.0.0.1:$Porta"
  Invocar { & $ts funnel --bg "http://127.0.0.1:$Porta" }
  if ($LASTEXITCODE -ne 0) {
    Registrar 'ERRO' "o comando funnel falhou (codigo $LASTEXITCODE). Leia a mensagem acima."
    Registrar 'INF' 'O caso mais comum: Funnel ainda nao liberado para este tailnet.'
    exit 1
  }
}

Registrar 'INF' 'configuracao atual do Funnel:'
Invocar { & $ts funnel status }

# ---------------------------------------------------------------------------
# 6. CONFERIR SERVINDO, de fora para dentro
# ---------------------------------------------------------------------------
# Sai desta maquina, passa pela borda do Tailscale e volta. E o unico teste que
# prova o caminho inteiro -- "funnel status" so diz o que foi CONFIGURADO.
$urlSaude = "https://$host_ts/functions/v1/ingest/healthz"
Registrar 'INF' "conferindo $urlSaude"

$codigo = 0
$erro = ''
try {
  $r = Invoke-WebRequest -Uri $urlSaude -TimeoutSec 20 -UseBasicParsing
  $codigo = [int]$r.StatusCode
} catch {
  if ($_.Exception.Response) { $codigo = [int]$_.Exception.Response.StatusCode }
  $erro = $_.Exception.Message
}

if ($codigo -eq 200) {
  Registrar 'OK' 'endereco publico respondendo 200. Caminho completo funcionando.'
} elseif ($codigo -ge 500) {
  Registrar 'AVI' "o Funnel esta de pe, mas a stack atras dele nao respondeu (HTTP $codigo)."
  Registrar 'AVI' 'E o sintoma esperado com o Docker parado: suba com .\scripts\subir-servidor.ps1'
} elseif ($codigo -gt 0) {
  Registrar 'AVI' "resposta inesperada: HTTP $codigo"
} else {
  Registrar 'AVI' "sem resposta: $erro"
  Registrar 'AVI' 'Na PRIMEIRA vez o certificado leva ate uns minutos para ser emitido.'
  Registrar 'AVI' 'Espere e rode com -Conferir.'
}

# ---------------------------------------------------------------------------
# 7. O endereco, escrito onde nao se perde
# ---------------------------------------------------------------------------
$arqEndereco = Join-Path $logDir 'endereco-publico.txt'
$conteudo = @(
  "# Endereco publico fixo da stack self-hosted -- gerado por tunel-tailscale.ps1",
  "# $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
  "https://$host_ts",
  "",
  "# painel (dashboard/config.js na Vercel):",
  "restUrl: 'https://$host_ts/rest/v1'",
  "",
  "# agente (%ProgramData%\MonitorAgent\config.json em cada maquina):",
  "`"ingestUrl`": `"https://$host_ts/functions/v1/ingest`""
)
Set-Content -Path $arqEndereco -Value $conteudo -Encoding utf8
Registrar 'OK' "endereco anotado em $arqEndereco"

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host " ENDERECO FIXO:  https://$host_ts" -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host ' Proximos passos, nesta ordem:' -ForegroundColor Cyan
Write-Host "   1. dashboard/config.js da Vercel -> restUrl = https://$host_ts/rest/v1"
Write-Host '   2. publicar o painel (scripts\publicar-dashboard.ps1)'
Write-Host "   3. agentes -> ingestUrl = https://$host_ts/functions/v1/ingest"
Write-Host ''
Write-Host ' Lembrete honesto: este endereco volta sozinho depois do reboot,' -ForegroundColor Yellow
Write-Host ' mas a stack atras dele nao -- o Docker Desktop so sobe com alguem' -ForegroundColor Yellow
Write-Host ' logado na maquina. Ate isso mudar, reboot = 502 ate alguem logar.' -ForegroundColor Yellow
exit 0
