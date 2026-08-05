# Fase 3 — Agente Windows

Estado: **código completo e compilando.** Coleta validada contra Windows 11
pt-BR real. **O critério de aceite NÃO foi executado**, por um bloqueio de
política desta máquina — detalhado na seção 1, que é a parte mais importante
deste documento.

---

## 1. BLOQUEIO CRÍTICO: Smart App Control

### O que foi medido

```
Máquina            : PC-ANALISTA, Windows 11 Pro 10.0.26200, pt-BR
Smart App Control  : VerifiedAndReputablePolicyState = 1  (IMPOSIÇÃO)
WDAC / Device Guard: CodeIntegrityPolicyEnforcementStatus = 2  (imposição)
```

Ao tentar executar o agente compilado:

```
System.IO.FileLoadException: Could not load file or assembly 'MonitorAgent.dll'.
Uma política de Controle de Aplicativo bloqueou este arquivo. (0x800711C7)
```

Testado em dois caminhos diferentes (`Desktop` e `%LOCALAPPDATA%\Temp`) — **o
bloqueio não é por pasta**. O Smart App Control recusa binário sem assinatura
reputável em qualquer lugar do disco.

### Por que isso importa muito além do meu teste

**O MonitorAgent não vai executar em nenhuma máquina do parque que tenha Smart
App Control em imposição.** O sintoma será: o serviço instala, aparece como
`Stopped`, e falha ao iniciar com `0x800711C7`. Nenhum ajuste de permissão de
pasta, de conta de serviço ou de política de execução resolve.

Dois fatos que definem o tamanho do problema:

- SAC vem **ligado por padrão em instalação limpa de Windows 11**.
- SAC vem **desligado em máquinas que foram atualizadas do Windows 10**.

Então o problema pode ser grande ou pequeno, e **isso é mensurável antes de
qualquer decisão**:

```powershell
# Numa máquina
powershell -ExecutionPolicy Bypass -File .\agent\tools\verificar-app-control.ps1

# No parque, se você tem WinRM
Invoke-Command -ComputerName PDV01,PDV02,SRV01 `
  -FilePath .\agent\tools\verificar-app-control.ps1 |
  Export-Csv .\levantamento-sac.csv -NoTypeInformation
```

O script sai com código 0 se a máquina pode rodar o agente, 1 se não pode.

### As opções, com o custo real de cada uma

**1. Certificado de assinatura de código EV — a resposta certa para dezenas de lojas.**
Certificado EV (DigiCert, Sectigo, ~R$ 2.000–4.000/ano) ganha reputação
imediata no SAC e no SmartScreen. Resolve o parque inteiro, serve para qualquer
software interno futuro, e é a única opção que não deixa dívida. O custo anual é
menor que uma visita técnica a uma loja.

**2. Política WDAC da organização liberando o agente.**
Gratuito e distribuível por GPO/Intune. Esta máquina **já tem WDAC em
imposição** (status 2), o que sugere que existe política da organização — e
portanto que a TI já tem o mecanismo. Liberar por *assinatura* (mesmo
autoassinada) é sustentável; liberar por *hash* exige regerar a regra a cada
versão nova do agente, o que atrita com a auto-atualização da Fase 6.

**3. Desligar o SAC nas máquinas monitoradas.**
**Irreversível.** Voltar a ligar exige redefinir o Windows. Reduz a proteção da
máquina de forma permanente. Só com decisão formal de segurança, e mesmo assim
eu recomendaria contra num parque de PDV que processa pagamento.

**Minha recomendação:** meça primeiro. Se o SAC estiver desligado na maioria das
máquinas, siga com a opção 2 para as exceções. Se estiver ligado em boa parte,
compre o certificado EV — e assine também o instalador da Fase 6, que vai
enfrentar o SmartScreen pelo mesmo motivo.

### Consequência para o cronograma

A Fase 6 (empacotamento) muda: a assinatura de código deixa de ser um detalhe de
polimento e passa a ser **pré-requisito da implantação**. Minha estimativa
original de 2–4 dias para a Fase 6 supunha `dotnet publish` + script. Com
aquisição e configuração de certificado EV, some 1–2 dias de trabalho e o tempo
de emissão do certificado (a validação de uma EV leva de dias a duas semanas,
porque exige verificação jurídica da empresa).

**Comece o processo de aquisição do certificado agora, em paralelo**, se a
medição indicar que é o caminho. É o item com maior prazo externo do projeto.

---

## 2. O que foi validado, e como

### 2.1 Compilação

```
dotnet build  ->  0 avisos, 0 erros
```

Com `TreatWarningsAsErrors=true` e `Nullable=enable`. Um `null` não tratado num
coletor é exatamente o bug que a regra 19 proíbe, então ele é erro de
compilação, não algo a descobrir em produção.

### 2.2 Coleta CIM, contra o Windows real

Como não posso executar o agente, validei o que de fato varia entre máquinas: as
**consultas**. O script emite as mesmas WQL do código C# e confere se as
propriedades voltam com o tipo esperado.

```powershell
powershell -ExecutionPolicy Bypass -File .\agent\tools\validar-consultas-wql.ps1 `
  -CriticalServices Spooler,Dhcp
```

