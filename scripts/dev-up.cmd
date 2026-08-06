@echo off
rem ===========================================================================
rem  Sobe a stack local (banco, API, ingestao, dashboard).
rem
rem  CLIQUE DUAS VEZES NESTE ARQUIVO.
rem
rem  Existe porque o Windows recusa .ps1 por padrao, com a mensagem "a execucao
rem  de scripts foi desabilitada neste sistema". O -ExecutionPolicy Bypass vale
rem  SO para este processo: nao altera configuracao nenhuma da maquina.
rem
rem  NAO precisa de administrador. Se algum dia precisar, o proprio script diz.
rem
rem  Para passar opcoes (-ComLogin, -SemSimulador...), use o PowerShell:
rem    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\dev-up.ps1 -ComLogin
rem ===========================================================================

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dev-up.ps1" %*

echo.
echo (janela mantida aberta para voce ler o resultado)
pause
