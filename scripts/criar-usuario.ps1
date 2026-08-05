<#
.SYNOPSIS
  Cria ou atualiza um usuario do dashboard na stack local.

.DESCRIPTION
  A senha e pedida de forma oculta e trafega por STDIN, nunca por argumento de
  linha de comando nem por arquivo em disco. Isso importa porque argumento de
  processo e visivel para qualquer usuario da maquina (Get-Process, tasklist) e
  fica no historico do PowerShell.

  No banco fica apenas o hash bcrypt (custo 12). Nao existe caminho de leitura da
  senha.

  Para trocar a senha depois, rode o mesmo comando: a funcao faz upsert e
  destrava a conta.

.PARAMETER Email
  E-mail do usuario. Usado como identificador (case-insensitive).

.PARAMETER Nome
  Nome completo, mostrado no dashboard.

.PARAMETER Perfil
  admin  = ve todas as lojas e administra o cadastro
  operator = ve o escopo e reconhece alertas
  viewer = somente leitura

.PARAMETER Lojas
  Codigos de loja aos quais o usuario tem acesso. Ignorado para admin, que ve
  tudo. Ex.: -Lojas BSB-001,SP-001

.PARAMETER SenhaTexto
  Senha em texto. NAO recomendado: fica no historico do shell. Use apenas em
  automacao, e prefira o prompt oculto.

.EXAMPLE
  .\scripts\criar-usuario.ps1 -Email kaualarsson@cajupar.com -Nome 'Kaua Larsson'

.EXAMPLE
  .\scripts\criar-usuario.ps1 -Email gerente.bsb001@cajupar.com -Perfil viewer -Lojas BSB-001
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string] $Email,
  [string] $Nome = '',
  [ValidateSet('admin', 'operator', 'viewer')][string] $Perfil = 'admin',
  [string[]] $Lojas = @(),
  [string] $SenhaTexto = '',
  [string] $Container = 'monitor-db'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

function Info { param([string]$T) Write-Host "   $T" -ForegroundColor DarkGray }
function Ok   { param([string]$T) Write-Host "   $T" -ForegroundColor Green }

# ---------------------------------------------------------------------------
# Pre-requisitos
# ---------------------------------------------------------------------------
$docker = Get-Command docker -ErrorAction SilentlyContinue
if ($null -eq $docker) { Write-Host 'docker nao encontrado.' -ForegroundColor Red; exit 1 }

$existe = & docker ps --filter "name=$Container" --format '{{.Names}}' 2>$null
if ($existe -notcontains $Container) {
  Write-Host "container $Container nao esta rodando. Rode .\scripts\dev-up.ps1 primeiro." -ForegroundColor Red
  exit 1
}

# ---------------------------------------------------------------------------
# Senha
# ---------------------------------------------------------------------------
if ($SenhaTexto) {
  Write-Host ''
  Write-Host 'AVISO: senha passada por parametro fica no historico do PowerShell.' -ForegroundColor Yellow
  Write-Host 'Limpe depois com: Clear-History; Remove-Item (Get-PSReadlineOption).HistorySavePath' -ForegroundColor Yellow
  $senha = $SenhaTexto
} else {
  Write-Host ''
  $s1 = Read-Host "Senha para $Email" -AsSecureString
  $s2 = Read-Host 'Repita a senha' -AsSecureString

  # Marshal + ZeroFreeBSTR: a senha em claro existe em memoria pelo menor tempo
  # possivel e a regiao e zerada depois. String normal do .NET ficaria no heap
  # ate o GC passar.
  $b1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s1)
  $b2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s2)
  try {
    $senha  = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b1)
    $senha2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b2)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b1)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2)
  }

  if ($senha -ne $senha2) { Write-Host 'As senhas nao coincidem.' -ForegroundColor Red; exit 1 }
}

