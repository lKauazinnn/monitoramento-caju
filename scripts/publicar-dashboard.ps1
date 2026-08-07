<#
.SYNOPSIS
  Publica o dashboard na Vercel.

.DESCRIPTION
  So o dashboard vai para a Vercel. A ingestao e o banco ja estao no Supabase e
  sao alcancaveis de qualquer rede — o dashboard e a unica peca que ainda vive
  nesta maquina.

  MONTA UMA COPIA e publica dela, em vez de mexer no dashboard/ do repositorio.
  Assim a sua stack local continua funcionando com o config.js dela enquanto a
  producao roda com o de producao: os dois convivem, e nao ha aquele momento de
  "esqueci de voltar o arquivo".

  O que ele NAO publica esta no .vercelignore, e a razao de cada um esta la. O
  mais importante: dev-config.json carrega um JWT valido da stack local.

.PARAMETER Token
  Token da Vercel, de https://vercel.com/account/tokens
  Sem ele, tenta VERCEL_TOKEN e depois a sessao do `vercel login`.

.PARAMETER Projeto
  Nome do projeto na Vercel. Padrao: monitoramento-cajupar.

.PARAMETER Preview
  Publica como preview em vez de producao. Use para conferir antes.

.EXAMPLE
  .\scripts\publicar-dashboard.ps1 -Token 'xxxxx'

.EXAMPLE
  # depois de `npx vercel login`
  .\scripts\publicar-dashboard.ps1
#>
[CmdletBinding()]
param(
  [string] $Token,
  [string] $Projeto = 'monitoramento-cajupar',
  [switch] $Preview
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$dash = Join-Path $repoRoot 'dashboard'
$prod = Join-Path $dash 'config.producao.js'

function Ok    { param([string]$T) Write-Host "   $T" -ForegroundColor Green }
function Info  { param([string]$T) Write-Host "   $T" -ForegroundColor DarkGray }
function Aviso { param([string]$T) Write-Host "   $T" -ForegroundColor Yellow }
function Erro  { param([string]$T) Write-Host "   $T" -ForegroundColor Red }
function Passo { param([string]$T) Write-Host ''; Write-Host "== $T ==" -ForegroundColor Cyan }

function Exec {
  param([string] $Arquivo, [string[]] $Argumentos = @(), [switch] $Mostrar)
  $anterior = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $saida = & $Arquivo @Argumentos 2>&1 | ForEach-Object { "$_" }
    $codigo = $LASTEXITCODE
  } finally { $ErrorActionPreference = $anterior }
  if ($Mostrar) { $saida | ForEach-Object { Info $_ } }
  return [pscustomobject]@{ Codigo = $codigo; Saida = $saida }
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' Publicando o dashboard na Vercel' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan

# ---------------------------------------------------------------------------
Passo 'Conferindo o que vai ser publicado'
# ---------------------------------------------------------------------------
if (-not (Test-Path $prod)) {
  Erro 'dashboard/config.producao.js nao existe.'
  Aviso 'Publique a producao primeiro:'
  Write-Host '     .\scripts\publicar-supabase.ps1 -ProjetoRef SEU_REF -AnonKey ... -EmailAdmin ... -SenhaAdmin ...' -ForegroundColor DarkGray
  exit 1
}

$conteudoProd = Get-Content $prod -Raw

# A protecao que mais importa aqui. Publicar com a configuracao LOCAL poe no ar
# um dashboard que aponta para 127.0.0.1: ele carrega, nao acha a API e mostra a
# faixa de erro para quem abrir. Pior, o modo local NAO PEDE LOGIN — e um painel
# sem login na internet, mesmo que sem dado nenhum, e o tipo de coisa que nao
# pode depender de ninguem lembrar de trocar um arquivo.
if ($conteudoProd -notmatch "authMode:\s*'supabase'") {
  Erro 'config.producao.js nao esta em authMode supabase. Nao vou publicar.'
  exit 1
}
if ($conteudoProd -match '127\.0\.0\.1|localhost') {
  Erro 'config.producao.js referencia 127.0.0.1. Nao vou publicar.'
  exit 1
}
if ($conteudoProd -notmatch "restUrl:\s*'https://") {
  Erro 'config.producao.js sem restUrl em https. Nao vou publicar.'
  exit 1
}
Ok 'configuracao de producao: authMode supabase, restUrl em https'

# A CSP e verificada antes de subir: se ela quebra a pagina, quebra publicada.
$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
  $r = Exec -Arquivo $node.Source -Argumentos @((Join-Path $PSScriptRoot 'verificar-csp.mjs'))
  if ($r.Codigo -ne 0) {
    $r.Saida | ForEach-Object { Erro $_ }
    Erro 'a CSP quebra a pagina. Nada foi publicado.'
    exit 1
  }
  Ok ($r.Saida | Where-Object { $_ -match 'VERIFICACOES DE CSP' } | Select-Object -Last 1)
} else {
  Aviso 'node ausente: verificacao de CSP pulada'
}

