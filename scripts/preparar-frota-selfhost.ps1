<#
.SYNOPSIS
  Prepara a maquina servidora para provisionar agentes contra a stack
  self-hosted: gera a chave de servico e escreve o .env.producao. Roda NA
  MAQUINA SERVIDORA.

.DESCRIPTION
  O PROBLEMA QUE ISTO RESOLVE

  O comando-para-loja.ps1 -- o gerador do comando de instalacao de cada maquina
  -- foi escrito quando producao era Supabase. Ele le tres campos do
  .env.producao (SUPABASE_URL, INGEST_URL, INGEST_SHARED_SECRET) e usa uma
  service_role key para falar com a API. Nada disso existe na stack
  self-hosted, entao ele para antes de comecar.

  Mas nada disso precisa ser inventado, e este script nao improvisa credencial
  nenhuma: o PostgREST desta stack valida JWT assinado com o JWT_SECRET
  (PGRST_JWT_SECRET no compose). Uma chave de servico e, literalmente, um JWT
  com a claim role=service_role assinado com esse mesmo segredo. E o que este
  script gera -- na maquina, com o segredo que ja esta la, sem nada passar por
  conversa nenhuma.

  O QUE ELE FAZ

    1. le JWT_SECRET e INGEST_SHARED_SECRET do .env.selfhost;
    2. descobre o endereco publico (logs/endereco-publico.txt, escrito pelo
       tunel-tailscale.ps1) ou aceita -Endereco;
    3. assina a chave de servico (HS256, validade de 2 anos);
    4. escreve o .env.producao com os quatro campos;
    5. CONFERE chamando a API publica com a chave -- porque chave que nao foi
       testada e chave que ninguem sabe se funciona.

  VALIDADE DE 2 ANOS, e nao "para sempre": chave sem prazo e chave que ninguem
  troca nunca. Dois anos e prazo para o sistema viver em paz e ainda assim
  obrigar uma rotacao antes de virar folclore. Rodar este script de novo emite
  outra.

  A chave NAO e impressa na tela. Ela vai para o .env.producao, que o
  .gitignore ja cobre (.env.*), e o proprio script mostra como carrega-la na
  sessao sem ecoar.

.PARAMETER Endereco
  Endereco publico, ex: https://desktop-abc.tailXXXX.ts.net. Padrao: o que
  estiver em logs/endereco-publico.txt.

.PARAMETER Anos
  Validade da chave de servico. Padrao: 2.

.EXAMPLE
  .\scripts\preparar-frota-selfhost.ps1
#>
[CmdletBinding()]
param(
  [string] $Endereco,
  [int]    $Anos = 2,
  [string] $Raiz
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Raiz)) { $Raiz = Split-Path -Parent $PSScriptRoot }

$envSelf     = Join-Path $Raiz '.env.selfhost'
$envProducao = Join-Path $Raiz '.env.producao'
$arqEndereco = Join-Path $Raiz 'logs\endereco-publico.txt'

function Falhar([string] $texto) {
  Write-Host $texto -ForegroundColor Red
  exit 1
}

function LerEnv([string] $arquivo, [string] $chave) {
  if (-not (Test-Path $arquivo)) { return $null }
  foreach ($linha in (Get-Content $arquivo)) {
    if ($linha -match "^\s*$chave\s*=\s*(.+?)\s*$") { return $Matches[1] }
  }
  return $null
}

# ---------------------------------------------------------------------------
# 1. Os segredos, lidos da maquina
# ---------------------------------------------------------------------------
if (-not (Test-Path $envSelf)) { Falhar "nao achei $envSelf (rode na maquina servidora)." }

$jwtSecret = LerEnv $envSelf 'JWT_SECRET'
$segredoIngest = LerEnv $envSelf 'INGEST_SHARED_SECRET'

if ([string]::IsNullOrWhiteSpace($jwtSecret))     { Falhar 'JWT_SECRET ausente no .env.selfhost.' }
if ([string]::IsNullOrWhiteSpace($segredoIngest)) { Falhar 'INGEST_SHARED_SECRET ausente no .env.selfhost.' }

# ---------------------------------------------------------------------------
# 2. O endereco publico
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Endereco)) {
  if (-not (Test-Path $arqEndereco)) {
    Falhar 'passe -Endereco: nao achei logs\endereco-publico.txt.'
  }
  foreach ($linha in (Get-Content $arqEndereco)) {
    if ($linha -match '^\s*(https://\S+)\s*$') { $Endereco = $Matches[1]; break }
  }
}
if ([string]::IsNullOrWhiteSpace($Endereco)) { Falhar 'nao consegui determinar o endereco publico.' }

$Endereco = $Endereco.TrimEnd('/')
if ($Endereco -notlike 'https://*') { Falhar "o endereco precisa ser https: $Endereco" }