Resultado nesta máquina (pt-BR, sessão **não** elevada): **13 OK, 3 avisos, 0 erros.**

| Consulta | Resultado |
|---|---|
| `Win32_PerfFormattedData_PerfOS_Processor` CPU `_Total` | 15 (UInt64) |
| `Win32_PerfRawData_PerfOS_Processor` (fallback) | contador + `Timestamp_Sys100NS` |
| `Win32_PerfFormattedData_PerfOS_System` fila/proc/threads/uptime | 0 / 290 / 4301 / 118471 |
| `Win32_OperatingSystem` memória (KB) | 33342932 / 14081784 |
| `Win32_PageFileUsage.CurrentUsage` (MB) | 105 |
| `Win32_LogicalDisk` DriveType=3 | C:, NTFS, 255013679104 |
| `MSFT_PhysicalDisk` | PLEXTOR PX-256M7VC, MediaType=4 (SSD), HealthStatus=0 |
| `Win32_Service` 3 nomes, 1 inexistente | 2 instâncias, `State=Running`, `Started=True` (Boolean) |
| `Win32_Processor` | i5-11400, 6 núcleos |
| Fórmula do fallback de CPU | delta bruto → 3,96% (formatado: 1%) |
| Conversão de temperatura | 3032 dK → 30,05 °C |
| `MSAcpi_ThermalZoneTemperature` | **Acesso negado** (sem elevação) |
| `MSStorageDriver_FailurePredictStatus` | **Acesso negado** (sem elevação) |
| `MSFT_StorageReliabilityCounter` | recurso indisponível ao cliente |

Os 3 avisos são todos de privilégio e **esperados**: como serviço (LocalSystem)
essas classes respondem. Os flags `temp_denied` e `smart_denied` existem
justamente para não confundir "sem privilégio" com "sem sensor".

O caso do serviço inexistente confirmou o caminho que importa: a consulta com 3
nomes devolveu 2 instâncias, e é por isso que o `ServiceCollector` reporta o
ausente como **parado** em vez de omitir — um serviço crítico desinstalado é o
problema que mais interessa detectar.

### 2.3 Suíte de testes: escrita, NÃO executada

32 testes em `agent/tests/MonitorAgent.Tests`. Resultado real:

```
Com falha: 31, Aprovado: 1, Total: 32
Mensagem: System.IO.FileLoadException ... 0x800711C7
```

**As 31 falhas têm uma única causa: a política de sistema recusa carregar
`MonitorAgent.dll`.** O único teste que passou
(`Timestamp_do_agente_e_utc_com_sufixo_z`) é o único que não toca em nenhum tipo
do agente. Não há evidência de defeito nem de acerto nos outros 31 — eles não
rodaram.

Numa máquina sem SAC:

```powershell
cd agent
dotnet test
```

