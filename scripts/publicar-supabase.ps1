<#
.SYNOPSIS
  Publica o monitoramento no Supabase e VERIFICA o que subiu.

.DESCRIPTION
  Este e o caminho de producao. Ele existe porque o endpoint local
  (http://IP-DA-LAN:3010) nao serve para loja remota por dois motivos: aquele IP
  nao existe na outra rede, e HTTP puro contraria a regra 9.

  Depois de rodar isto, o comando de uma linha gerado pelo dashboard aponta para
  https://<projeto>.supabase.co/functions/v1/ingest e funciona de qualquer rede
  que tenha saida na 443 — sem VPN, sem porta liberada, sem IP publico.

  O que ele faz, na ordem:
    1. confere pre-requisitos e o que esta no repositorio
    2. roda os testes de logica pura (nao publica codigo que ja falha aqui)
    3. liga o repositorio ao projeto e aplica as migrations
    4. define o segredo compartilhado como variavel de ambiente da funcao
    5. publica a Edge Function
    6. registra endereco e segredo no banco (ingest_config)
    7. VERIFICA por HTTPS, de verdade: healthz, os dois scripts, segredo errado
       recusado, token invalido recusado e UMA INGESTAO REAL ponta a ponta
    8. grava .env.producao (ignorado pelo git) com o que voce vai precisar depois

  O passo 7 e o motivo de este script existir em vez de uma lista de comandos no
  documento. Publicar e facil; a pergunta que importa e "esta realmente no ar e
  aceitando metrica?", e essa so se responde tentando.

.PARAMETER ProjetoRef
  Referencia do projeto no Supabase. Esta na URL do painel:
  https://supabase.com/dashboard/project/SEU_REF

.PARAMETER SenhaBanco
  Senha do banco (Settings > Database). Usada apenas pelo `db push`. Se omitida,
  e pedida no terminal sem aparecer na tela.

.PARAMETER ChaveServiceRole
  service_role key (Settings > API). Usada para registrar a configuracao e para o
  teste ponta a ponta. NUNCA e gravada em arquivo. Se omitida, tenta a variavel
  de ambiente SUPABASE_SERVICE_ROLE_KEY e depois pergunta.

.PARAMETER Segredo
  Segredo compartilhado da ingestao. Gerado com 40 caracteres se omitido.
  Reaproveitado de .env.producao quando o arquivo ja existe.

.PARAMETER AnonKey
  anon key do projeto (Settings > API). E publica por desenho: o que protege os
  dados e o RLS. Usada para gerar a configuracao do dashboard.

.PARAMETER EmailAdmin
  E-mail do usuario admin do dashboard em producao. Informando este parametro
  (junto com -AnonKey e -SenhaAdmin), o script cria o usuario, concede o papel de
  admin, CONFERE que o login funciona e gera dashboard/config.producao.js.
  Sem ele, o dashboard continua apontado para a stack local.

.PARAMETER SenhaAdmin
  Senha do usuario admin do dashboard.

.PARAMETER SoVerificar
  Nao publica nada: apenas roda o passo 7 contra o que ja esta no ar. Use para
  conferir se o ambiente continua saudavel.

.EXAMPLE
  .\scripts\publicar-supabase.ps1 -ProjetoRef abcdefghijklmnopqrst

.EXAMPLE
  .\scripts\publicar-supabase.ps1 -ProjetoRef abcdefghijklmnopqrst -SoVerificar
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string] $ProjetoRef,
  [string] $SenhaBanco,
  [string] $ChaveServiceRole,
  [string] $Segredo,

  # Token pessoal de acesso (sbp_...), de
  # https://supabase.com/dashboard/account/tokens
  #
  # Evita o `supabase login`, que abre navegador. E uma credencial DIFERENTE da
  # service_role: ela administra o projeto (publicar funcao, definir segredo), e a
  # service_role administra os DADOS. Nao e gravada em arquivo.
  [string] $TokenAcesso,

  # Dashboard apontado para producao. Os tres andam juntos: sem eles, o passo e
  # pulado e o dashboard continua olhando a stack local.
  [string] $AnonKey,
  [string] $EmailAdmin,
  [string] $SenhaAdmin,

  [switch] $SoVerificar
)

$ErrorActionPreference = 'Stop'