if ($senha.Length -lt 8) { Write-Host 'A senha precisa de ao menos 8 caracteres.' -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------------------
# Criacao
# ---------------------------------------------------------------------------
# Aspas simples dobradas: literal SQL nao aceita ' solto. Sem isto, uma senha com
# apostrofo quebraria a instrucao — e no pior caso executaria o resto como SQL.
function EscSql { param([string]$V) return $V.Replace("'", "''") }

$lojasSql = ''
if ($Perfil -ne 'admin' -and $Lojas.Count -gt 0) {
  $lista = ($Lojas | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) |
             ForEach-Object { "'" + (EscSql $_) + "'" }
  $lojasSql = @"

delete from public.user_site_access where user_id = v_id;
insert into public.user_site_access (user_id, site_id)
select v_id, s.id from public.sites s where upper(s.code) in ($(($lista | ForEach-Object { $_.ToUpper() }) -join ', '));
"@
}

# O SQL vai por STDIN (docker exec -i), nao por -c: argumento de processo e
# visivel na lista de processos da maquina.
$sql = @"
do `$do`$
declare
  v_id uuid;
begin
  select u.user_id into v_id
  from public.upsert_local_user('$(EscSql $Email)', '$(EscSql $senha)', '$(EscSql $Nome)', '$Perfil') u;
  $lojasSql
  raise notice 'usuario % com perfil % (id %)', '$(EscSql $Email)', '$Perfil', v_id;
end
`$do`$;

select u.email, r.role,
       coalesce((select count(*) from public.user_site_access a where a.user_id = u.user_id), 0) as lojas,
       length(u.password_hash) as tamanho_hash,
       left(u.password_hash, 4) as algoritmo
from public.app_users u
join public.user_roles r on r.user_id = u.user_id
where lower(u.email) = lower('$(EscSql $Email)');
"@

$anterior = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  $saida = $sql | & docker exec -i $Container psql -U postgres -v ON_ERROR_STOP=1 2>&1 | ForEach-Object { "$_" }
  $codigo = $LASTEXITCODE
} finally {
  $ErrorActionPreference = $anterior
  # Zera a variavel: nao deixa a senha viva no escopo do script depois do uso.
  $senha = $null
  $senha2 = $null
  [System.GC]::Collect()
}

if ($codigo -ne 0) {
  Write-Host ''
  Write-Host 'FALHOU:' -ForegroundColor Red
  $saida | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }
  exit 1
}

Write-Host ''
$saida | Where-Object { $_ -match 'NOTICE|bcrypt|\|' } | ForEach-Object { Info $_ }

Write-Host ''
Ok "usuario $Email criado/atualizado com perfil $Perfil"
Info 'no banco fica apenas o hash bcrypt (prefixo $2a$ = blowfish, custo 12)'

# ---------------------------------------------------------------------------
# Persiste o HASH (nao a senha) para sobreviver a um dev-up -Recriar
# ---------------------------------------------------------------------------
# Guardar o hash e seguro e evita ter que recriar o usuario a cada reset do
# banco. Guardar a SENHA em arquivo nao seria.
$envFile = Join-Path $repoRoot '.env.local'
if (Test-Path $envFile) {
  $hash = ($saida | Where-Object { $_ -match '^\s*\$2[aby]\$' } | Select-Object -First 1)
  if (-not $hash) {
    $r = & docker exec -i $Container psql -U postgres -q -t -A -c "select password_hash from public.app_users where lower(email) = lower('$(EscSql $Email)');" 2>$null
    $hash = ($r | Where-Object { $_ -match '^\$2' } | Select-Object -First 1)
  }

  if ($hash) {
    $linhas = @(Get-Content $envFile | Where-Object { $_ -notmatch '^(DEV_USER_EMAIL|DEV_USER_HASH|DEV_USER_NAME|DEV_USER_ROLE)=' })
    $linhas += "DEV_USER_EMAIL=$Email"
    $linhas += "DEV_USER_NAME=$Nome"
    $linhas += "DEV_USER_ROLE=$Perfil"
    $linhas += "DEV_USER_HASH=$($hash.Trim())"
    $linhas | Out-File -FilePath $envFile -Encoding ascii
    Info 'hash guardado em .env.local (gitignored) para sobreviver a dev-up -Recriar'
  }
}

Write-Host ''
Write-Host '   Entre no dashboard com esse e-mail e senha.' -ForegroundColor Cyan
Write-Host '   Trocar a senha depois: rode este mesmo comando novamente.' -ForegroundColor DarkGray
Write-Host ''
