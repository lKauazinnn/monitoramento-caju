<#
.SYNOPSIS
  Troca a senha de um usuario do dashboard em producao.

.DESCRIPTION
  A senha vive no Auth do Supabase, nao no banco da aplicacao — entao nao adianta
  procurar em app_users, que e a tabela do modo LOCAL. A troca vai pela API de
  administracao do Auth.

  Depois de trocar, ele CONFERE fazendo login de verdade com a senha nova e a
  anon key. Trocar sem conferir deixa a duvida mais cara possivel: voce so
  descobre que nao funcionou na frente da tela de login.

.PARAMETER Email
  Usuario a alterar. Padrao: o unico admin, se houver so um.

.PARAMETER NovaSenha
  Se omitida, e pedida no terminal sem aparecer na tela.

.PARAMETER ChaveServiceRole
  service_role key. Tenta SUPABASE_SERVICE_ROLE_KEY e depois pergunta.

.PARAMETER AnonKey
  anon key, usada so para conferir o login. Sem ela, a conferencia e pulada.

.EXAMPLE
  .\scripts\trocar-senha-producao.ps1 -Email kaualarsson@cajupar.com
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string] $Email,
  [string] $NovaSenha,
  [string] $ChaveServiceRole,
  [string] $AnonKey
)

$ErrorActionPreference = 'Stop'

foreach ($nome in @('Tls12', 'Tls13')) {
  try {
    $valor = [Enum]::Parse([Net.SecurityProtocolType], $nome)
    [Net.ServicePointManager]::SecurityProtocol =
      [Net.ServicePointManager]::SecurityProtocol -bor $valor
  } catch { }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$envProducao = Join-Path $repoRoot '.env.producao'

function Ok    { param([string]$T) Write-Host "   $T" -ForegroundColor Green }
function Info  { param([string]$T) Write-Host "   $T" -ForegroundColor DarkGray }
function Aviso { param([string]$T) Write-Host "   $T" -ForegroundColor Yellow }
function Erro  { param([string]$T) Write-Host "   $T" -ForegroundColor Red }
function Passo { param([string]$T) Write-Host ''; Write-Host "== $T ==" -ForegroundColor Cyan }

function LerSegredoOculto {
  param([string] $Rotulo)
  $seguro = Read-Host -Prompt "   $Rotulo" -AsSecureString
  $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($seguro)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Lista {
  param($Resposta)
  if ($null -eq $Resposta) { return @() }
  return @($Resposta | ForEach-Object { $_ })
}

if (-not (Test-Path $envProducao)) {
  Erro '.env.producao nao existe. Publique a producao primeiro.'
  exit 1
}

$cfg = @{}
Get-Content $envProducao | ForEach-Object {
  if ($_ -match '^\s*([A-Z_]+)=(.*)$') { $cfg[$Matches[1]] = $Matches[2].Trim() }
}
$base = $cfg['SUPABASE_URL']

if ([string]::IsNullOrWhiteSpace($ChaveServiceRole)) { $ChaveServiceRole = $env:SUPABASE_SERVICE_ROLE_KEY }
if ([string]::IsNullOrWhiteSpace($ChaveServiceRole)) {
  Info 'service_role key (Settings > API). Nao aparece na tela.'
  $ChaveServiceRole = LerSegredoOculto 'service_role key:'
}
if ([string]::IsNullOrWhiteSpace($NovaSenha)) {
  $NovaSenha = LerSegredoOculto 'nova senha:'
}

if ($NovaSenha.Length -lt 6) {
  Erro 'o Supabase recusa senha com menos de 6 caracteres.'
  exit 1
}

$cab = @{
  apikey         = $ChaveServiceRole
  Authorization  = "Bearer $ChaveServiceRole"
  'Content-Type' = 'application/json'
}

# ---------------------------------------------------------------------------
Passo 'Localizando o usuario'
# ---------------------------------------------------------------------------
try {
  $lista = Invoke-RestMethod -Uri "$base/auth/v1/admin/users?per_page=200" -Headers $cab -TimeoutSec 30
} catch {
  Erro "nao consegui listar usuarios: $($_.Exception.Message)"
  Aviso 'service_role key errada?'
  exit 1
}

$u = Lista $lista.users | Where-Object { $_.email -eq $Email } | Select-Object -First 1
if (-not $u) {
  Erro "usuario nao encontrado: $Email"
  Info ('existentes: ' + ((Lista $lista.users | ForEach-Object { $_.email }) -join ', '))
  exit 1
}
Ok "$Email  ($($u.id))"

# ---------------------------------------------------------------------------
Passo 'Trocando a senha'
# ---------------------------------------------------------------------------
try {
  Invoke-RestMethod -Uri "$base/auth/v1/admin/users/$($u.id)" -Method Put -Headers $cab -TimeoutSec 30 `
    -Body (@{ password = $NovaSenha } | ConvertTo-Json -Compress) | Out-Null
  Ok 'senha alterada'
} catch {
  Erro "falhou: $($_.Exception.Message)"
  exit 1
}

# ---------------------------------------------------------------------------
Passo 'Conferindo com um login de verdade'
# ---------------------------------------------------------------------------
# Trocar sem conferir deixa a duvida mais cara possivel: voce so descobre que nao
# funcionou na frente da tela de login.
if ([string]::IsNullOrWhiteSpace($AnonKey)) {
  $prod = Join-Path $repoRoot 'dashboard\config.producao.js'
  if (Test-Path $prod) {
    $m = Select-String -Path $prod -Pattern "anonKey:\s*'([^']+)'" -ErrorAction SilentlyContinue
    if ($m) { $AnonKey = $m.Matches.Groups[1].Value }
  }
}

if ([string]::IsNullOrWhiteSpace($AnonKey)) {
  Aviso 'sem anon key: conferencia pulada. Teste o login manualmente.'
  exit 0
}

try {
  $s = Invoke-RestMethod -Uri "$base/auth/v1/token?grant_type=password" -Method Post -TimeoutSec 30 `
        -Headers @{ apikey = $AnonKey; 'Content-Type' = 'application/json' } `
        -Body (@{ email = $Email; password = $NovaSenha } | ConvertTo-Json -Compress)

  if ($s.access_token) {
    Ok 'login com a senha nova FUNCIONA'
  } else {
    Erro 'o login nao devolveu token'
    exit 1
  }
} catch {
  Erro "o login com a senha nova falhou: $($_.Exception.Message)"
  exit 1
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Green
Write-Host " SENHA TROCADA E CONFERIDA" -ForegroundColor Green
Write-Host '============================================================' -ForegroundColor Green
Write-Host "  Usuario: $Email"
Write-Host "  Painel : $base"
Write-Host '============================================================' -ForegroundColor Green
Write-Host ''