# TLS 1.2/1.3 antes de qualquer requisicao: o PowerShell 5.1 herda o padrao do
# .NET Framework, que pode nao negociar com o Supabase.
foreach ($nome in @('Tls12', 'Tls13')) {
  try {
    $valor = [Enum]::Parse([Net.SecurityProtocolType], $nome)
    [Net.ServicePointManager]::SecurityProtocol =
      [Net.ServicePointManager]::SecurityProtocol -bor $valor
  } catch { }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$envProducao = Join-Path $repoRoot '.env.producao'

$falhas = 0
$verificacoes = 0

function Passo { param([string]$T) Write-Host ''; Write-Host "== $T ==" -ForegroundColor Cyan }
function Ok    { param([string]$T) Write-Host "   $T" -ForegroundColor Green }
function Info  { param([string]$T) Write-Host "   $T" -ForegroundColor DarkGray }
function Aviso { param([string]$T) Write-Host "   $T" -ForegroundColor Yellow }
function Erro  { param([string]$T) Write-Host "   $T" -ForegroundColor Red }

function Verificar {
  param([string] $Nome, [bool] $Condicao, [string] $Detalhe = '')
  $script:verificacoes++
  if ($Condicao) {
    Write-Host "   ok    $Nome" -ForegroundColor Green
  } else {
    $script:falhas++
    Write-Host "   FALHA $Nome" -ForegroundColor Red
    if ($Detalhe) { Write-Host "         $Detalhe" -ForegroundColor DarkGray }
  }
}

<#
  Executa programa nativo sem que a saida em stderr aborte o script.

  O `2>&1` do PowerShell embrulha cada linha de stderr num ErrorRecord, e com
  $ErrorActionPreference = 'Stop' isso encerra a execucao mesmo quando o programa
  terminou com codigo 0 — que e exatamente o caso da CLI do Supabase, que escreve
  progresso em stderr. Quem decide sucesso aqui e o codigo de saida.
#>
function Exec {
  param(
    [Parameter(Mandatory = $true)][string] $Arquivo,
    [string[]] $Argumentos = @(),
    [switch] $Mostrar
  )

  $anterior = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $saida = & $Arquivo @Argumentos 2>&1 | ForEach-Object { "$_" }
    $codigo = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $anterior
  }

  if ($Mostrar) { $saida | ForEach-Object { Info $_ } }
  return [pscustomobject]@{ Codigo = $codigo; Saida = $saida }
}

function Aleatorio {
  param([int] $Tamanho = 40)
  # RandomNumberGenerator.GetBytes(int) estatico nao existe no .NET Framework:
  # instancia e preenche buffer.
  $bytes = New-Object 'byte[]' $Tamanho
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
  $alfabeto = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
  -join ($bytes | ForEach-Object { $alfabeto[$_ % $alfabeto.Length] })
}

<#
  Normaliza a resposta do PostgREST numa lista de verdade.

  O Invoke-RestMethod do PowerShell 5.1 pode devolver um array JSON como UM item
  que CONTEM o array. Nesse caso `.Count` da 1 mesmo com N linhas, `$x[0]` devolve
  o array inteiro em vez do primeiro registro, e uma resposta vazia (`[]`) tambem
  conta 1 — os tres levam a erro que nao parece ter relacao com a causa
  ("nao e possivel converter System.Object[] em System.Double").

  A canalizacao desembrulha um nivel; o @() recolhe. Funciona igual quando a
  resposta ja vem desembrulhada.
#>
function Lista {
  param($Resposta)
  if ($null -eq $Resposta) { return @() }
  return @($Resposta | ForEach-Object { $_ })
}

function Primeiro {
  param($Resposta)
  $l = Lista $Resposta
  if ($l.Count -eq 0) { return $null }
  return $l[0]
}

