<#
.SYNOPSIS
  Troca o INGEST_SHARED_SECRET da stack e reconfigura tudo o que depende dele.
  Roda NA MAQUINA SERVIDORA.

.DESCRIPTION
  POR QUE

  O segredo compartilhado da ingestao foi colado no chat varias vezes em 17/09,
  junto com os comandos de instalacao. Quem tiver aquele texto consegue mandar
  amostra falsa como se fosse qualquer maquina da rede -- inclusive apagar a
  confianca no que o painel mostra, que e o unico motivo de o sistema existir.

  O CUSTO DE ADIAR, em uma frase: este script derruba TODAS as maquinas
  instaladas ate que cada uma seja reinstalada. Com duas, e meia hora. Com
  quarenta e cinco espalhadas em lojas, e um dia inteiro. Por isso a hora de
  fazer isso e agora, e nao depois da frota migrada.

  O QUE ELE FAZ, em ordem

    1. guarda copia do .env.selfhost (data e hora no nome);
    2. gera segredo novo -- 48 caracteres, de gerador criptografico;
    3. grava no .env.selfhost;
    4. RECRIA o contentor de ingestao, para ele ler o valor novo. Reiniciar nao
       basta: variavel de ambiente so entra na criacao do contentor;
    5. grava o mesmo segredo em ingest_config, que e de onde o PAINEL monta os
       comandos de instalacao;
    6. atualiza o .env.producao, que e de onde o comando-para-loja.ps1 le;
    7. PROVA o resultado por comportamento: o segredo velho passa a ser
       recusado e o novo passa a ser aceito.

  O segredo novo NAO e impresso. Ele fica nos arquivos da maquina e no banco; os
  comandos de instalacao saem do painel, ja preenchidos.

.PARAMETER Confirmar
  Obrigatorio. Sem ele o script so explica o que faria e sai -- trocar segredo
  por engano derruba a frota.

.EXAMPLE
  .\scripts\rotacionar-segredo-ingestao.ps1 -Confirmar
#>
[CmdletBinding()]
param(
  [switch] $Confirmar,
  [string] $Container = 'monitor-db',
  [string] $Raiz
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Raiz)) { $Raiz = Split-Path -Parent $PSScriptRoot }

$envSelf     = Join-Path $Raiz '.env.selfhost'
$envProducao = Join-Path $Raiz '.env.producao'
$compose     = Join-Path $Raiz 'docker-compose.producao.yml'
$composeTls  = Join-Path $Raiz 'docker-compose.tls.yml'
$arqEndereco = Join-Path $Raiz 'logs\endereco-publico.txt'

function Falhar([string] $t) { Write-Host $t -ForegroundColor Red; exit 1 }
function Passo ([string] $t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function Ok    ([string] $t) { Write-Host "   $t" -ForegroundColor Green }
function Info  ([string] $t) { Write-Host "   $t" -ForegroundColor DarkGray }

function Invocar([scriptblock] $b) {
  $antes = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $b } finally { $ErrorActionPreference = $antes }
}

function LerEnv([string] $arquivo, [string] $chave) {
  if (-not (Test-Path $arquivo)) { return $null }
  foreach ($l in (Get-Content $arquivo)) {
    if ($l -match "^\s*$chave\s*=\s*(.+?)\s*$") { return $Matches[1] }
  }
  return $null
}

if (-not (Test-Path $envSelf)) { Falhar "nao achei $envSelf (rode na maquina servidora)." }

$segredoVelho = LerEnv $envSelf 'INGEST_SHARED_SECRET'
if ([string]::IsNullOrWhiteSpace($segredoVelho)) { Falhar 'INGEST_SHARED_SECRET ausente no .env.selfhost.' }

$endereco = $null
if (Test-Path $arqEndereco) {
  foreach ($l in (Get-Content $arqEndereco)) {
    if ($l -match '^\s*(https://\S+)\s*$') { $endereco = $Matches[1].TrimEnd('/'); break }
  }
}
if ([string]::IsNullOrWhiteSpace($endereco)) { Falhar 'nao achei o endereco publico em logs\endereco-publico.txt.' }