Write-Host "endereco publico: $Endereco" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 3. Assinar a chave de servico
# ---------------------------------------------------------------------------
# JWT e tres pedacos em base64url separados por ponto. base64url NAO e base64:
# troca + por -, / por _ e corta o preenchimento com =. Errar isso produz um
# token que parece certo e e recusado sem explicacao util.
function Base64Url([byte[]] $bytes) {
  [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

$agora = [DateTimeOffset]::UtcNow
$iat = $agora.ToUnixTimeSeconds()
$exp = $agora.AddYears($Anos).ToUnixTimeSeconds()

$cabecalho = '{"alg":"HS256","typ":"JWT"}'
$conteudo  = '{"role":"service_role","iss":"monitor-selfhost","iat":' + $iat + ',"exp":' + $exp + '}'

$h = Base64Url ([Text.Encoding]::UTF8.GetBytes($cabecalho))
$p = Base64Url ([Text.Encoding]::UTF8.GetBytes($conteudo))

$hmac = New-Object System.Security.Cryptography.HMACSHA256
try {
  $hmac.Key = [Text.Encoding]::UTF8.GetBytes($jwtSecret)
  $assinatura = Base64Url ($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes("$h.$p")))
} finally { $hmac.Dispose() }

$chave = "$h.$p.$assinatura"
Write-Host ("chave de servico assinada, valida ate {0:yyyy-MM-dd}" -f $agora.AddYears($Anos).LocalDateTime) -ForegroundColor Green

# ---------------------------------------------------------------------------
# 4. Escrever o .env.producao
# ---------------------------------------------------------------------------
# SUPABASE_URL continua com esse nome mesmo sem Supabase nenhum: e o campo que o
# comando-para-loja.ps1 le, e renomear agora seria mexer num script que funciona
# para ganhar estetica. O nome mente; o comentario no arquivo conta a verdade.
$utf8SemBom = New-Object System.Text.UTF8Encoding($false)
$linhas = @(
  '# Producao SELF-HOSTED. Gerado por scripts/preparar-frota-selfhost.ps1.',
  '# SUPABASE_URL aqui e o endereco da SUA stack -- o nome do campo ficou por',
  '# compatibilidade com o comando-para-loja.ps1. Nao ha Supabase nenhum atras.',
  "SUPABASE_URL=$Endereco",
  "INGEST_URL=$Endereco/functions/v1/ingest",
  "INGEST_SHARED_SECRET=$segredoIngest",
  "SUPABASE_SERVICE_ROLE_KEY=$chave"
)
[System.IO.File]::WriteAllText($envProducao, ($linhas -join "`r`n") + "`r`n", $utf8SemBom)
Write-Host ".env.producao escrito (fora do git, coberto por .env.*)" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 5. CONFERIR a chave contra a API publica
# ---------------------------------------------------------------------------
# Chave nao testada e chave que ninguem sabe se funciona. E o teste vai pelo
# endereco PUBLICO de proposito: e o mesmo caminho que as maquinas de loja vao
# usar, entao ele prova o caminho inteiro e nao so a assinatura.
#
# curl.exe, e nao Invoke-WebRequest: o Invoke-WebRequest do PowerShell 5.1
# obedece o proxy do usuario e ja produziu alarme falso neste projeto hoje.
$url = "$Endereco/rest/v1/sites?select=code&limit=1"
$antes = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  $codigo = & curl.exe -s -o NUL -w '%{http_code}' --max-time 20 `
              -H "apikey: $chave" -H "Authorization: Bearer $chave" $url
  $saiu = $LASTEXITCODE
} finally { $ErrorActionPreference = $antes }

Write-Host ''
if ($saiu -ne 0) {
  Write-Host "SEM RESPOSTA de $Endereco -- o endereco publico esta fora?" -ForegroundColor Red
  exit 1
}

switch -regex ("$codigo".Trim()) {
  '^2\d\d$' {
    Write-Host "OK: a chave de servico foi aceita pela API publica (HTTP $codigo)." -ForegroundColor Green
  }
  '^401$|^403$' {
    Write-Host "RECUSADA (HTTP $codigo): o JWT_SECRET do .env.selfhost nao e o mesmo que o PostgREST esta usando." -ForegroundColor Red
    Write-Host 'Suba a stack com o mesmo arquivo de ambiente e rode de novo.' -ForegroundColor Yellow
    exit 1
  }
  default {
    Write-Host "resposta inesperada: HTTP $codigo" -ForegroundColor Yellow
    exit 1
  }
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' Pronto para provisionar maquinas' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host ' Carregue a chave na sessao (sem ecoar na tela):'
Write-Host '   $env:SUPABASE_SERVICE_ROLE_KEY = ((Get-Content .env.producao | Where-Object { $_ -like ''SUPABASE_SERVICE_ROLE_KEY=*'' }) -split ''='', 2)[1]'
Write-Host ''
Write-Host ' Depois, para cada loja -- SEMPRE com -ComTarefa:'
Write-Host '   .\scripts\comando-para-loja.ps1 -Loja BSB-001 -Rotulo PC-CAIXA -ComTarefa'
Write-Host ''
Write-Host ' -ComTarefa nao e opcional na pratica: e ele que instala a tarefa' -ForegroundColor Yellow
Write-Host ' agendada. Sem ela o agente nao volta depois do desligamento, e foi' -ForegroundColor Yellow
Write-Host ' exatamente assim que 27 maquinas sumiram sem erro nenhum.' -ForegroundColor Yellow
Write-Host ''
Write-Host ' COMECE POR UMA. Instale numa maquina so, confirme que a amostra' -ForegroundColor Yellow
Write-Host ' chegou, e so entao siga para as outras:' -ForegroundColor Yellow
Write-Host "   docker exec monitor-db psql -U postgres -d postgres -A -t -c ""select count(*) from public.metrics where ingested_at > now() - interval '10 minutes';"""
exit 0
