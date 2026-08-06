<#
.SYNOPSIS
  Gera o comando de instalacao de uma maquina em producao.

.DESCRIPTION
  Faz pelo terminal o que o botao "+ Adicionar PC" faz pelo dashboard. Existe por
  dois motivos praticos:

    1. no PRIMEIRO teste em loja remota, o dashboard ainda pode nem estar
       apontado para o Supabase — e ficar sem poder cadastrar maquina por causa
       disso seria travar o teste pela razao errada;
    2. para cadastrar varias maquinas de uma vez, terminal ganha do formulario.

  O comando sai pronto para copiar. Ele contem o token DAQUELA maquina, e o token
  nao pode ser lido de novo depois: o banco guarda apenas o hash SHA-256.

.PARAMETER Loja
  Codigo da loja. Se ela nao existir, use -CriarLoja com -NomeLoja.

.PARAMETER Rotulo
  Nome da maquina como vai aparecer no dashboard. Ex: "PDV 01".

.PARAMETER Perfil
  Perfil da maquina: pdv, servidor, gerencia... Padrao: pdv.

.PARAMETER Servicos
  Servicos criticos a vigiar, separados por virgula. Use o NOME CURTO do servico
  (Spooler), nunca o nome exibido (Spooler de Impressao), que muda com o idioma
  do Windows. Vazio usa os do perfil.

.PARAMETER CriarLoja
  Cria a loja se ela ainda nao existir.

.PARAMETER NomeLoja
  Nome da loja nova. Sem isso, usa o proprio codigo.

.PARAMETER Marca
  Codigo da marca da loja nova. Padrao: LOCAL.

.PARAMETER ChaveServiceRole
  service_role key. Tenta SUPABASE_SERVICE_ROLE_KEY e depois pergunta.
  Nunca e gravada em arquivo.

.PARAMETER ComTarefa
  Acrescenta -ComTarefa ao comando: o agente volta sozinho depois de reiniciar o
  Windows, rodando como SYSTEM, e passa a coletar temperatura e SMART. Exige
  PowerShell elevado na maquina de destino. Em producao, use.

.EXAMPLE
  .\scripts\comando-para-loja.ps1 -Loja BSB-001 -Rotulo "PDV 03" -ComTarefa