O que a suíte cobre:

| Área | Testes |
|---|---|
| Spool: ida e volta preservando o timestamp do agente | 1 |
| Spool: não remove até o ack (sobrevive a morte entre POST e ack) | 1 |
| Spool: drena do mais antigo para o mais novo | 1 |
| **Spool: 10 minutos offline preserva as 10 amostras com timestamps originais** | 1 |
| Spool: linha com JSON corrompido não trava a fila | 2 |
| Spool: trim por idade e por quantidade descarta o mais antigo | 2 |
| Spool: sobrevive a reabertura do arquivo | 1 |
| Spool: conta tentativas de envio | 1 |
| Config: recusa HTTP sem TLS, token truncado, faixas inválidas | 7 |
| Config: `ToSafeString` nunca revela token nem segredo | 1 |
| Config: o template é parseável pelo próprio loader | 1 |
| Backoff: exponencial, teto, sem estouro em 500 tentativas | 3 |
| Backoff: jitter dentro da faixa e efetivamente variando | 3 |
| Contrato JSON: nomes exatos que `register_metrics` espera | 1 |
| Contrato JSON: não envia percentuais derivados no servidor | 1 |
| Contrato JSON: UTC com sufixo Z, nulos omitidos | 2 |

### 2.4 Critério de aceite: script pronto, execução pendente

O critério é "desconectar a rede por 10 minutos e reconectar; **todas** as
amostras do período aparecem no banco com os timestamps corretos". Automatizado:

```powershell
$env:MONITOR_DB_URL = 'postgresql://...'
.\agent\tools\teste-aceite-offline.ps1 -Minutos 10 -MachineId '<guid>' -Adaptador 'Ethernet'
```

Ele registra o estado, derruba o adaptador, acompanha o spool crescer, reconecta,
espera a drenagem e então verifica quatro coisas: o spool drenou; a contagem na
janela bate com o esperado; **não há buraco maior que 2× o intervalo de coleta**;
e existe amostra com `ingested_at - time > 60s`, que é a prova de que o
timestamp do agente foi preservado e não sobrescrito pelo servidor (regra 12).

Sem `-Adaptador`, ele pede para você desconectar o cabo — necessário quando a
máquina é acessada por RDP, porque desabilitar a rede derrubaria a própria
sessão.

---

## 3. Decisões de projeto que merecem justificativa

**A ordem do ciclo é coleta → spool → envio, nunca coleta → envio → spool.**
Regra 16. Um agente que grava só no erro perde a amostra se o processo morrer
durante o POST — e o momento em que o processo morre é o momento interessante.

**`Dequeue` não remove; só o `Ack` remove.** É o que faz o reenvio funcionar
quando o processo morre entre o POST e a confirmação. O servidor é idempotente
(regra 13), então reenviar não duplica — e `duplicates > 0` na resposta é sinal
normal de recuperação, não erro.

**Cada coletor tem timeout próprio de 15s, além do try/catch.** O timeout é tão
importante quanto a captura: WMI travado **não lança exceção**, ele simplesmente
não volta. Sem isso, um PDV com controlador de disco travado perderia a amostra
inteira — CPU, memória e serviços junto — e apareceria offline por causa de um
disco.

**O trabalho síncrono vai para `Task.Run`.** A API CIM é bloqueante; sem isso o
`Wait(timeout)` só desistiria de esperar enquanto a thread continuaria presa. A
thread do pool fica ocupada até o WMI voltar, mas o ciclo segue e a amostra sai
no horário.

**5 falhas seguidas no mesmo coletor recriam a sessão CIM.** Sessão MI morta
devolve erro para sempre; só recriar resolve.

**`mem_pct` e `free_pct` não são enviados.** O servidor deriva de used/total. Uma
conta a menos para o agente errar, e uma fonte só para o mesmo número.

**`sent_at` é o relógio do agente no ENVIO, não na coleta.** É a única medida de
drift que não se confunde com reenvio de spool: `max(t)` de um lote antigo
também é antigo, mas `sent_at` é sempre "agora" na visão do agente.

