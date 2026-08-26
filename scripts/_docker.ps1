# =============================================================================
# Ajuda comum: o psql vem do contentor, e o contentor cai
# =============================================================================
# O psql nao esta no PATH desta maquina, entao os scripts de producao usam o de
# dentro do monitor-db. So que o Docker Desktop caiu tres vezes num dia de
# trabalho, e cada queda virou um erro cru na tela do Kaua no meio de uma tarefa.
#
# Este arquivo e carregado por ponto (dot-sourcing) pelos scripts que precisam do
# psql: ele detecta o motor parado, sobe o Docker Desktop, espera, e -- se nao
# subir -- diz exatamente o que fazer, em vez de deixar o comando falhar com
# "npipe: The system cannot find the file specified".
# =============================================================================

function Test-DockerVivo {
  # 'Continue' e $LASTEXITCODE: o docker escreve o erro no stderr, e o PowerShell
  # 5.1 embrulha stderr de programa nativo num ErrorRecord -- com 'Stop' isso
  # abortaria o script inteiro so por perguntar se o motor esta de pe.
  $antes = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
  } catch {
    return $false
  } finally {
    $ErrorActionPreference = $antes
  }
}

function Test-ContentorVivo([string] $Nome = 'monitor-db') {
  $antes = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $n = docker ps --filter "name=$Nome" --format '{{.Names}}' 2>$null
    return (($n | Out-String) -match [regex]::Escape($Nome))
  } catch {
    return $false
  } finally {
    $ErrorActionPreference = $antes
  }
}

<#
.SYNOPSIS
  Garante Docker e contentor de pe, subindo o que faltar. Devolve $true/$false.
#>
function Assert-PsqlDisponivel {
  param([int] $EsperaSegundos = 150)

  # psql de verdade no PATH dispensa Docker inteiro.
  if (Get-Command psql -ErrorAction SilentlyContinue) { return $true }

  if ($null -eq (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host 'Nem psql no PATH nem docker instalado.' -ForegroundColor Red
    return $false
  }

  if (-not (Test-DockerVivo)) {
    $exes = @(
      "$env:LOCALAPPDATA\Programs\DockerDesktop\Docker Desktop.exe",
      'C:\Program Files\Docker\Docker\Docker Desktop.exe'
    )
    $exe = $exes | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $exe) {
      Write-Host 'Docker parado e nao achei o Docker Desktop para iniciar.' -ForegroundColor Red
      Write-Host 'Abra o Docker Desktop a mao e rode de novo.' -ForegroundColor Yellow
      return $false
    }

    Write-Host 'Docker parado: iniciando o Docker Desktop...' -ForegroundColor Yellow
    Start-Process $exe

    $fim = (Get-Date).AddSeconds($EsperaSegundos)
    while ((Get-Date) -lt $fim) {
      Start-Sleep -Seconds 5
      if (Test-DockerVivo) { break }
      Write-Host '.' -NoNewline -ForegroundColor DarkGray
    }
    Write-Host ''

    if (-not (Test-DockerVivo)) {
      Write-Host "O motor do Docker nao subiu em $EsperaSegundos s." -ForegroundColor Red
      Write-Host 'Abra o Docker Desktop, espere ficar verde, e rode de novo.' -ForegroundColor Yellow
      return $false
    }
    Write-Host '   motor de pe.' -ForegroundColor DarkGray
  }

  if (-not (Test-ContentorVivo 'monitor-db')) {
    # O contentor pode demorar alguns segundos depois do motor.
    for ($i = 0; $i -lt 12; $i++) {
      Start-Sleep -Seconds 5
      if (Test-ContentorVivo 'monitor-db') { break }
    }
  }

  if (-not (Test-ContentorVivo 'monitor-db')) {
    Write-Host 'O contentor monitor-db nao esta de pe.' -ForegroundColor Red
    Write-Host 'Suba a stack local: .\scripts\dev-up.ps1' -ForegroundColor Yellow
    Write-Host '(este script usa o psql de dentro dele para falar com PRODUCAO;' -ForegroundColor DarkGray
    Write-Host ' o banco local em si nao e consultado)' -ForegroundColor DarkGray
    return $false
  }

  return $true
}