# ---------------------------------------------------------------------------
Passo 'Montando a copia'
# ---------------------------------------------------------------------------
# Copia em vez de mexer no dashboard/: a stack local continua com o config.js
# dela, e nao existe o momento "esqueci de voltar o arquivo".
$saida = Join-Path ([System.IO.Path]::GetTempPath()) "dash-vercel-$(Get-Date -Format 'yyyyMMddHHmmss')"
New-Item -ItemType Directory -Force -Path $saida | Out-Null

$naoVao = @('dev-config.json', 'dev-token.json', 'diagnostico.html', 'config.producao.js', '.vercelignore')

Get-ChildItem $dash -Recurse -File | ForEach-Object {
  $rel = $_.FullName.Substring($dash.Length + 1)
  if ($naoVao -contains $_.Name) { Info "fora: $rel"; return }

  $destino = Join-Path $saida $rel
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destino) | Out-Null
  Copy-Item $_.FullName $destino -Force
}

# O config.js da copia e o de PRODUCAO.
Copy-Item $prod (Join-Path $saida 'config.js') -Force
Ok 'config.js da copia substituido pelo de producao'

# Rede de seguranca: conferir o resultado, e nao a intencao. Um erro na montagem
# acima passaria despercebido ate a pagina estar no ar.
$vazou = @()
foreach ($proibido in @('dev-config.json', 'dev-token.json', 'diagnostico.html')) {
  if (Test-Path (Join-Path $saida $proibido)) { $vazou += $proibido }
}
$cfgCopia = Get-Content (Join-Path $saida 'config.js') -Raw
if ($cfgCopia -notmatch "authMode:\s*'supabase'") { $vazou += 'config.js NAO e o de producao' }

if ($vazou.Count -gt 0) {
  Erro ('a copia contem o que nao deveria: ' + ($vazou -join ', '))
  Remove-Item $saida -Recurse -Force -ErrorAction SilentlyContinue
  exit 1
}

$arquivos = Get-ChildItem $saida -Recurse -File
Ok "$($arquivos.Count) arquivo(s), $([math]::Round((($arquivos | Measure-Object Length -Sum).Sum) / 1KB)) KB"
$arquivos | ForEach-Object { Info ('  ' + $_.FullName.Substring($saida.Length + 1)) }

# ---------------------------------------------------------------------------
Passo 'Publicando'
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Token)) { $Token = $env:VERCEL_TOKEN }

$npx = Get-Command npx -ErrorAction SilentlyContinue
if (-not $npx) { Erro 'npx nao encontrado (precisa do Node).'; exit 1 }

$args = @('--yes', 'vercel@latest', 'deploy', $saida, '--yes', '--name', $Projeto)
if (-not $Preview) { $args += '--prod' }
if ($Token) { $args += @('--token', $Token); Ok 'token recebido' }
else {
  Aviso 'sem token: usando a sessao do `vercel login`.'
  Aviso 'Se nao houver sessao, o comando vai travar pedindo login — cancele e rode:'
  Write-Host '     npx vercel login' -ForegroundColor DarkGray
}

$r = Exec -Arquivo $npx.Source -Argumentos $args -Mostrar

if ($r.Codigo -ne 0) {
  Erro 'o deploy falhou.'
  Remove-Item $saida -Recurse -Force -ErrorAction SilentlyContinue
  exit 1
}

$url = $r.Saida | Where-Object { $_ -match '^https://\S+\.vercel\.app' } | Select-Object -Last 1
Remove-Item $saida -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '============================================================' -ForegroundColor Green
Write-Host ' DASHBOARD PUBLICADO' -ForegroundColor Green
Write-Host '============================================================' -ForegroundColor Green
if ($url) { Write-Host "  $url" }
Write-Host ''
Write-Host '  O login e OBRIGATORIO aqui — o atalho sem senha existe apenas na' -ForegroundColor Yellow
Write-Host '  stack local, que escuta so em loopback.' -ForegroundColor Yellow
Write-Host '============================================================' -ForegroundColor Green
Write-Host ''