**Serviço ausente é reportado como parado, não omitido.** Omitir faria o alerta
de serviço parado nunca disparar num PDV onde alguém desinstalou o software — que
é justamente o caso que interessa.

**`HttpClient` único com `PooledConnectionLifetime = 5min`, sem
`IHttpClientFactory`.** O agente fala com um endereço fixo pelo resto da vida do
processo, então a fábrica não agregaria nada. Mas o `PooledConnectionLifetime` é
essencial e é o que a fábrica resolveria: sem ele, um `HttpClient` de vida longa
**nunca reconsulta o DNS**, e uma troca de IP no Supabase deixaria o agente mudo
sem erro compreensível.

**Log de link caído é `Debug`, não `Error`.** Queda de link é o caso normal numa
loja. Um `Error` por minuto durante 6 horas de queda enche o log e esconde tudo o
mais. Marcos visíveis saem em `Warning` nas tentativas 5, 20 e 60.

**Credencial recusada gera UM `Critical`, não um por ciclo.** Repetir a cada
minuto durante dias afogaria o log; e o sintoma no servidor já é "máquina
offline", que a Fase 5 alerta.

**Nada de PerformanceCounter, em nenhum ponto** (regra 10). Só classes CIM, cujos
nomes vêm do MOF e são invariantes.

---

## 4. Bugs encontrados durante a construção

| Onde | Bug | Como apareceu |
|---|---|---|
| `NetworkCollector` | criei uma subclasse `SocketException_` achando que serviria de alias; **subclasse não captura a classe base** num filtro `when`, então `SocketException` real passaria batido e derrubaria o coletor | erro de compilação em uma das duas ocorrências revelou a ideia errada |
| `AgentConfig` | `TimeSpan FromSecondsSafe(...)` sem o ponto — erro de sintaxe | compilação |
| `Program.cs` | `AddHttpClient` exige o pacote `Microsoft.Extensions.Http`; troquei por `HttpClient` único, que é melhor aqui | compilação |
| Todos os `.ps1` | PowerShell 5.1 lê `.ps1` como **ANSI quando não há BOM**; o travessão `—` em UTF-8 decodifica como aspas inteligentes e quebra a string | `verificar-app-control.ps1` falhou com "cadeia sem terminador" |
| `validar-consultas-wql.ps1` | `powershell -File script.ps1 -Param A,B` entrega **uma string** `"A,B"`, não array — gerou `Name = 'Spooler,Dhcp'` | o próprio teste reprovou |

O caso do BOM vale registro: **todos os 9 scripts do projeto** agora têm BOM
UTF-8 e são verificados com o parser do PowerShell. O comando que faz isso está
no runbook da Fase 6.

---

## 5. Como usar

### Modos de diagnóstico

```powershell
$exe = "$env:ProgramFiles\MonitorAgent\MonitorAgent.exe"

& $exe --check          # valida config, coleta uma amostra, testa /healthz
& $exe --collect-once   # imprime o JSON exato que iria ao servidor
& $exe --spool-status   # quantas amostras pendentes, período, tentativas
& $exe --template       # gera um config.json modelo comentado
& $exe --help
```

`--collect-once` é a ferramenta principal para "esse PDV não reporta X": ele
mostra o que a máquina consegue coletar e os `flags` dizem o que falhou e por
quê.

**Rode em terminal ELEVADO.** Sem elevação, temperatura e SMART retornam acesso
negado e o diagnóstico natural ("essa máquina não tem sensor") é falso.

### Instalação como serviço

```powershell
# 1. Antes de tudo
powershell -ExecutionPolicy Bypass -File .\agent\tools\verificar-app-control.ps1

# 2. Provisionar no servidor e gerar o config
.\scripts\provision-machine.ps1 -SiteCode BSB-001 -Label 'PDV 01' `
  -IngestUrl 'https://SEUPROJETO.supabase.co/functions/v1/ingest' `
  -OutConfig C:\temp\config-pdv01.json

# 3. Instalar (terminal ELEVADO)
.\agent\tools\instalar-servico.ps1 -ConfigPath C:\temp\config-pdv01.json

# 4. Acompanhar
Get-Content "$env:ProgramData\MonitorAgent\logs\agent.log" -Tail 30 -Wait
```

