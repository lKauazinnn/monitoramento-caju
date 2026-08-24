<#
.SYNOPSIS
  Empurra a frota deste monitoramento para a API Sentinela do sistema principal,
  para as maquinas aparecerem la.

.DESCRIPTION
  Le o estado atual do NOSSO banco e faz um POST por maquina em
  /functions/v1/sentinela-ingest do projeto Sentinela, traduzindo os campos.

  AUTENTICACAO: aquele endpoint usa TOKEN DE AGENTE, um por maquina, emitido em
  Sentinela > Cadastros > Gerar token. Nao existe token global. Entao este script
  precisa de um arquivo com o token de cada maquina -- ver -ArquivoTokens.

  O QUE ELE NAO FAZ, DE PROPOSITO:

  Nao empurra maquina OFFLINE. O POST e um sinal de vida: quem recebe marca a
  maquina como vista AGORA. Mandar a ultima amostra de uma maquina desligada ha
  tres horas faria o painel do outro sistema mostra-la ONLINE para sempre, e ele
  nunca abriria alerta por ela -- o oposto do proposito. O silencio e a
  informacao; deixo o silencio chegar la tambem.

  Use -IncluirOffline apenas para uma carga inicial de INVENTARIO, sabendo que as
  offline vao aparecer como vistas agora ate o proximo ciclo.

  Nao empurra volume desmarcado aqui (machine_volumes.acompanhar = false). Se o D:
  de backup foi tirado da conta neste painel de proposito, manda-lo para la
  reintroduziria o mesmo alerta eterno no outro sistema.

.PARAMETER ArquivoTokens
  JSON { "NOME-DA-MAQUINA": "token", ... }. Padrao:
  %LOCALAPPDATA%\sentinela\tokens-espelho.json

  FORA do repositorio de proposito: sao credenciais de outro sistema, precisam
  viajar em texto claro (nao ha como hashear o que tem de ser enviado) e nao podem
  entrar em commit.

.PARAMETER Url
  Endpoint de ingestao do outro sistema.

.PARAMETER Maquina
  Filtra por trecho do nome. Padrao: todas.

.PARAMETER Simular
  Mostra exatamente o que seria enviado, e NAO envia. Use na primeira vez.

.PARAMETER IncluirOffline
  Envia tambem as offline. Leia o aviso acima antes.

.EXAMPLE
  .\scripts\espelhar-no-sentinela.ps1 -Simular

.EXAMPLE
  .\scripts\espelhar-no-sentinela.ps1