if (-not $Confirmar) {
  Write-Host ''
  Write-Host 'Isto trocaria o segredo da ingestao e DERRUBARIA todas as maquinas' -ForegroundColor Yellow
  Write-Host 'instaladas ate cada uma ser reinstalada pelo painel.' -ForegroundColor Yellow
  Write-Host ''
  Write-Host 'Para fazer de verdade:  .\scripts\rotacionar-segredo-ingestao.ps1 -Confirmar'
  exit 0
}

# ---------------------------------------------------------------------------
Passo 'Copia de seguranca'
# ---------------------------------------------------------------------------
$copia = "$envSelf.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Copy-Item $envSelf $copia -Force
Ok "guardado em $(Split-Path -Leaf $copia)"

# ---------------------------------------------------------------------------
Passo 'Gerando o segredo novo'
# ---------------------------------------------------------------------------
# Gerador criptografico, e nao Get-Random: este ultimo e previsivel o bastante
# para nao servir de credencial.
$bytes = New-Object byte[] 24
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
$segredoNovo = -join ($bytes | ForEach-Object { $_.ToString('x2') })
Ok "$($segredoNovo.Length) caracteres gerados (nao sao impressos)"

# ---------------------------------------------------------------------------
Passo 'Gravando no .env.selfhost'
# ---------------------------------------------------------------------------
# Sem BOM: um BOM no meio do arquivo vira parte do NOME da variavel seguinte e o
# docker compose deixa de enxerga-la.
$utf8SemBom = New-Object System.Text.UTF8Encoding($false)
$linhas = [System.IO.File]::ReadAllLines($envSelf)
$novas = foreach ($l in $linhas) {
  if ($l -match '^\s*INGEST_SHARED_SECRET\s*=') { "INGEST_SHARED_SECRET=$segredoNovo" } else { $l }
}
[System.IO.File]::WriteAllLines($envSelf, $novas, $utf8SemBom)
Ok 'gravado'

# ---------------------------------------------------------------------------
Passo 'Recriando o contentor de ingestao'
# ---------------------------------------------------------------------------
# --force-recreate e obrigatorio: variavel de ambiente entra na CRIACAO do
# contentor. Um `restart` subiria o mesmo processo com o segredo antigo, e o
# sintoma seria "troquei e nao mudou nada".
$dominio = LerEnv $envSelf 'DOMINIO_PUBLICO'
# NAO usar $args aqui: e variavel automatica, e dentro do bloco do Invocar ela
# seria a lista (vazia) do proprio bloco -- o docker rodaria sem argumento nenhum.
$argsCompose = @('compose', '-f', $compose)
if ((Test-Path $composeTls) -and -not [string]::IsNullOrWhiteSpace($dominio)) { $argsCompose += @('-f', $composeTls) }
$argsCompose += @('--env-file', $envSelf, 'up', '-d', '--force-recreate', 'ingest')

Invocar { docker @argsCompose }
if ($LASTEXITCODE -ne 0) { Falhar 'falhou ao recriar o contentor de ingestao.' }
Ok 'contentor recriado'

Start-Sleep -Seconds 3

# ---------------------------------------------------------------------------
Passo 'Atualizando o banco e o .env.producao'
# ---------------------------------------------------------------------------
# O painel monta o comando de instalacao a partir de ingest_config. Sem este
# passo ele continuaria entregando comandos com o segredo VELHO -- e cada
# maquina reinstalada nasceria ja recusada.
$sqlLocal = Join-Path $env:TEMP ("rotacao-{0}.sql" -f (Get-Date -Format 'yyyyMMddHHmmssfff'))
$urlEsc = "$endereco/functions/v1/ingest".Replace("'", "''")
$segEsc = $segredoNovo.Replace("'", "''")
Set-Content -Path $sqlLocal -Encoding utf8 -Value "select public.definir_ingestao('$urlEsc', '$segEsc');"