function LerSegredoOculto {
  param([string] $Rotulo)
  $seguro = Read-Host -Prompt "   $Rotulo" -AsSecureString
  $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($seguro)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' Publicando o monitoramento no Supabase' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan

$ProjetoRef = $ProjetoRef.Trim()
if ($ProjetoRef -notmatch '^[a-z0-9]{16,32}$') {
  Aviso "'$ProjetoRef' nao parece uma referencia de projeto (esperado ~20 letras minusculas)."
  Aviso 'Ela esta na URL do painel: https://supabase.com/dashboard/project/SEU_REF'
}

$urlBase    = "https://$ProjetoRef.supabase.co"
$urlIngest  = "$urlBase/functions/v1/ingest"
$urlRest    = "$urlBase/rest/v1"

# ---------------------------------------------------------------------------
Passo 'Configuracao anterior'
# ---------------------------------------------------------------------------
$anterior = @{}
if (Test-Path $envProducao) {
  Get-Content $envProducao | ForEach-Object {
    if ($_ -match '^\s*([A-Z_]+)=(.*)$') { $anterior[$Matches[1]] = $Matches[2].Trim() }
  }
  Ok ".env.producao encontrado ($($anterior.Count) valores)"
} else {
  Info '.env.producao ainda nao existe (primeira publicacao)'
}

if ([string]::IsNullOrWhiteSpace($Segredo)) {
  if ($anterior['INGEST_SHARED_SECRET']) {
    $Segredo = $anterior['INGEST_SHARED_SECRET']
    Info 'segredo compartilhado reaproveitado de .env.producao'
  } else {
    $Segredo = Aleatorio 40
    Ok 'segredo compartilhado gerado (40 caracteres)'
  }
}

if ($Segredo.Length -lt 24) {
  Erro "o segredo precisa de ao menos 24 caracteres (tem $($Segredo.Length))."
  Erro 'A funcao recusa segredo curto na PARTIDA, para nao ficar no ar mal protegida.'
  exit 1
}

if ([string]::IsNullOrWhiteSpace($ChaveServiceRole)) {
  $ChaveServiceRole = $env:SUPABASE_SERVICE_ROLE_KEY
}

# ---------------------------------------------------------------------------
Passo 'Pre-requisitos'
# ---------------------------------------------------------------------------
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { Erro 'node nao encontrado no PATH.'; exit 1 }
Ok "node: $($node.Version)"

# CLI do Supabase.
#
# NAO existe pacote no winget (`Supabase.CLI` nao e um id valido) e o
# `npm i -g supabase` foi descontinuado pelo proprio projeto. O que sempre
# funciona e o binario da release do GitHub — entao o script o baixa sozinho, em
# tools\supabase\, fora do git. "Instale a CLI antes" e justamente o passo em que
# se perde tempo, e ele nao precisa existir.
$cliArquivo = $null
$cliBase = @()
$cliLocal = Join-Path $repoRoot 'tools\supabase\supabase.exe'

$supa = Get-Command supabase -ErrorAction SilentlyContinue
if ($supa) {
  $cliArquivo = $supa.Source
  Ok "supabase CLI: $($supa.Source)"
} elseif (Test-Path $cliLocal) {
  $cliArquivo = $cliLocal
  Ok 'supabase CLI: tools\supabase\supabase.exe'
} elseif (-not $SoVerificar) {
  Info 'CLI do Supabase ausente; baixando a release do GitHub (~72 MB)'

  $arq = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }

  try {
    $rel = Invoke-RestMethod 'https://api.github.com/repos/supabase/cli/releases/latest' `
             -Headers @{ 'User-Agent' = 'monitoramento-caju' } -TimeoutSec 60
    $asset = $rel.assets | Where-Object { $_.name -eq "supabase_$($rel.tag_name.TrimStart('v'))_windows_$arq.zip" } |
               Select-Object -First 1
    if (-not $asset) { throw "release $($rel.tag_name) sem pacote windows_$arq" }

    $zip = Join-Path $env:TEMP 'supabase-cli.zip'
    $pasta = Join-Path $repoRoot 'tools\supabase'
    New-Item -ItemType Directory -Force -Path $pasta | Out-Null

    # Sem a barra de progresso: no PowerShell 5.1 ela custa mais tempo que o
    # proprio download quando a saida nao e um console interativo.
    $pb = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
      Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -TimeoutSec 900
    } finally {
      $ProgressPreference = $pb
    }

    Expand-Archive -Path $zip -DestinationPath $pasta -Force
    Remove-Item $zip -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path $cliLocal)) { throw 'o pacote nao trouxe supabase.exe' }
    $cliArquivo = $cliLocal
    Ok "supabase CLI $($rel.tag_name) baixada para tools\supabase\"
  } catch {
    Erro "nao foi possivel baixar a CLI: $($_.Exception.Message)"
    Write-Host ''
    Aviso 'Baixe manualmente e extraia em tools\supabase\:'
    Write-Host '     https://github.com/supabase/cli/releases/latest' -ForegroundColor DarkGray
    Aviso 'Ou instale com o scoop:'
    Write-Host '     scoop bucket add supabase https://github.com/supabase/scoop-bucket.git' -ForegroundColor DarkGray
    Write-Host '     scoop install supabase' -ForegroundColor DarkGray
    exit 1
  }
}

# O token pessoal autentica a CLI sem abrir navegador. Vive so nesta sessao de
# processo: nao vai para arquivo nem para o ambiente do usuario.
if (-not [string]::IsNullOrWhiteSpace($TokenAcesso)) {
  $env:SUPABASE_ACCESS_TOKEN = $TokenAcesso.Trim()
  Ok 'token de acesso recebido por parametro'
}

function Supa {
  param([string[]] $Argumentos, [switch] $Mostrar)
  return Exec -Arquivo $cliArquivo -Argumentos ($cliBase + $Argumentos) -Mostrar:$Mostrar
}

if (-not $SoVerificar) {
  $r = Supa @('--version')
  if ($r.Codigo -ne 0) {
    $r.Saida | ForEach-Object { Erro $_ }
    Erro 'a CLI do Supabase nao respondeu.'
    exit 1
  }
  Ok "CLI versao $($r.Saida -join ' ')"
}

# ---------------------------------------------------------------------------
Passo 'Conferindo o repositorio'
# ---------------------------------------------------------------------------
# Os .ps1 servidos em HTTPS estao EMBUTIDOS num modulo gerado. Se o gerado ficou
# atras do original, a loja remota baixaria uma versao velha do agente sem
# ninguem perceber — e o sintoma apareceria dias depois, na maquina errada.
$r = Exec -Arquivo $node.Source -Argumentos @((Join-Path $PSScriptRoot 'gerar-scripts-embutidos.mjs'), '--verificar')
if ($r.Codigo -ne 0) {
  $r.Saida | ForEach-Object { Erro $_ }
  Erro 'regere os scripts embutidos antes de publicar:'
  Write-Host '     node scripts\gerar-scripts-embutidos.mjs' -ForegroundColor DarkGray
  exit 1
}
Ok 'scripts embutidos em dia com os .ps1 de origem'

if (-not $SoVerificar) {
  $r = Exec -Arquivo $node.Source -Argumentos @((Join-Path $repoRoot 'supabase\functions\ingest\lib.test.mjs'))
  if ($r.Codigo -ne 0) {
    $r.Saida | ForEach-Object { Erro $_ }
    Erro 'os testes da logica da funcao falharam. Nada foi publicado.'
    exit 1
  }
  Ok ($r.Saida | Where-Object { $_ -match 'TESTES' } | Select-Object -Last 1)
}

# ---------------------------------------------------------------------------
if (-not $SoVerificar) {
  Passo 'Ligando ao projeto'
  # -------------------------------------------------------------------------
  # config.toml precisa existir para o `link`, e nele mora `verify_jwt = false`.
  # A flag --no-verify-jwt do deploy esta em desuso nas versoes novas da CLI; o
  # arquivo e o caminho que continua valendo. Os dois juntos cobrem as duas
  # versoes, e a regra 6 segue satisfeita porque a FUNCAO valida o segredo
  # compartilhado dela mesma antes de tocar no banco.
  $configToml = Join-Path $repoRoot 'supabase\config.toml'
  $conteudoToml = @"
# Gerado por scripts/publicar-supabase.ps1. Fora do git: nomeia o seu projeto.
project_id = "$ProjetoRef"

[functions.ingest]
# Os agentes nao possuem JWT do Supabase — eles tem o token proprio da maquina.
# Por isso a verificacao do gateway fica desligada, e em troca a funcao valida um
# segredo compartilhado proprio, em tempo constante, antes de qualquer coisa.
verify_jwt = false
"@
  [System.IO.File]::WriteAllText($configToml, $conteudoToml, (New-Object System.Text.UTF8Encoding($false)))
  Ok 'supabase/config.toml gerado (verify_jwt = false para a funcao ingest)'

  if ([string]::IsNullOrWhiteSpace($env:SUPABASE_ACCESS_TOKEN)) {
    Aviso 'sem token de acesso: a CLI vai pedir `supabase login` (abre navegador).'
    Aviso 'Para evitar isso, rode com -TokenAcesso sbp_...'
    Info  'crie o token em https://supabase.com/dashboard/account/tokens'
  }

  $r = Supa @('link', '--project-ref', $ProjetoRef) -Mostrar
  if ($r.Codigo -ne 0) {
    Erro 'nao foi possivel ligar ao projeto.'
    Aviso 'Se a mensagem fala de autenticacao, rode primeiro:  supabase login'
    exit 1
  }
  Ok "ligado ao projeto $ProjetoRef"

  # -------------------------------------------------------------------------
  Passo 'Aplicando as migrations'
  # -------------------------------------------------------------------------
  if ([string]::IsNullOrWhiteSpace($SenhaBanco)) {
    Info 'senha do banco (Settings > Database). Nao aparece na tela.'
    $SenhaBanco = LerSegredoOculto 'senha do banco:'
  }

  $r = Supa @('db', 'push', '--password', $SenhaBanco) -Mostrar
  if ($r.Codigo -ne 0) {
    Erro 'db push falhou.'
    Aviso 'Alternativa: cole os arquivos de supabase/migrations no SQL Editor, NA ORDEM do nome.'
    exit 1
  }
  Ok 'migrations aplicadas'

  # -------------------------------------------------------------------------
  Passo 'Definindo o segredo da funcao'
  # -------------------------------------------------------------------------
  # SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY sao injetados pela plataforma. Só o
  # segredo compartilhado e nosso — e ele existe somente como variavel de
  # ambiente do lado servidor (regra 1).
  $r = Supa @('secrets', 'set', "INGEST_SHARED_SECRET=$Segredo")
  if ($r.Codigo -ne 0) {
    $r.Saida | ForEach-Object { Erro $_ }
    Erro 'nao foi possivel definir INGEST_SHARED_SECRET.'
    exit 1
  }
  Ok 'INGEST_SHARED_SECRET definido no projeto'

  # -------------------------------------------------------------------------
  Passo 'Publicando a Edge Function'
  # -------------------------------------------------------------------------
  $r = Supa @('functions', 'deploy', 'ingest', '--no-verify-jwt') -Mostrar
  if ($r.Codigo -ne 0) {
    # Versoes novas removeram a flag. Repete sem ela: o config.toml ja cobre.
    Aviso 'deploy com --no-verify-jwt falhou; tentando sem a flag (config.toml cobre)'
    $r = Supa @('functions', 'deploy', 'ingest') -Mostrar
  }
  if ($r.Codigo -ne 0) {
    Erro 'deploy da funcao falhou.'
    exit 1
  }
  Ok "funcao publicada em $urlIngest"
}

# ---------------------------------------------------------------------------
Passo 'Registrando o endereco da ingestao no banco'
# ---------------------------------------------------------------------------
# O dashboard monta o comando de instalacao com o que esta AQUI, nao com o que
# esta em arquivo de configuracao do navegador. Por isso este passo: sem ele, o
# comando sairia apontando para o endereco antigo.
if ([string]::IsNullOrWhiteSpace($ChaveServiceRole)) {
  Info 'service_role key (Settings > API). Nao aparece na tela e nao vai para arquivo.'
  $ChaveServiceRole = LerSegredoOculto 'service_role key:'
}

$cabServico = @{
  apikey          = $ChaveServiceRole
  Authorization   = "Bearer $ChaveServiceRole"
  'Content-Type'  = 'application/json'
}

try {
  $corpo = @{ p_url = $urlIngest; p_secret = $Segredo } | ConvertTo-Json -Compress
  $res = Invoke-RestMethod -Uri "$urlRest/rpc/definir_ingestao" -Method Post `
           -Headers $cabServico -Body $corpo -TimeoutSec 30
  Ok "ingestao apontada para $($res.ingest_url) (https: $($res.https))"
} catch {
  Erro "nao foi possivel registrar a configuracao: $($_.Exception.Message)"
  Aviso 'Causas comuns:'
  Write-Host '     - service_role key errada' -ForegroundColor DarkGray
  Write-Host '     - migration 0017 nao aplicada (rode sem -SoVerificar)' -ForegroundColor DarkGray
  exit 1
}

# ---------------------------------------------------------------------------
Passo 'Verificando o que esta no ar'
# ---------------------------------------------------------------------------
# Publicar e facil. A pergunta que importa e se esta aceitando metrica de
# verdade, e ela so se responde tentando.

# ---- healthz sem segredo: liveness, e nada sobre o parque -------------------
try {
  $h = Invoke-RestMethod -Uri "$urlIngest/healthz" -TimeoutSec 20
  Verificar 'healthz responde' ([bool]$h.ok) ($h | ConvertTo-Json -Compress)
  Verificar 'healthz sem segredo nao expoe o banco' ($null -eq $h.db) ($h | ConvertTo-Json -Compress)
} catch {
  Verificar 'healthz responde' $false $_.Exception.Message
}

# ---- healthz com segredo: diagnostico -------------------------------------
try {
  $hd = Invoke-RestMethod -Uri "$urlIngest/healthz" -TimeoutSec 20 `
          -Headers @{ 'x-monitor-secret' = $Segredo }
  Verificar 'healthz com segredo alcanca o banco' ($null -ne $hd.db) ($hd | ConvertTo-Json -Compress)
} catch {
  Verificar 'healthz com segredo alcanca o banco' $false $_.Exception.Message
}

# ---- os dois scripts servidos em HTTPS ------------------------------------
foreach ($par in @(@('instalar.ps1', 'param('), @('agente.ps1', 'NovaAmostra'))) {
  $arquivo = $par[0]; $marca = $par[1]
  try {
    $texto = Invoke-RestMethod -Uri "$urlIngest/$arquivo" -TimeoutSec 30
    Verificar "$arquivo servido em HTTPS" ($texto -is [string] -and $texto.Length -gt 1000) `
      "tamanho: $(if ($texto) { $texto.Length } else { 0 })"
    Verificar "$arquivo tem conteudo de PowerShell" ($texto -like "*$marca*") "procurava '$marca'"
  } catch {
    Verificar "$arquivo servido em HTTPS" $false $_.Exception.Message
  }
}