.EXAMPLE
  .\scripts\comando-para-loja.ps1 -Loja SP-009 -CriarLoja -NomeLoja "Cajupar Moema" `
    -Rotulo "PDV 01" -Servicos 'Spooler,Dhcp' -ComTarefa
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string] $Loja,
  [Parameter(Mandatory = $true)][string] $Rotulo,

  [string] $Perfil = 'pdv',
  [string] $Servicos = '',
  [switch] $CriarLoja,
  [string] $NomeLoja,
  [string] $Marca = 'LOCAL',
  [string] $ChaveServiceRole,
  [switch] $ComTarefa
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

function Passo { param([string]$T) Write-Host ''; Write-Host "== $T ==" -ForegroundColor Cyan }
function Ok    { param([string]$T) Write-Host "   $T" -ForegroundColor Green }
function Info  { param([string]$T) Write-Host "   $T" -ForegroundColor DarkGray }
function Aviso { param([string]$T) Write-Host "   $T" -ForegroundColor Yellow }
function Erro  { param([string]$T) Write-Host "   $T" -ForegroundColor Red }

<#
  Normaliza a resposta do PostgREST numa lista de verdade.

  O Invoke-RestMethod do PowerShell 5.1 pode devolver um array JSON como UM item
  que CONTEM o array. Nesse caso `.Count` da 1 mesmo com N linhas — e, pior, da 1
  tambem quando a resposta e `[]`, o que faria "loja nao existe" virar "loja
  existe" e o script seguir com id nulo.

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

# ---------------------------------------------------------------------------
Passo 'Lendo a configuracao de producao'
# ---------------------------------------------------------------------------
if (-not (Test-Path $envProducao)) {
  Erro '.env.producao nao existe.'
  Aviso 'Publique a producao primeiro:'
  Write-Host '     .\scripts\publicar-supabase.ps1 -ProjetoRef SEU_REF' -ForegroundColor DarkGray
  exit 1
}

$cfg = @{}
Get-Content $envProducao | ForEach-Object {
  if ($_ -match '^\s*([A-Z_]+)=(.*)$') { $cfg[$Matches[1]] = $Matches[2].Trim() }
}

foreach ($campo in @('SUPABASE_URL', 'INGEST_URL', 'INGEST_SHARED_SECRET')) {
  if ([string]::IsNullOrWhiteSpace($cfg[$campo])) {
    Erro "$campo ausente em .env.producao. Publique de novo."
    exit 1
  }
}

$urlRest = "$($cfg['SUPABASE_URL'])/rest/v1"
$urlIngest = $cfg['INGEST_URL']
Ok "ingestao: $urlIngest"

if ($urlIngest -notlike 'https://*') {
  Aviso 'a ingestao NAO esta em HTTPS: este comando so vale dentro da rede local.'
}

if ([string]::IsNullOrWhiteSpace($ChaveServiceRole)) {
  $ChaveServiceRole = $env:SUPABASE_SERVICE_ROLE_KEY
}
if ([string]::IsNullOrWhiteSpace($ChaveServiceRole)) {
  Info 'service_role key (Settings > API). Nao aparece na tela.'
  $ChaveServiceRole = LerSegredoOculto 'service_role key:'
}

$cab = @{
  apikey         = $ChaveServiceRole
  Authorization  = "Bearer $ChaveServiceRole"
  'Content-Type' = 'application/json'
}
$cabRetorno = $cab + @{ Prefer = 'return=representation' }

# ---------------------------------------------------------------------------
Passo 'Loja'
# ---------------------------------------------------------------------------
$Loja = $Loja.Trim().ToUpperInvariant()

try {
  $lojas = Lista (Invoke-RestMethod -Uri "$urlRest/sites?code=eq.$Loja&select=id,code,name,is_active" `
             -Headers $cab -TimeoutSec 30)
} catch {
  Erro "nao foi possivel consultar as lojas: $($_.Exception.Message)"
  Aviso 'service_role key errada, ou as migrations nao foram aplicadas.'
  exit 1
}