#>
[CmdletBinding()]
param(
  [string] $ArquivoTokens = "$env:LOCALAPPDATA\sentinela\tokens-espelho.json",
  [string] $Url = 'https://bieknqhxbecmakxgaspe.supabase.co/functions/v1/sentinela-ingest',
  [string] $Maquina = '%',
  [switch] $Simular,
  [switch] $IncluirOffline,
  [string] $UrlBanco,
  [System.Security.SecureString] $Senha
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot

# ------------------------------------------------------------------ os tokens
$tokens = @{}
if (Test-Path $ArquivoTokens) {
  (Get-Content $ArquivoTokens -Raw | ConvertFrom-Json).PSObject.Properties |
    ForEach-Object { $tokens[$_.Name] = $_.Value }
}

if ($Simular) {
  Write-Host 'SIMULACAO: nada sera enviado.' -ForegroundColor Yellow
} elseif ($tokens.Count -eq 0) {
  Write-Host ''
  Write-Host "Nenhum token em: $ArquivoTokens" -ForegroundColor Red
  Write-Host ''
  Write-Host 'Cada maquina precisa do SEU token, emitido no outro sistema em'
  Write-Host 'Sentinela > Cadastros > Gerar token. Crie o arquivo assim:'
  Write-Host ''
  Write-Host '  {' -ForegroundColor DarkGray
  Write-Host '    "CAJU-ASN": "eyJhbGciOi...",' -ForegroundColor DarkGray
  Write-Host '    "SERVIDOR-NAZO-SUL": "eyJhbGciOi..."' -ForegroundColor DarkGray
  Write-Host '  }' -ForegroundColor DarkGray
  Write-Host ''
  Write-Host 'A chave e o NOME DA MAQUINA como aparece neste painel.'
  Write-Host 'Rode com -Simular para ver os nomes exatos e o que seria enviado.'
  exit 1
} else {
  Write-Host "$($tokens.Count) token(s) carregado(s)" -ForegroundColor DarkGray
}

# --------------------------------------------------------------------- o banco
if ([string]::IsNullOrWhiteSpace($UrlBanco)) {
  $arq = Join-Path $raiz 'supabase\.temp\pooler-url'
  if (-not (Test-Path $arq)) {
    Write-Host 'Passe -UrlBanco: nao achei supabase\.temp\pooler-url.' -ForegroundColor Red
    exit 1
  }
  $UrlBanco = (Get-Content $arq -Raw).Trim()
}

if ($null -eq $Senha) { $Senha = Read-Host -Prompt 'Senha do banco de producao' -AsSecureString }
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Senha)
try { $senhaNua = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

$psql = Get-Command psql -ErrorAction SilentlyContinue
$viaDocker = $null -eq $psql
if ($viaDocker -and $null -eq (Get-Command docker -ErrorAction SilentlyContinue)) {
  Write-Host 'Nem psql no PATH nem docker (suba o Docker Desktop).' -ForegroundColor Red
  exit 1
}

# =============================================================================
# A traducao mora no SQL
# =============================================================================
# O de-para fica aqui, e nao no PowerShell, por dois motivos: da para ler os dois
# lados na mesma linha, e o resultado ja sai no formato exato que a outra API
# espera -- o script nao monta nada, so entrega.
#
# jsonb_strip_nulls no fim: campo que nao medimos vai AUSENTE, e nao null. Uma API
# que valida tipo costuma recusar null num campo numerico, e "ausente" e a verdade
# (nao medimos), enquanto null pode ser lido como zero do outro lado.
$sql = @'
\pset tuples_only on
\pset format unaligned
\pset fieldsep '|'

with alvo as (
  select ms.*
  from public.machines_status ms
  where ms.label ilike :'padrao'
    and ms.is_active
    and ms.last_sample_at is not null
    and (:incluir_offline or ms.status in ('online', 'degradado'))
)
select
  a.label,
  a.status,
  jsonb_strip_nulls(jsonb_build_object(
    -- O outro sistema documenta "1.4.0"; o nosso e "ps-1.8.0". Mando so a parte
    -- numerica para nao arriscar uma validacao de formato do outro lado.
    'versao_agente', regexp_replace(coalesce(a.agent_version, ''), '^ps-', ''),
    'host', jsonb_build_object(
      'hostname', coalesce(a.hostname, a.label),
      'ip_lan',   a.ip_lan,
      'so_nome',  a.os_caption
    ),
    'metricas', jsonb_build_object(
      'cpu_pct',             a.cpu_pct,
      -- Reserva: mem_pct e preenchida pelo agente, nao derivada. Agente antigo
      -- deixa nula, e o campo sumiria do corpo (jsonb_strip_nulls). Com usado e
      -- total na mao, calcular e aritmetica honesta.
      'memoria_pct', coalesce(
        a.mem_pct,
        case when coalesce(a.mem_total_mb, 0) > 0
             then round(a.mem_used_mb::numeric * 100 / a.mem_total_mb, 1)
        end),
      'uptime_segundos',     a.uptime_seconds,
      'latencia_gateway_ms', a.gw_latency_ms
    ),
    'discos', (
      select jsonb_agg(jsonb_build_object(
               'unidade',  d.drive,
               'total_gb', round(d.total_gb)::int,
               'livre_gb', round(d.free_gb)::int,
               'smart_ok', d.smart_ok
             ) order by d.drive)
      from public.metrics_disks d
      left join public.machine_volumes mv
             on mv.machine_id = d.machine_id
            and mv.drive = upper(btrim(d.drive))
      where d.machine_id = a.machine_id
        and d."time" = a.last_sample_at
        -- Respeita a escolha feita NESTE painel: volume desmarcado aqui nao vai
        -- para la reintroduzir o alerta que a gente acabou de calar.
        and coalesce(mv.acompanhar, true)
    ),
    'servicos', (
      select jsonb_agg(jsonb_build_object(
               'servico', sv.service_name,
               'rodando', sv.is_running
             ) order by sv.service_name)
      from public.metrics_services sv
      where sv.machine_id = a.machine_id
        and sv."time" = a.last_sample_at
    )
  ))::text as corpo
from alvo a
order by a.label;
'@

$tmp = Join-Path $env:TEMP 'espelho-sentinela.sql'
Set-Content -Path $tmp -Value $sql -Encoding utf8

$off = $IncluirOffline.IsPresent.ToString().ToLower()

function Consultar {
  # 'Continue' em volta do nativo: o psql escreve avisos no stderr e o PowerShell
  # 5.1 embrulha cada linha num ErrorRecord, o que com 'Stop' abortaria aqui.
  $antes = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($viaDocker) {
      docker cp $tmp monitor-db:/tmp/espelho.sql | Out-Null
      docker exec -e PGPASSWORD=$senhaNua monitor-db psql $UrlBanco `
        -v padrao="$Maquina" -v incluir_offline=$off -f /tmp/espelho.sql
    } else {
      $env:PGPASSWORD = $senhaNua
      & $psql.Source $UrlBanco -v padrao="$Maquina" -v incluir_offline=$off -f $tmp
    }
  } finally { $ErrorActionPreference = $antes }
}

Write-Host ''
Write-Host '== Lendo a frota ==' -ForegroundColor Cyan
$linhas = @(Consultar | Where-Object { $_ -match '\|\{' })
Remove-Item $tmp -ErrorAction SilentlyContinue

if ($linhas.Count -eq 0) {
  Write-Host 'Nenhuma maquina para espelhar.' -ForegroundColor Yellow
  if (-not $IncluirOffline) {
    Write-Host 'Sem -IncluirOffline so vao as online -- talvez seja isso.' -ForegroundColor DarkGray
  }
  exit 0
}

Write-Host "$($linhas.Count) maquina(s)"
Write-Host ''
Write-Host '== Enviando ==' -ForegroundColor Cyan

$ok = 0; $erro = 0; $semToken = 0

foreach ($l in $linhas) {
  # Divido no maximo 3 vezes: o corpo e JSON e pode conter '|' dentro.
  $p = $l -split '\|', 3
  $nome = $p[0]; $estado = $p[1]; $corpo = $p[2]

  if (-not $tokens.ContainsKey($nome)) {
    $semToken++
    Write-Host ("  {0,-28} SEM TOKEN" -f $nome) -ForegroundColor DarkYellow
    if ($Simular) { Write-Host "      $corpo" -ForegroundColor DarkGray }
    continue
  }

  if ($Simular) {
    Write-Host ("  {0,-28} [{1}] enviaria:" -f $nome, $estado) -ForegroundColor DarkGray
    Write-Host "      $corpo" -ForegroundColor DarkGray
    $ok++
    continue
  }

  try {
    $r = Invoke-RestMethod -Method Post -Uri $Url -TimeoutSec 25 `
      -Headers @{ Authorization = "Bearer $($tokens[$nome])" } `
      -ContentType 'application/json' -Body $corpo

    # A API documenta { "sucesso": true }. HTTP 200 com sucesso=false e RECUSA, e
    # tratar isso como sucesso esconderia o problema exatamente onde ele importa.
    if ($r.sucesso -eq $true) {
      $ok++
      Write-Host ("  {0,-28} ok" -f $nome) -ForegroundColor Green
    } else {
      $erro++
      Write-Host ("  {0,-28} RECUSADO: {1}" -f $nome, ($r | ConvertTo-Json -Compress -Depth 4)) -ForegroundColor Red
    }
  } catch {
    $erro++
    $st = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
    Write-Host ("  {0,-28} ERRO HTTP {1}: {2}" -f $nome, $st, $_.Exception.Message) -ForegroundColor Red
  }
}

Write-Host ''
Write-Host '============================================================'
Write-Host (" {0} enviada(s) | {1} com erro | {2} sem token" -f $ok, $erro, $semToken)
Write-Host '============================================================'

if ($semToken -gt 0) {
  Write-Host ''
  Write-Host "Emita o token dessas $semToken maquina(s) no outro sistema" -ForegroundColor Yellow
  Write-Host '(Sentinela > Cadastros > Gerar token) e acrescente em:' -ForegroundColor Yellow
  Write-Host "  $ArquivoTokens" -ForegroundColor Yellow
  Write-Host 'Gerar novamente REVOGA o token anterior daquela maquina.' -ForegroundColor DarkGray
}
Write-Host ''
