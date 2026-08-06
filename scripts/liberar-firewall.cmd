@echo off
rem ===========================================================================
rem  Libera a porta da ingestao no Firewall do Windows.
rem
rem  CLIQUE DUAS VEZES NESTE ARQUIVO. Ele resolve os dois obstaculos que fazem
rem  o .ps1 nao rodar direto:
rem
rem   1. politica de execucao. Por padrao o Windows recusa qualquer .ps1 com
rem      "a execucao de scripts foi desabilitada neste sistema". O
rem      -ExecutionPolicy Bypass vale SO para este processo  nao altera
rem      configuracao nenhuma da maquina, e some quando a janela fecha.
rem
rem   2. elevacao. Regra de firewall exige administrador. O -Verb RunAs pede a
rem      confirmacao do UAC.
rem
rem  -NoExit mantem a janela aberta: sem isso o resultado apareceria e sumiria
rem  antes de dar tempo de ler, que e o pior desfecho possivel para um script
rem  cujo proposito e justamente dizer se deu certo.
rem ===========================================================================

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File','\"%~dp0liberar-firewall.ps1\"'"

if errorlevel 1 (
  echo.
  echo Nao foi possivel elevar. Se voce recusou o aviso do Windows, rode de novo
  echo e clique em "Sim".
  echo.
  pause
)
