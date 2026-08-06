<#
.SYNOPSIS
  Sobe o sistema completo localmente: banco, API e dashboard.

.DESCRIPTION
  Um comando, sistema funcionando. Faz:
    1. gera .env.local com senha e segredo JWT aleatorios (nunca fixos)
    2. sobe Postgres + PostgREST + nginx via docker compose
    3. aplica as migrations
    4. aplica o seed (3 lojas, 5 maquinas)
    5. cria um usuario admin e gera o JWT de desenvolvimento
    6. envia metricas reais pela ingestao (simulador de agente)
    7. abre o dashboard

  O PostgREST e exatamente o que o Supabase expoe como /rest/v1, e o JWT tem as
  MESMAS claims que o Supabase Auth emite. Ou seja: o RLS exercitado aqui e o
  mesmo do ambiente real — nao e um bypass de desenvolvimento.

.PARAMETER Recriar
  Apaga o volume do banco antes de subir. Use para partir do zero.

.PARAMETER SemSimulador
  Nao gera metricas sinteticas nem roda o simulador.

.PARAMETER Horas
  Horas de historico que o simulador gera. Padrao 24.

.EXAMPLE
  .\scripts\dev-up.ps1

.EXAMPLE
  .\scripts\dev-up.ps1 -Recriar -Horas 48
#>
[CmdletBinding()]
param(
  [switch] $Recriar,
  [switch] $SemSimulador,
  [int]    $Horas = 24
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

function Passo { param([string]$T) Write-Host ''; Write-Host "== $T ==" -ForegroundColor Cyan }
function Ok    { param([string]$T) Write-Host "   $T" -ForegroundColor Green }
function Info  { param([string]$T) Write-Host "   $T" -ForegroundColor DarkGray }

<#
  Invoca executavel nativo capturando saida e codigo de retorno.

  Existe por um comportamento especifico do Windows PowerShell 5.1: redirecionar
  stderr de um .exe (com 2>&1) embrulha cada linha num ErrorRecord, e com
  $ErrorActionPreference = 'Stop' isso ABORTA o script. O `docker compose up`
  escreve o progresso do pull em stderr — ou seja, o script morria no caminho
  normal, sem nenhum erro real.

  Aqui a preferencia e rebaixada apenas durante a chamada, e a decisao passa a
  ser o codigo de saida, que e o que de fato indica falha.
#>
function Exec {
  param(
    [Parameter(Mandatory = $true)][string]   $Programa,
    [Parameter(Mandatory = $true)][string[]] $Argumentos,
    [switch] $Silencioso
  )

  $anterior = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $saida = & $Programa @Argumentos 2>&1 | ForEach-Object { "$_" }
    $codigo = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $anterior
  }

  if (-not $Silencioso -and $saida) {
    $saida | Select-Object -Last 6 | ForEach-Object { Info $_ }
  }

  return [pscustomobject]@{ Codigo = $codigo; Saida = $saida }
}

function Aleatorio {
  param([int] $Bytes = 32)
  # RNG criptografico, nao Get-Random: senha de banco e segredo de JWT nao podem
  # sair de um PRNG previsivel.
  #
  # Create() + GetBytes(buffer) e nao o GetBytes(int) estatico: o estatico so
  # existe no .NET Core 3+, e o Windows PowerShell 5.1 roda sobre .NET Framework.
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $b = New-Object byte[] ($Bytes + 12)
    $rng.GetBytes($b)
    $limpo = ([Convert]::ToBase64String($b) -replace '[^A-Za-z0-9]', '')
    return $limpo.Substring(0, [Math]::Min($Bytes, $limpo.Length))
  } finally {
    $rng.Dispose()
  }
}

# ---------------------------------------------------------------------------
Passo 'Pre-requisitos'
# ---------------------------------------------------------------------------
$docker = Get-Command docker -ErrorAction SilentlyContinue
if ($null -eq $docker) { Write-Host 'docker nao encontrado.' -ForegroundColor Red; exit 1 }
Ok "docker: $($docker.Source)"

$node = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $node) { Write-Host 'node nao encontrado (necessario para o JWT e o simulador).' -ForegroundColor Red; exit 1 }
Ok "node: $(& $node.Source --version)"

