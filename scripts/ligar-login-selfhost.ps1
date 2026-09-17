<#
.SYNOPSIS
  Liga o login por e-mail e senha na stack self-hosted. Roda NA MAQUINA
  SERVIDORA.

.DESCRIPTION
  O BURACO QUE ISTO TAPA

  O painel autentica no Supabase Auth (`/auth/v1/token`). A stack self-hosted
  nao tem esse endpoint -- o nginx so expoe /rest/v1 e /functions/v1/ingest. E
  no modo `local` o painel simplesmente NAO PEDE SENHA: o login.js diz "stack
  local nao usa login" e manda direto para o dashboard. Isso era aceitavel em
  127.0.0.1; num endereco publico seria o painel inteiro aberto para quem tiver
  o link.

  A peca que falta ja existe no banco desde a 0014: `local_sign_in(email, senha)`
  confere bcrypt, tem bloqueio por tentativas repetidas e devolve um JWT com
  `role: authenticated` -- que e exatamente o que o PostgREST valida e o RLS usa.
  Ela nasceu INERTE de proposito: falha com "login local nao esta habilitado"
  enquanto a tabela `local_auth_config` estiver vazia, para que aplicar as
  migrations num projeto Supabase nao criasse um caminho de autenticacao
  paralelo por acidente.

  Este script preenche essa tabela -- e so isso. Uma linha, com o MESMO
  JWT_SECRET que o PostgREST usa (PGRST_JWT_SECRET no compose): se os dois
  segredos diferirem, o login "funciona" e todo pedido seguinte volta 401, que e
  dos sintomas mais confusos que existem.

  O SEGREDO NAO PASSA PELA LINHA DE COMANDO. Ele vai num arquivo .sql temporario
  copiado para dentro do contentor e apagado depois -- comando com segredo fica
  no historico do PowerShell e na lista de processos.

.PARAMETER Horas
  Validade do token de sessao. Padrao: 12 (um expediente).

.EXAMPLE
  .\scripts\ligar-login-selfhost.ps1
#>
[CmdletBinding()]
param(
  [int]    $Horas = 12,
  [string] $Container = 'monitor-db',
  [string] $Raiz
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Raiz)) { $Raiz = Split-Path -Parent $PSScriptRoot }
$envSelf = Join-Path $Raiz '.env.selfhost'

function Falhar([string] $texto) { Write-Host $texto -ForegroundColor Red; exit 1 }

function Invocar([scriptblock] $Bloco) {
  $antes = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $Bloco } finally { $ErrorActionPreference = $antes }
}

if (-not (Test-Path $envSelf)) { Falhar "nao achei $envSelf (rode na maquina servidora)." }

$jwtSecret = $null
foreach ($linha in (Get-Content $envSelf)) {
  if ($linha -match '^\s*JWT_SECRET\s*=\s*(.+?)\s*$') { $jwtSecret = $Matches[1] }
}
if ([string]::IsNullOrWhiteSpace($jwtSecret)) { Falhar 'JWT_SECRET ausente no .env.selfhost.' }
if ($jwtSecret.Length -lt 32) { Falhar 'JWT_SECRET com menos de 32 caracteres: o PostgREST recusa.' }

$vivo = Invocar { docker inspect -f '{{.State.Running}}' $Container }
if ($LASTEXITCODE -ne 0 -or ("$vivo".Trim() -ne 'true')) { Falhar "o contentor $Container nao esta de pe." }

# ---------------------------------------------------------------------------
# A linha unica de configuracao
# ---------------------------------------------------------------------------
# `id boolean primary key check (id)` limita a tabela a UMA linha (ver 0014):
# dois segredos seriam duas verdades, e a segunda quebraria a validacao no
# PostgREST sem erro compreensivel. Por isso on conflict update, e nao insert.
$sqlLocal = Join-Path $env:TEMP ("login-selfhost-{0}.sql" -f (Get-Date -Format 'yyyyMMddHHmmssfff'))
$segredoEscapado = $jwtSecret.Replace("'", "''")

$sql = @"
insert into public.local_auth_config (id, jwt_secret, token_ttl_hours)
values (true, '$segredoEscapado', $Horas)
on conflict (id) do update
  set jwt_secret = excluded.jwt_secret,
      token_ttl_hours = excluded.token_ttl_hours;

do `$do`$
declare
  v_resposta jsonb;
begin
  -- A PROVA, e ela e de comportamento e nao de configuracao: com a tabela
  -- vazia, local_sign_in LEVANTA EXCECAO ('login local nao esta habilitado').
  -- Se esta chamada devolver o json de credencial invalida, o login esta vivo.
  -- Usuario inexistente de proposito: nao e preciso saber senha de ninguem
  -- para provar que o caminho existe.
  v_resposta := public.local_sign_in('ninguem@invalido.invalido', 'x');

  if coalesce((v_resposta->>'ok')::boolean, true) then
    raise exception 'resposta inesperada do login: %', v_resposta;
  end if;

  raise notice 'login local habilitado; TTL de $Horas h.';
end
`$do`$;
"@

Set-Content -Path $sqlLocal -Value $sql -Encoding utf8

try {
  Invocar {
    docker cp $sqlLocal "${Container}:/tmp/login-selfhost.sql" | Out-Null
    docker exec $Container psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/login-selfhost.sql
  }
  $codigo = $LASTEXITCODE
} finally {
  Remove-Item $sqlLocal -Force -ErrorAction SilentlyContinue
  Invocar { docker exec $Container rm -f /tmp/login-selfhost.sql } | Out-Null
}

if ($codigo -ne 0) { Falhar 'falhou ao habilitar o login local.' }

# ---------------------------------------------------------------------------
# Quem pode entrar
# ---------------------------------------------------------------------------
$usuarios = (Invocar {
  docker exec $Container psql -U postgres -d postgres -A -t `
    -c "select coalesce(string_agg(email || ' (' || coalesce(role,'sem papel') || ')', ', '), 'NENHUM') from public.app_users u left join public.user_roles r on r.user_id = u.user_id;"
} | Out-String).Trim()

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' Login local habilitado' -ForegroundColor Green
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host " Quem pode entrar: $usuarios"
Write-Host ''
Write-Host ' Se a senha nao for conhecida, defina outra (ela e digitada escondida):'
Write-Host '   .\scripts\criar-usuario.ps1 -Email kaualarsson@cajupar.com -Perfil admin'
Write-Host ''
Write-Host ' Falta ainda o painel APONTAR para ca -- e isso e o proximo passo,' -ForegroundColor Yellow
Write-Host ' com o config.producao.js e a publicacao na Vercel.' -ForegroundColor Yellow
exit 0