if ($lojas.Count -eq 0) {
  if (-not $CriarLoja) {
    Erro "loja '$Loja' nao existe."
    Aviso 'Para criar junto, acrescente:  -CriarLoja -NomeLoja "Nome da loja"'
    exit 1
  }

  if ([string]::IsNullOrWhiteSpace($NomeLoja)) { $NomeLoja = $Loja }

  # A marca precisa existir antes da loja: sites.brand_id e `not null`.
  $marcas = Lista (Invoke-RestMethod -Uri "$urlRest/brands?code=eq.$($Marca.ToUpperInvariant())&select=id" `
              -Headers $cab -TimeoutSec 30)

  if ($marcas.Count -eq 0) {
    $m = Invoke-RestMethod -Uri "$urlRest/brands" -Method Post -Headers $cabRetorno -TimeoutSec 30 `
           -Body (@{ code = $Marca.ToUpperInvariant(); name = $Marca } | ConvertTo-Json -Compress)
    $brandId = (Primeiro $m).id
    Ok "marca $Marca criada"
  } else {
    $brandId = (Primeiro $marcas).id
  }

  $s = Invoke-RestMethod -Uri "$urlRest/sites" -Method Post -Headers $cabRetorno -TimeoutSec 30 `
         -Body (@{ brand_id = $brandId; code = $Loja; name = $NomeLoja } | ConvertTo-Json -Compress)
  Ok "loja $Loja ($NomeLoja) criada"
} else {
  $l = Primeiro $lojas
  if (-not $l.is_active) {
    Erro "a loja $Loja existe mas esta INATIVA; reative antes de provisionar."
    exit 1
  }
  Ok "loja $Loja - $($l.name)"
}

# ---------------------------------------------------------------------------
Passo 'Emitindo o token da maquina'
# ---------------------------------------------------------------------------
# p_rotate = true: se a maquina ja tem token ativo, emite outro. E o caminho de
# "reinstalei aquele PDV", que precisa funcionar sem etapa manual de revogacao.
try {
  $prov = Invoke-RestMethod -Uri "$urlRest/rpc/provision_machine" -Method Post `
            -Headers $cab -TimeoutSec 30 `
            -Body (@{
              p_site_code = $Loja
              p_label     = $Rotulo
              p_role_code = $Perfil
              p_notes     = 'cadastrada por comando-para-loja.ps1'
              p_rotate    = $true
            } | ConvertTo-Json -Compress)
} catch {
  Erro "provisionamento falhou: $($_.Exception.Message)"
  try {
    $resp = $_.Exception.Response
    if ($resp) {
      $leitor = New-Object System.IO.StreamReader($resp.GetResponseStream())
      Info $leitor.ReadToEnd()
    }
  } catch { }
  exit 1
}

$p = Primeiro $prov
if (-not $p.token) {
  Erro 'o servidor nao devolveu token.'
  exit 1
}

Ok "$($p.label) em $($p.site_code) - prefixo $($p.token_prefix)"

# Servicos criticos informados: gravados como override da maquina.
$listaServicos = @($Servicos -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

if ($listaServicos.Count -gt 0) {
  try {
    Invoke-RestMethod -Uri "$urlRest/machines?id=eq.$($p.machine_id)" -Method Patch `
      -Headers $cab -TimeoutSec 30 `
      -Body (@{ critical_services_override = $listaServicos } | ConvertTo-Json -Compress) | Out-Null
    Ok "servicos vigiados: $($listaServicos -join ', ')"
  } catch {
    Aviso "nao foi possivel gravar os servicos: $($_.Exception.Message)"
    Aviso 'o agente ainda vai usar os servicos do perfil'
  }
}

# ---------------------------------------------------------------------------
Passo 'Comando para rodar NA MAQUINA DA LOJA'
# ---------------------------------------------------------------------------
# scriptblock::Create e nao `iex` direto: so assim da para PASSAR ARGUMENTOS a um
# script baixado. Com `iex`, os parametros seriam ignorados em silencio e o
# instalador rodaria sem token.
$comando = "& ([scriptblock]::Create((irm '$urlIngest/instalar.ps1'))) " +
           "-Servidor '$urlIngest' -Token '$($p.token)' -Segredo '$($cfg['INGEST_SHARED_SECRET'])'"

if ($listaServicos.Count -gt 0) {
  $comando += " -Servicos '$($listaServicos -join ',')'"
}
if ($ComTarefa) { $comando += ' -ComTarefa' }

Write-Host ''
Write-Host $comando -ForegroundColor White
Write-Host ''

try {
  Set-Clipboard -Value $comando
  Ok 'comando copiado para a area de transferencia'
} catch {
  Info 'nao foi possivel copiar automaticamente; selecione o texto acima'
}

Write-Host ''
Write-Host '------------------------------------------------------------' -ForegroundColor Yellow
Write-Host ' Este comando contem o token DESTA maquina.' -ForegroundColor Yellow
Write-Host ' O banco guarda apenas o hash: nao ha como mostra-lo de novo.' -ForegroundColor Yellow
Write-Host ' Se perder, rode este script outra vez para emitir outro.' -ForegroundColor Yellow
if (-not $ComTarefa) {
  Write-Host ''
  Write-Host ' SEM -ComTarefa o agente NAO volta depois de reiniciar o Windows.' -ForegroundColor Yellow
  Write-Host ' Em producao, rode de novo com -ComTarefa.' -ForegroundColor Yellow
}
Write-Host '------------------------------------------------------------' -ForegroundColor Yellow
Write-Host ''
Write-Host ' Na maquina da loja: abra o PowerShell (como administrador, se'
Write-Host ' usar -ComTarefa) e cole. Em menos de um minuto ela aparece no'
Write-Host ' dashboard.'
Write-Host ''