$r = Exec 'docker' @('compose', 'version') -Silencioso
if ($r.Codigo -ne 0) { Write-Host '"docker compose" indisponivel.' -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------------------
Passo 'Segredos locais'
# ---------------------------------------------------------------------------
# Preservado entre execucoes: recriar o segredo do JWT invalidaria o token e o
# dashboard cairia para a tela de login sem explicacao.
$envFile = Join-Path $repoRoot '.env.local'

if (Test-Path $envFile) {
  Info '.env.local ja existe (preservado)'
} else {
  $pg  = Aleatorio 24
  $jwt = Aleatorio 32
  @(
    '# Gerado por scripts/dev-up.ps1. NAO comitar (esta no .gitignore).',
    '# Somente ambiente local. Producao usa os segredos do painel do Supabase.',
    "POSTGRES_PASSWORD=$pg",
    "JWT_SECRET=$jwt"
  ) | Out-File -FilePath $envFile -Encoding ascii
  Ok '.env.local criado com senha e segredo aleatorios'
}

$vars = @{}
foreach ($linha in Get-Content $envFile) {
  if ($linha -match '^\s*([A-Z_]+)\s*=\s*(.+)\s*$') { $vars[$Matches[1]] = $Matches[2] }
}
$jwtSecret = $vars['JWT_SECRET']
if ([string]::IsNullOrWhiteSpace($jwtSecret)) { Write-Host 'JWT_SECRET vazio no .env.local' -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------------------
Passo 'Limpando execucao anterior'
# ---------------------------------------------------------------------------
# ANTES de escolher portas: containers da execucao anterior ainda seguram as
# portas, e sem isto cada execucao subiria uma porta (3001, 3002, 3003...).
if ($Recriar) {
  Info 'derrubando containers e apagando o volume do banco'
  Exec 'docker' @('compose', 'down', '-v') -Silencioso | Out-Null
} else {
  Info 'derrubando containers (volume preservado)'
  Exec 'docker' @('compose', 'down') -Silencioso | Out-Null
}

# ---------------------------------------------------------------------------
Passo 'Escolhendo portas'
# ---------------------------------------------------------------------------
# Nesta maquina 8080 e 3000 estavam tomadas por wslrelay (sobra do Docker/WSL).
# Descobrir a porta livre e melhor que documentar "libere a 8080": o script
# funciona na maquina de quem for rodar, nao apenas na minha.
function QuemOcupa {
  param([int] $Porta)

  # Dizer QUEM ocupa, nao apenas que esta ocupada. Nesta maquina as portas 3000 e
  # 8080 sao de outro projeto (WAHA), e abrir a 8080 achando que era este
  # dashboard custou uma sessao inteira de diagnostico.
  $c = docker ps --format '{{.Names}} {{.Ports}}' 2>$null |
         Where-Object { $_ -match ":$Porta->" }
  if ($c) { return "container docker: $(($c -split ' ')[0])" }

  $t = Get-NetTCPConnection -LocalPort $Porta -State Listen -ErrorAction SilentlyContinue
  if ($t) {
    $nome = (Get-Process -Id $t[0].OwningProcess -ErrorAction SilentlyContinue).ProcessName
    if ($nome) { return "processo: $nome" }
    return 'processo desconhecido'
  }
  return $null
}

function PortaLivre {
  param([int] $Preferida, [int] $Tentativas = 40)
  for ($p = $Preferida; $p -lt ($Preferida + $Tentativas); $p++) {
    $emUso = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
    if (-not $emUso) { return $p }
  }
  throw "nenhuma porta livre entre $Preferida e $($Preferida + $Tentativas)"
}

$restPort = PortaLivre 3000
$webPort  = PortaLivre 8080

if ($restPort -ne 3000) {
  $dono = QuemOcupa 3000
  Write-Host "   porta 3000 ocupada por $dono" -ForegroundColor Yellow
  Write-Host "   -> a API deste projeto vai para $restPort" -ForegroundColor Yellow
}
if ($webPort -ne 8080) {
  $dono = QuemOcupa 8080
  Write-Host "   porta 8080 ocupada por $dono" -ForegroundColor Yellow
  Write-Host "   -> o DASHBOARD deste projeto vai para $webPort" -ForegroundColor Yellow
  Write-Host "   -> NAO abra 127.0.0.1:8080, ali esta outra aplicacao" -ForegroundColor Yellow
}
Ok "API $restPort  |  dashboard $webPort"

# docker compose le .env por padrao. As portas escolhidas entram aqui, nao no
# .env.local, para que o arquivo de segredos nao seja reescrito a cada execucao.
@(
  '# Gerado por scripts/dev-up.ps1 a cada execucao. Nao editar.',
  "POSTGRES_PASSWORD=$($vars['POSTGRES_PASSWORD'])",
  "JWT_SECRET=$jwtSecret",
  "REST_PORT=$restPort",
  "WEB_PORT=$webPort"
) | Out-File -FilePath (Join-Path $repoRoot '.env') -Encoding ascii

$restUrl = "http://127.0.0.1:$restPort"
$webUrl  = "http://127.0.0.1:$webPort"

# ---------------------------------------------------------------------------
Passo 'Subindo containers'
# ---------------------------------------------------------------------------
Info 'docker compose up (pode baixar imagens na primeira vez)'
$r = Exec 'docker' @('compose', 'up', '-d')
if ($r.Codigo -ne 0) {
  Write-Host 'docker compose up falhou:' -ForegroundColor Red
  $r.Saida | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }
  exit 1
}
Ok 'containers no ar'

Info 'aguardando o banco ficar saudavel'
$pronto = $false
for ($i = 0; $i -lt 75; $i++) {
  $chk = Exec 'docker' @('exec', 'monitor-db', 'pg_isready', '-U', 'postgres', '-q') -Silencioso
  if ($chk.Codigo -eq 0) { $pronto = $true; break }
  Start-Sleep -Milliseconds 800
}
if (-not $pronto) { Write-Host 'banco nao subiu em 60s' -ForegroundColor Red; exit 1 }
Ok 'banco pronto'

# ---------------------------------------------------------------------------
Passo 'Aplicando migrations'
# ---------------------------------------------------------------------------
Exec 'docker' @('exec', 'monitor-db', 'mkdir', '-p', '/work/m', '/work/s', '/work/bin') -Silencioso | Out-Null
Exec 'docker' @('cp', (Join-Path $repoRoot 'supabase\migrations\.'), 'monitor-db:/work/m/') -Silencioso | Out-Null
Exec 'docker' @('cp', (Join-Path $repoRoot 'supabase\seed\.'), 'monitor-db:/work/s/') -Silencioso | Out-Null

<#
  Script shell vai por ARQUIVO, nunca por `bash -c "<string>"`.

  Motivo: o Windows PowerShell 5.1 reescreve as aspas ao montar a linha de
  comando de um executavel nativo. Um script com `-f "$f"` dentro chega ao bash
  quebrado, e o erro que aparece ("syntax error: unexpected end of file") nao tem
  nenhuma relacao visivel com a causa. Arquivo elimina a classe inteira de
  problema.
#>
function ExecScript {
  param(
    [Parameter(Mandatory = $true)][string] $Conteudo,
    [Parameter(Mandatory = $true)][string] $Nome
  )

  $local = Join-Path $env:TEMP $Nome
  # LF e sem BOM: bash nao aceita CRLF nem marca de ordem de bytes.
  $texto = ($Conteudo -replace "`r`n", "`n")
  [System.IO.File]::WriteAllText($local, $texto, (New-Object System.Text.UTF8Encoding($false)))

  Exec 'docker' @('cp', $local, "monitor-db:/work/bin/$Nome") -Silencioso | Out-Null
  Remove-Item $local -Force -ErrorAction SilentlyContinue

  return Exec 'docker' @('exec', 'monitor-db', 'bash', "/work/bin/$Nome") -Silencioso
}

$r = ExecScript -Nome 'aplicar.sh' -Conteudo @'
set -e
n=0
for f in /work/m/*.sql; do
  if ! psql -U postgres -q --single-transaction -v ON_ERROR_STOP=1 -f "$f" > /tmp/o 2>&1; then
    echo "FALHA em $(basename "$f")"
    cat /tmp/o
    exit 1
  fi
  n=$((n + 1))
done
echo "$n migrations aplicadas"
'@

if ($r.Codigo -ne 0) {
  $r.Saida | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }
  exit 1
}
Ok (($r.Saida | Where-Object { $_ -match 'migrations' } | Select-Object -Last 1))

# ---------------------------------------------------------------------------
Passo 'Seed'
# ---------------------------------------------------------------------------
$r = ExecScript -Nome 'seed.sh' -Conteudo @'
set -e
psql -U postgres -q -v ON_ERROR_STOP=1 -f /work/s/seed_demo.sql
'@

if ($r.Codigo -ne 0) {
  $r.Saida | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }
  exit 1
}
Ok '2 marcas, 3 lojas, 5 maquinas'

# ---------------------------------------------------------------------------
Passo 'Recarregando o cache de schema da API'
# ---------------------------------------------------------------------------
<#
  Sem isto o dashboard fica vazio SEM NENHUM ERRO visivel.

  O PostgREST monta o cache de schema quando sobe. Aqui ele subiu com o banco
  ainda vazio (o compose up vem antes das migrations), entao ficou com
  "0 Relations, 0 Functions" e responderia 404 em tudo.

  O NOTIFY no canal pgrst e o mecanismo oficial de recarga. Vale saber tambem
  para producao: o Supabase recarrega sozinho ao aplicar migration pelo CLI, mas
  ao rodar DDL na mao pelo SQL Editor a mesma armadilha existe.
#>
$r = ExecScript -Nome 'reload.sh' -Conteudo @'
set -e
psql -U postgres -q -v ON_ERROR_STOP=1 -c "notify pgrst, 'reload schema';"
'@

if ($r.Codigo -ne 0) {
  $r.Saida | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }
  exit 1
}
Ok 'NOTIFY pgrst enviado'

# ---------------------------------------------------------------------------
Passo 'Habilitando o login local'
# ---------------------------------------------------------------------------
# Popular local_auth_config e o que LIGA o login local. Um projeto Supabase que
# receba estas migrations fica com a funcao presente mas inerte, porque esta
# tabela permanece vazia la — nao se cria um caminho de autenticacao paralelo ao
# Supabase Auth por acidente.
$r = ExecScript -Nome 'authcfg.sh' -Conteudo @"
set -e
psql -U postgres -q -v ON_ERROR_STOP=1 <<'SQL'
insert into public.local_auth_config (id, jwt_secret, token_ttl_hours)
values (true, '$jwtSecret', 12)
on conflict (id) do update
  set jwt_secret = excluded.jwt_secret,
      token_ttl_hours = excluded.token_ttl_hours,
      updated_at = now();
SQL
"@

if ($r.Codigo -ne 0) {
  $r.Saida | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }
  exit 1
}
Ok 'segredo de assinatura sincronizado com o PostgREST'

# ---------------------------------------------------------------------------
Passo 'Usuario do dashboard'
# ---------------------------------------------------------------------------
# UUID fixo para o usuario de exemplo: reexecutar nao cria usuario novo.
# Todos os digitos sao HEXADECIMAIS. A versao anterior terminava em "dev01" e o
# Postgres rejeitava, porque 'v' nao existe em hexadecimal.
$userId = '0198b1c0-0000-4000-8000-00000000dbba'
$email = 'dev@local'

$r = ExecScript -Nome 'usuario.sh' -Conteudo @"
set -e
psql -U postgres -q -v ON_ERROR_STOP=1 <<'SQL'
insert into public.user_roles (user_id, role, note)
values ('$userId', 'admin', 'usuario tecnico do dev-up')
on conflict (user_id) do update set role = 'admin';
SQL
"@

if ($r.Codigo -ne 0) {
  $r.Saida | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }
  exit 1
}

# Restaura o usuario real a partir do HASH guardado no .env.local. Assim um
# `-Recriar` (que apaga o volume) nao obriga a recriar a conta, e a SENHA nunca
# precisa ficar em arquivo — so o bcrypt.
$devEmail = $vars['DEV_USER_EMAIL']
$devHash  = $vars['DEV_USER_HASH']

if ($devEmail -and $devHash) {
  $devNome = if ($vars['DEV_USER_NAME']) { $vars['DEV_USER_NAME'] } else { '' }
  $devRole = if ($vars['DEV_USER_ROLE']) { $vars['DEV_USER_ROLE'] } else { 'admin' }

  # SQL puro, SEM bloco DO.
  #
  # A versao anterior usava `do $do$ ... $do$` e nao funcionava: dentro de um
  # here-string @"..."@ do PowerShell, escapar o `$` exige backtick, e eu escrevi
  # `\$do\$` — a barra invertida ia LITERAL para o arquivo e o psql respondia
  # "invalid command \$do". Dois statements independentes eliminam a necessidade
  # de dollar-quoting e a classe inteira de erro de escape.
  $r = ExecScript -Nome 'usuario-real.sh' -Conteudo @"
set -e
psql -U postgres -q -v ON_ERROR_STOP=1 <<'SQL'
insert into public.app_users (email, password_hash, full_name)
values (lower('$devEmail'), '$devHash', '$devNome')
on conflict (lower(email)) do update
  set password_hash = excluded.password_hash,
      full_name = excluded.full_name,
      is_active = true,
      failed_attempts = 0,
      locked_until = null;

insert into public.user_roles (user_id, role, note)
select u.user_id, '$devRole', 'login local'
from public.app_users u
where lower(u.email) = lower('$devEmail')
on conflict (user_id) do update set role = excluded.role;
SQL
"@

  if ($r.Codigo -ne 0) {
    Write-Host '   nao foi possivel restaurar o usuario do .env.local:' -ForegroundColor Yellow
    $r.Saida | ForEach-Object { Write-Host "   $_" -ForegroundColor Yellow }
  } else {
    Ok "usuario restaurado do .env.local: $devEmail (perfil $devRole)"
  }
} else {
  Info 'nenhum usuario em .env.local — crie com scripts\criar-usuario.ps1'
}

# JWT HS256 com as mesmas claims do Supabase Auth. Feito em node porque
# PowerShell 5.1 nao tem primitiva de JWT e escrever HMAC na mao aqui seria
# mais codigo para errar.
#
# Sao emitidos DOIS tokens, e a separacao espelha a producao:
#   authenticated -> o dashboard. Sujeito a RLS, escopado por loja.
#   service_role  -> o simulador de agente, no lugar da Edge Function. E o unico
#                    com EXECUTE em ingest_batch.
# O simulador falhar com "permission denied for function ingest_batch" usando o
# token do dashboard nao foi um problema: foi a regra 3 funcionando.
$tokenJs = @'
const crypto = require('crypto');
const [secret, sub, email] = process.argv.slice(2);
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const agora = Math.floor(Date.now() / 1000);
const cabecalho = b64({ alg: 'HS256', typ: 'JWT' });

function assinar(corpoObj) {
  const corpo = b64(corpoObj);
  const assinatura = crypto.createHmac('sha256', secret)
    .update(`${cabecalho}.${corpo}`).digest('base64url');
  return `${cabecalho}.${corpo}.${assinatura}`;
}

const validade = agora + 60 * 60 * 24 * 30;

const tokenAuth = assinar({
  aud: 'authenticated', role: 'authenticated', sub, email, iat: agora, exp: validade,
});

const tokenServico = assinar({
  aud: 'authenticated', role: 'service_role', iat: agora, exp: validade,
});
process.stdout.write(JSON.stringify({
  token: tokenAuth,
  serviceToken: tokenServico,
  email,
  restUrl: process.argv[5],
}, null, 2));
'@

$tmpJs = Join-Path $env:TEMP 'monitor-gerar-jwt.js'
$tokenJs | Out-File -FilePath $tmpJs -Encoding ascii

$r = Exec $node.Source @($tmpJs, $jwtSecret, $userId, $email, $restUrl) -Silencioso
if ($r.Codigo -ne 0) {
  $r.Saida | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }
  exit 1
}
$tokensJson = ($r.Saida -join '')
$tokens = $tokensJson | ConvertFrom-Json
Remove-Item $tmpJs -Force -ErrorAction SilentlyContinue

# O arquivo servido ao navegador leva SOMENTE a URL da API. Nenhum token vai
# para o disco publico: o dashboard obtem o dele fazendo login de verdade, e o de
# service_role fica em memoria e vai ao simulador por parametro.
#
# A versao anterior publicava um token pronto em dev-token.json — quem abrisse a
# URL entrava sem senha. O login real eliminou isso.
@{
  restUrl  = $restUrl
  authMode = 'local'
} | ConvertTo-Json | Out-File -FilePath (Join-Path $repoRoot 'dashboard\dev-config.json') -Encoding ascii

$antigo = Join-Path $repoRoot 'dashboard\dev-token.json'
if (Test-Path $antigo) {
  Remove-Item $antigo -Force
  Info 'dev-token.json removido (nao ha mais token publicado em disco)'
}

Ok 'dashboard/dev-config.json gerado (apenas a URL da API)'

# ---------------------------------------------------------------------------
Passo 'Verificando a API'
# ---------------------------------------------------------------------------
$token = $tokens.token
$restOk = $false
$visiveis = 0

for ($i = 0; $i -lt 40; $i++) {
  try {
    $r = Invoke-RestMethod -Uri "$restUrl/rpc/dashboard_summary" -Method Post `
           -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json' -Body '{}'
    $restOk = $true
    $visiveis = [int]$r.machines_total
    Ok "PostgREST respondendo: $visiveis maquina(s) visiveis"
    break
  } catch {
    Start-Sleep -Milliseconds 900
  }
}

if (-not $restOk) {
  Write-Host '   PostgREST nao respondeu. Logs:' -ForegroundColor Red
  Exec 'docker' @('compose', 'logs', '--tail', '25', 'rest') | Out-Null
  exit 1
}

# 5 maquinas no seed e o admin ve todas. Zero aqui significa que auth.uid()
# devolveu NULL — sintoma silencioso de GUC de JWT no formato errado.
if ($visiveis -eq 0) {
  Write-Host '   FALHA: o usuario admin nao ve nenhuma maquina.' -ForegroundColor Red
  Write-Host '   Provavel causa: auth.uid() nao esta lendo as claims do JWT.' -ForegroundColor Red
  Write-Host '   Depure com:' -ForegroundColor Yellow
  Write-Host "     docker exec monitor-db psql -U postgres -c ""select public.current_user_is_admin();"""
  exit 1
}

# Regra 3, verificada de fora: quem chega sem token nao le nada.
try {
  Invoke-RestMethod -Uri "$restUrl/machines_status?select=machine_id" -Method Get | Out-Null
  Write-Host '   FALHA DE SEGURANCA: anon leu machines_status' -ForegroundColor Red
  exit 1
} catch {
  Ok 'anon sem token recebe negativa (RLS + grants funcionando)'
}

# ---------------------------------------------------------------------------
if (-not $SemSimulador) {
  Passo 'Enviando metricas pela ingestao real'
  & (Join-Path $PSScriptRoot 'simular-agentes.ps1') `
      -Horas $Horas -RestUrl $restUrl -ServiceToken $tokens.serviceToken
  if ($LASTEXITCODE -ne 0) { Write-Host 'simulador falhou' -ForegroundColor Red; exit 1 }
}

# ---------------------------------------------------------------------------
Passo 'Pronto'
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Green
Write-Host '   SISTEMA NO AR' -ForegroundColor Green
Write-Host '  ============================================================' -ForegroundColor Green
Write-Host "   Dashboard : $webUrl"
Write-Host "   API       : $restUrl"
Write-Host '   Banco     : sem porta publicada (regra 8) - use docker exec'
Write-Host ''
Write-Host '   Entre com o e-mail e a senha criados por criar-usuario.ps1.'
Write-Host '   Criar/trocar: .\scripts\criar-usuario.ps1 -Email voce@empresa.com'
Write-Host ''
Write-Host '   Parar        : docker compose down'
Write-Host '   Apagar tudo  : docker compose down -v'
Write-Host '   SQL          : docker exec -it monitor-db psql -U postgres'
Write-Host '  ============================================================' -ForegroundColor Green
Write-Host ''

# A URL abre com ?v= e um carimbo de tempo.
#
# Isso e o que garante que o navegador NAO sirva a pagina do proprio cache: uma
# URL que ele nunca viu nao tem entrada em cache, ponto. Sem isto, dependia de o
# usuario saber fazer Ctrl+Shift+R — e enquanto ele nao fizesse, veria uma versao
# antiga do dashboard e nenhuma pista do motivo.
$carimbo = (Get-Date).ToString('yyyyMMddHHmmss')
$urlAbrir = "$webUrl/?v=$carimbo"

Write-Host "   Abrindo: $urlAbrir" -ForegroundColor Cyan
Write-Host '   (o ?v= evita que o navegador use uma copia antiga da pagina)' -ForegroundColor DarkGray
Write-Host ''

try { Start-Process $urlAbrir } catch { Info "abra $urlAbrir no navegador" }