O `-OutConfig` ainda não inclui o `sharedSecret` — acrescente-o à mão no
`config.json` ou passe `-SharedSecret` (o script de provisionamento será ajustado
na Fase 6, quando a implantação em massa entrar).

O instalador faz o que importa e é fácil esquecer: publica self-contained (a
máquina alvo não precisa de runtime .NET), restringe o ACL de
`%ProgramData%\MonitorAgent` a SYSTEM e Administradores (o `config.json` contém
o token em claro), registra a origem no Log de Eventos, configura início
**automático atrasado** (o PDV não disputa CPU com o software de venda durante o
boot) e reinício automático em falha (5s, 30s, 2min).

### Arquivos

```
%ProgramFiles%\MonitorAgent\            binários
%ProgramData%\MonitorAgent\config.json  configuração (contém o token)
%ProgramData%\MonitorAgent\spool.db     spool SQLite
%ProgramData%\MonitorAgent\logs\        agent.log + 7 rotações
Log de Eventos > Application > MonitorAgent   apenas Warning e acima
```

---

## 6. O que pode dar errado

**Smart App Control.** Seção 1. É o risco número um desta fase.

**Serviço instala e não inicia, sem mensagem clara.** Ordem de diagnóstico:
`--check` (config e conectividade), `agent.log`, Log de Eventos. Se aparecer
`0x800711C7`, é política de aplicativo.

**Temperatura sempre nula.** Duas causas distintas, e o flag diz qual:
`temp_denied` = falta elevação (em console) ou o serviço não é LocalSystem;
`temp_unavailable` = a máquina não tem zona térmica ACPI, que é o caso **comum**
em hardware de PDV. Depois de 10 tentativas sem sensor o coletor se desliga para
não gastar consulta a `root\wmi` a cada minuto.

**CPU sempre 0.** Cache de contadores de desempenho corrompido, comum após
upgrade in-place do Windows. O agente detecta (o bruto discorda do formatado),
cai para o fallback e emite `cpu_raw_fallback` com um `Warning` sugerindo
`lodctr /R`.

**Spool crescendo sem parar.** Sintoma de credencial recusada ou URL errada.
`--spool-status` mostra `tentativas` alto; o `last_error` no SQLite diz o motivo.
Ao bater o teto, o **mais antigo** é descartado (regra 17) — as amostras recentes
sobrevivem.

**Relógio dessincronizado.** O servidor mede o drift e o agente avisa acima de
60s. Passando da tolerância (`clock_skew_future_seconds`, 300s), o servidor
rejeita com `MON04` e o agente **preserva** o spool: corrija com `w32tm /resync`
e os dados são aceitos.

**Primeira amostra sem CPU do fallback.** O fallback depende de delta entre dois
snapshots; no primeiro ciclo não existe anterior. Se o formatado estiver
quebrado, a primeira amostra sai com `cpu_pct` nulo. Não vale complicar: a
segunda amostra já tem.

**`--collect-once` não escreve no spool.** É intencional — diagnóstico não
polui a série. Mas quem espera ver a contagem subir vai se confundir.

---

## 7. Próximo passo

Duas frentes independentes:

**Você:** medir o Smart App Control no parque e decidir o caminho da assinatura.
É o item de maior prazo externo do projeto.

**Eu:** Fase 4 (dashboard), que não depende de agente nem de assinatura — o seed
de métricas sintéticas já cobre o desenvolvimento, e o critério de aceite (o
hostname `<script>alert(1)</script>` renderizado como texto) é verificável no
navegador.

Se preferir, posso em vez disso executar a suíte de 32 testes e o teste de aceite
numa máquina sem SAC que você indique — mas isso depende de você ter uma.