try {
  Invocar {
    docker cp $sqlLocal "${Container}:/tmp/rotacao.sql" | Out-Null
    docker exec $Container psql -U postgres -d postgres -q -v ON_ERROR_STOP=1 -f /tmp/rotacao.sql | Out-Null
  }
  $cod = $LASTEXITCODE
  Invocar { docker exec $Container rm -f /tmp/rotacao.sql } | Out-Null
} finally {
  Remove-Item $sqlLocal -Force -ErrorAction SilentlyContinue
}
if ($cod -ne 0) { Falhar 'falhou ao gravar a configuracao de ingestao no banco.' }
Ok 'ingest_config atualizada'

if (Test-Path $envProducao) {
  $linhasP = [System.IO.File]::ReadAllLines($envProducao)
  $novasP = foreach ($l in $linhasP) {
    if ($l -match '^\s*INGEST_SHARED_SECRET\s*=') { "INGEST_SHARED_SECRET=$segredoNovo" } else { $l }
  }
  [System.IO.File]::WriteAllLines($envProducao, $novasP, $utf8SemBom)
  Ok '.env.producao atualizado'
}

# ---------------------------------------------------------------------------
Passo 'Provando por comportamento'
# ---------------------------------------------------------------------------
# Nao basta o arquivo ter mudado: o que importa e o que o servidor RESPONDE.
# Token proposital invalido nos dois testes -- quem esta sendo medido e o
# segredo, que o servidor confere ANTES do token.
$url = "$endereco/functions/v1/ingest"
$corpo = '{"agent_version":"teste","sent_at":"1970-01-01T00:00:00.000Z","machine":{},"samples":[]}'

function Bater([string] $segredo) {
  $antes = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & curl.exe -s -o NUL -w '%{http_code}' --max-time 20 -X POST `
      -H 'Content-Type: application/json' `
      -H "x-monitor-secret: $segredo" `
      -H 'authorization: Bearer mon_token_invalido_de_proposito' `
      --data-binary $corpo $url
  } finally { $ErrorActionPreference = $antes }
}

$codVelho = "$(Bater $segredoVelho)".Trim()
$codNovo  = "$(Bater $segredoNovo)".Trim()

# A ordem de checagem do servidor e o que torna esta prova possivel:
#
#   segredo errado ............................ 401, e para ali
#   segredo certo, corpo invalido (samples []) . 400, porque passou da porta
#
# Os dois codigos sao diferentes DE PROPOSITO na leitura, mas a mensagem de 401
# e generica no servidor -- ela nao revela se o problema foi o segredo ou o
# token, e isso esta certo. Quem distingue aqui e o corpo que EU mando: com o
# segredo certo, a recusa passa a ser do formato, nao da credencial.
Info "segredo velho -> HTTP $codVelho   (esperado 401: recusado na porta)"
Info "segredo novo  -> HTTP $codNovo    (esperado 400: passou da porta)"

if ($codVelho -eq $codNovo) {
  Falhar "o servidor respondeu $codVelho aos DOIS segredos: o contentor nao recarregou o valor novo."
}
if ($codVelho -ne '401') {
  Falhar "o segredo VELHO ainda nao esta sendo recusado (HTTP $codVelho)."
}
if ($codNovo -ne '400') {
  Falhar "o segredo NOVO nao esta sendo aceito (HTTP $codNovo)."
}
Ok 'o segredo velho foi recusado e o novo passou pela porta'

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' Segredo trocado' -ForegroundColor Green
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host ' AS MAQUINAS JA INSTALADAS PARARAM DE REPORTAR AGORA.' -ForegroundColor Yellow
Write-Host ' Elas voltam uma a uma, reinstaladas pelo painel -- o comando que ele'
Write-Host ' gera ja sai com o segredo novo. Sao duas hoje:'
Write-Host '   BANCO-DE-DADOS (esta maquina)  e  SERVIDOR-ASN (Caminito Asa Norte)'
Write-Host ''
Write-Host ' Confira depois de reinstalar cada uma:'
Write-Host '   docker logs monitor-ingest --since 3m'
Write-Host ''
Write-Host " A copia do arquivo anterior ficou em $(Split-Path -Leaf $copia)."
Write-Host ' Apague-a quando tudo estiver reportando: ela contem o segredo velho.'
exit 0