# ---- segredo errado tem de ser RECUSADO -----------------------------------
# Verificacao de NEGACAO: o valor de um teste assim esta em ele falhar quando a
# protecao cai. Ausencia de excecao aqui significa que a funcao aceitou.
$envelopeTeste = @{
  agent_version = 'verificacao-1.0.0'
  sent_at       = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
  samples       = @(@{ t = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ'); cpu_pct = 1 })
}

$recusou = $false
$statusVisto = ''
try {
  Invoke-RestMethod -Uri $urlIngest -Method Post -TimeoutSec 30 `
    -Headers @{ 'x-monitor-secret' = 'segredo-errado-de-proposito'; Authorization = 'Bearer mon_naoexiste' } `
    -ContentType 'application/json' -Body ($envelopeTeste | ConvertTo-Json -Depth 8 -Compress) | Out-Null
} catch {
  $recusou = $true
  try { $statusVisto = [int]$_.Exception.Response.StatusCode } catch { $statusVisto = '?' }
}
Verificar 'segredo errado e recusado' $recusou "status: $statusVisto"
Verificar 'segredo errado devolve 401' ("$statusVisto" -eq '401') "status: $statusVisto"

# ---- segredo certo + token invalido: tambem recusado ----------------------
$recusou = $false
$statusVisto = ''
try {
  Invoke-RestMethod -Uri $urlIngest -Method Post -TimeoutSec 30 `
    -Headers @{ 'x-monitor-secret' = $Segredo; Authorization = 'Bearer mon_naoexiste' } `
    -ContentType 'application/json' -Body ($envelopeTeste | ConvertTo-Json -Depth 8 -Compress) | Out-Null
} catch {
  $recusou = $true
  try { $statusVisto = [int]$_.Exception.Response.StatusCode } catch { $statusVisto = '?' }
}
Verificar 'token invalido e recusado mesmo com o segredo certo' $recusou "status: $statusVisto"
Verificar 'token invalido devolve 401' ("$statusVisto" -eq '401') "status: $statusVisto"

# ---- ingestao REAL, ponta a ponta ----------------------------------------
# A unica verificacao que prova o caminho inteiro: token emitido pelo banco,
# HTTPS, funcao, RPC, particao e linha gravada. Sem ela, tudo acima poderia
# passar com a ingestao quebrada no ultimo metro.
$rotuloTeste = "VERIFICACAO-$(Get-Date -Format 'yyyyMMddHHmmss')"
$codigoTeste = "ZZ-VERIF-$(Get-Date -Format 'HHmmss')"
$machineId = $null
$siteId = $null
$brandId = $null

try {
  # Marca e loja PROPRIAS, criadas agora e removidas no fim.
  #
  # provision_machine exige loja existente e ativa, e num projeto recem-criado
  # nao existe nenhuma: o seed de demonstracao nao roda em producao. Usar uma loja
  # de verdade tambem nao serve — deixaria um evento de provisionamento no
  # historico de uma loja que nunca teve essa maquina.
  $cabRetorno = $cabServico + @{ Prefer = 'return=representation' }

  $b = Invoke-RestMethod -Uri "$urlRest/brands" -Method Post -TimeoutSec 30 `
         -Headers $cabRetorno `
         -Body (@{ code = $codigoTeste; name = 'verificacao de publicacao' } | ConvertTo-Json -Compress)
  $brandId = (Primeiro $b).id

  $s = Invoke-RestMethod -Uri "$urlRest/sites" -Method Post -TimeoutSec 30 `
         -Headers $cabRetorno `
         -Body (@{ brand_id = $brandId; code = $codigoTeste; name = 'verificacao de publicacao' } | ConvertTo-Json -Compress)
  $siteId = (Primeiro $s).id

  $corpo = @{
    p_site_code = $codigoTeste
    p_label     = $rotuloTeste
    p_role_code = 'pdv'
    p_notes     = 'criada e removida por publicar-supabase.ps1'
  } | ConvertTo-Json -Compress

  $prov = Invoke-RestMethod -Uri "$urlRest/rpc/provision_machine" -Method Post `
            -Headers $cabServico -Body $corpo -TimeoutSec 30

  # provision_machine devolve TABLE, entao a resposta e um array.
  $p = Primeiro $prov
  $machineId = $p.machine_id

  Verificar 'maquina de teste provisionada' ([bool]$p.token) "prefixo: $($p.token_prefix)"

  $envio = Invoke-RestMethod -Uri $urlIngest -Method Post -TimeoutSec 40 `
             -Headers @{ 'x-monitor-secret' = $Segredo; Authorization = "Bearer $($p.token)" } `
             -ContentType 'application/json' `
             -Body ($envelopeTeste | ConvertTo-Json -Depth 8 -Compress)

  Verificar 'INGESTAO REAL por HTTPS aceita a amostra' ([int]$envio.accepted -ge 1) `
    ($envio | ConvertTo-Json -Compress)
  Verificar 'a funcao identificou a maquina pelo token' ([bool]$envio.machine_id) `
    ($envio | ConvertTo-Json -Compress)
} catch {
  Verificar 'INGESTAO REAL por HTTPS aceita a amostra' $false $_.Exception.Message
} finally {
  # Limpa SEMPRE, inclusive quando o envio falhou: uma maquina de verificacao
  # esquecida apareceria offline no dashboard todo dia, e uma loja fantasma
  # poluiria o agrupamento.
  #
  # ORDEM IMPORTA: machines.site_id e sites.brand_id sao `on delete restrict`.
  # Metricas, eventos e tokens da maquina somem em cascata com ela.
  $sobrou = @()

  foreach ($alvo in @(
    @{ Nome = 'maquina'; Url = "$urlRest/machines?id=eq.$machineId"; Id = $machineId },
    @{ Nome = 'loja';    Url = "$urlRest/sites?id=eq.$siteId";       Id = $siteId },
    @{ Nome = 'marca';   Url = "$urlRest/brands?id=eq.$brandId";     Id = $brandId }
  )) {
    if (-not $alvo.Id) { continue }
    try {
      Invoke-RestMethod -Uri $alvo.Url -Method Delete -Headers $cabServico -TimeoutSec 30 | Out-Null
    } catch {
      $sobrou += "$($alvo.Nome) ($($alvo.Id))"
    }
  }

  if ($sobrou.Count -eq 0) {
    Info 'marca, loja e maquina de verificacao removidas'
  } else {
    Aviso "sobrou no banco: $($sobrou -join ', ') - remova pelo SQL editor"
  }
}

# ---------------------------------------------------------------------------
Passo 'Dashboard apontado para producao'
# ---------------------------------------------------------------------------
# Sem este passo o teste fica pela metade: a loja envia metrica para o Supabase e
# o dashboard continua mostrando o banco local, ou seja, nao mostra a loja.
#
# Em producao a autenticacao e OBRIGATORIA — nao existe o atalho sem login da
# stack local, que so e aceitavel porque ela escuta apenas em loopback.
if ([string]::IsNullOrWhiteSpace($EmailAdmin)) {
  Info 'pulado (-EmailAdmin nao informado). O dashboard segue apontado para a stack local.'
  Info 'Para apontar depois, rode de novo com -AnonKey, -EmailAdmin e -SenhaAdmin.'
} elseif ([string]::IsNullOrWhiteSpace($AnonKey) -or [string]::IsNullOrWhiteSpace($SenhaAdmin)) {
  Aviso '-EmailAdmin informado sem -AnonKey ou -SenhaAdmin; passo pulado.'
  Aviso 'A anon key esta em Settings > API (ela e publica por desenho).'
} else {
  $userId = $null

  # Cria o usuario pela API de administracao do Auth. `email_confirm` evita a
  # etapa de confirmacao por e-mail, que travaria o cadastro num projeto sem SMTP.
  try {
    $u = Invoke-RestMethod -Uri "$urlBase/auth/v1/admin/users" -Method Post -TimeoutSec 30 `
           -Headers $cabServico `
           -Body (@{ email = $EmailAdmin; password = $SenhaAdmin; email_confirm = $true } | ConvertTo-Json -Compress)
    $userId = (Primeiro $u).id
    Ok "usuario $EmailAdmin criado"
  } catch {
    # Ja existir NAO e erro: republicar nao deve falhar por isso. Busca o id.
    try {
      $lista = Invoke-RestMethod -Uri "$urlBase/auth/v1/admin/users?per_page=200" `
                 -Headers $cabServico -TimeoutSec 30
      $achado = Lista $lista.users | Where-Object { $_.email -eq $EmailAdmin } | Select-Object -First 1
      if ($achado) {
        $userId = $achado.id
        Info "usuario $EmailAdmin ja existia (senha nao alterada)"
      }
    } catch { }

    if (-not $userId) {
      Verificar 'usuario admin do dashboard criado' $false $_.Exception.Message
    }
  }

  if ($userId) {
    # O papel de admin vive em public.user_roles, nao no Auth: quem decide o que
    # o usuario ve e o RLS, e ele consulta esta tabela.
    try {
      Invoke-RestMethod -Uri "$urlRest/user_roles?on_conflict=user_id" -Method Post -TimeoutSec 30 `
        -Headers ($cabServico + @{ Prefer = 'resolution=merge-duplicates' }) `
        -Body (@{ user_id = $userId; role = 'admin'; note = 'criado por publicar-supabase.ps1' } | ConvertTo-Json -Compress) | Out-Null

      $papel = Invoke-RestMethod -Uri "$urlRest/user_roles?user_id=eq.$userId&select=role" `
                 -Headers $cabServico -TimeoutSec 30
      Verificar 'usuario e admin em user_roles' ((Primeiro $papel).role -eq 'admin') `
        ($papel | ConvertTo-Json -Compress)
    } catch {
      Verificar 'usuario e admin em user_roles' $false $_.Exception.Message
    }

    # Confere que ele consegue entrar DE VERDADE. Criar o usuario e conceder o
    # papel nao prova que o login funciona, e descobrir isso na frente da tela e
    # o mesmo tipo de tempo perdido que este projeto ja pagou uma vez.
    try {
      $sessao = Invoke-RestMethod -Uri "$urlBase/auth/v1/token?grant_type=password" -Method Post `
                  -TimeoutSec 30 -Headers @{ apikey = $AnonKey; 'Content-Type' = 'application/json' } `
                  -Body (@{ email = $EmailAdmin; password = $SenhaAdmin } | ConvertTo-Json -Compress)
      Verificar 'login do dashboard funciona com a anon key' ([bool]$sessao.access_token) 'sem access_token'

      # E que, autenticado, ele realmente ve o parque pelo RLS.
      $vis = Invoke-RestMethod -Uri "$urlRest/rpc/opcoes_cadastro" -Method Post -TimeoutSec 30 `
               -Headers @{ apikey = $AnonKey; Authorization = "Bearer $($sessao.access_token)"; 'Content-Type' = 'application/json' } `
               -Body '{}'
      Verificar 'o usuario e admin pela visao do RLS' ($vis.is_admin -eq $true) ($vis | ConvertTo-Json -Compress)
      Verificar 'o dashboard ja recebe o endereco da ingestao' `
        ($vis.ingestao.configurada -eq $true -and $vis.ingestao.https -eq $true) `
        ($vis.ingestao | ConvertTo-Json -Compress)
    } catch {
      Verificar 'login do dashboard funciona com a anon key' $false $_.Exception.Message
    }

    # config.producao.js: gerado ao lado, nao sobre o config.js. Sobrescrever
    # apagaria a configuracao da stack local sem aviso, e as duas precisam
    # coexistir enquanto o teste na LAN ainda serve de referencia.
    $configProd = Join-Path $repoRoot 'dashboard\config.producao.js'
    $conteudo = @"
// =============================================================================
// Configuracao do dashboard - PRODUCAO (Supabase)
// =============================================================================
// Gerado por scripts/publicar-supabase.ps1.
//
// PARA USAR: copie sobre o config.js.
//     Copy-Item dashboard\config.producao.js dashboard\config.js -Force
//
// Para voltar a stack local: git checkout dashboard/config.js
//
// Nada aqui e segredo. A anon key e publica por desenho e o que protege os dados
// e o RLS (regra 3). A service_role_key NUNCA entra neste arquivo, e o segredo da
// ingestao tambem nao: ele vem do banco, so para admin (regra 1).
// =============================================================================

window.MONITOR_CONFIG = {
  restUrl: '$urlRest',
  authUrl: '$urlBase/auth/v1',
  anonKey: '$AnonKey',
  authMode: 'supabase',

  pollSeconds: 20,
  realtime: true,
};
"@
    [System.IO.File]::WriteAllText($configProd, $conteudo, (New-Object System.Text.UTF8Encoding($false)))
    Ok 'dashboard/config.producao.js gerado'
    Info 'para usar: Copy-Item dashboard\config.producao.js dashboard\config.js -Force'
  }
}

# ---------------------------------------------------------------------------
Passo 'Guardando a configuracao'
# ---------------------------------------------------------------------------
# .env.producao esta coberto pelo .gitignore (padrao .env.*). Guarda o que voce
# vai precisar depois; a service_role key NAO entra aqui.
$linhas = @(
  '# Gerado por scripts/publicar-supabase.ps1. NAO vai para o git (.env.*).',
  '# A service_role key nao esta aqui de proposito: ela nunca vai para arquivo.',
  "SUPABASE_PROJECT_REF=$ProjetoRef",
  "SUPABASE_URL=$urlBase",
  "INGEST_URL=$urlIngest",
  "INGEST_SHARED_SECRET=$Segredo"
)
[System.IO.File]::WriteAllLines($envProducao, $linhas, (New-Object System.Text.UTF8Encoding($false)))
Ok '.env.producao gravado'

# ---------------------------------------------------------------------------
Write-Host ''
if ($falhas -gt 0) {
  Write-Host '============================================================' -ForegroundColor Red
  Write-Host " FALHARAM $falhas de $verificacoes verificacoes" -ForegroundColor Red
  Write-Host '============================================================' -ForegroundColor Red
  Write-Host ''
  Write-Host ' NAO instale em loja nenhuma antes de resolver isso: o agente' -ForegroundColor Yellow
  Write-Host ' ficaria coletando e falhando em silencio.' -ForegroundColor Yellow
  Write-Host ''
  exit 1
}

Write-Host '============================================================' -ForegroundColor Green
Write-Host " $verificacoes VERIFICACOES PASSARAM - PRODUCAO NO AR" -ForegroundColor Green
Write-Host '============================================================' -ForegroundColor Green
Write-Host "  Ingestao : $urlIngest"
Write-Host "  Instalador: $urlIngest/instalar.ps1"
Write-Host ''
Write-Host '  PROXIMO PASSO - gerar o comando para uma maquina:' -ForegroundColor Cyan
Write-Host '    .\scripts\comando-para-loja.ps1 -Loja BSB-003 -Rotulo "PDV 01"' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  Para conferir depois, sem republicar:' -ForegroundColor Cyan
Write-Host "    .\scripts\publicar-supabase.ps1 -ProjetoRef $ProjetoRef -SoVerificar" -ForegroundColor DarkGray
Write-Host ''
Write-Host '  Guarde o segredo compartilhado num gerenciador de senhas.' -ForegroundColor Yellow
Write-Host '  Ele esta em .env.producao, que NAO vai para o git.' -ForegroundColor Yellow
Write-Host '============================================================' -ForegroundColor Green
Write-Host ''
