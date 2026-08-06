# Monitoramento Multi-Loja

Sistema de monitoramento 24/7 de máquinas Windows distribuídas em lojas atrás de
NAT, sem depender de VPN.

---

## Antes do primeiro comando: a política de execução

O Windows recusa `.ps1` por padrão, com esta mensagem:

> a execução de scripts foi desabilitada neste sistema

Não é defeito do projeto e **não** precisa ser "consertado" na máquina. Chame o
script pelo PowerShell dizendo a política **daquele processo**:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\dev-up.ps1
```

`Bypass` aqui vale só para esse processo e some quando a janela fecha — nenhuma
configuração da máquina é alterada. Evite `Set-ExecutionPolicy` global: baixar a
proteção do sistema inteiro para rodar um script é trocar um problema pequeno
por um permanente.

Para os dois comandos mais usados há atalho de clique duplo, que já faz isso:

| Arquivo | O que faz |
|---|---|
| `scripts\dev-up.cmd` | sobe a stack local |
| `scripts\liberar-firewall.cmd` | libera a porta da ingestão (pede elevação) |

---

## Rodar agora

Precisa de **Docker Desktop** e **Node 18+**. Nada mais.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\dev-up.ps1
```

Um comando: sobe Postgres + API + dashboard, aplica as migrations, semeia 3
lojas com 5 máquinas, envia 24 h de métricas pela ingestão real e abre o
navegador.

O dashboard **abre direto**, sem tela de login: a stack local escuta apenas em
loopback e o token vem do `dev-config.json`. Em produção o login é obrigatório.

```powershell
node scripts\verificar-e2e.mjs <email> <senha>   # ponta a ponta
node scripts\verificar-navegador.mjs <email> <senha>
node scripts\verificar-remocao.mjs               # remover loja e máquina
docker compose down                              # parar
docker compose down -v                           # apagar tudo, inclusive o volume
```

O `dev-up` já deixa o simulador rodando ao vivo, uma amostra por minuto. Ele toca
**apenas nas máquinas da demonstração** (GUID `bbbbbbbb-…`): máquina real nunca
recebe dado inventado por cima.

### Para outro PC enviar métricas

Falta liberar a porta no Firewall do Windows **deste** servidor, senão o agente
do outro PC nem baixa o instalador — e o erro que aparece lá
("Impossível conectar-se ao servidor remoto") não menciona firewall.

Clique duas vezes em `scripts\liberar-firewall.cmd`. Ele pede a elevação,
restringe a regra à sua sub-rede e confere se o endpoint responde.

### O que você vai ver

O seed embute cenários de propósito, para a tela não ficar toda verde:

| Loja / máquina | Cenário |
|---|---|
| BSB-001 / PDV 02 | mudo há 3 h → aparece **offline** |
| BSB-001 / PDV 01 | Spooler parado nas últimas 2 h |
| BSB-002 / PDV 01 | disco com ~7 % livre → dispara `disk_low` |
| SP-001 / gerência | sem sensor de temperatura (`temp_unavailable`) |

---

## Estado por fase

| Fase | Estado | Verificação |
|---|---|---|
| 1 — Fundação de dados | **pronta** | 13 migrations 2× do zero + 3 suítes SQL |
| 2 — Ingestão | **pronta** | 12 sub-testes SQL + 34 testes de lógica |
| 3 — Agente Windows | **código pronto, execução bloqueada** | compila com 0 avisos; 13 consultas WQL validadas em Windows pt-BR real |
| 4 — Dashboard | **pronto** | 36 verificações e2e, incluindo o critério de XSS |
| 5 — Alertas | tabela e regras prontas; avaliação pendente | — |
| 6 — Empacotamento | script de instalação pronto; **assinatura pendente** | — |
| 7 — Relatórios | rollup e expurgo prontos; relatórios pendentes | — |

### Bloqueio a resolver: Smart App Control

O agente **não executa** em máquina com Smart App Control em imposição — e ele
vem ligado por padrão em instalação limpa de Windows 11. Meça o parque antes de
decidir:

```powershell
Invoke-Command -ComputerName PDV01,PDV02,SRV01 `
  -FilePath .\agent\tools\verificar-app-control.ps1 |
  Export-Csv .\levantamento-sac.csv -NoTypeInformation
```

Detalhes e as três opções (certificado EV, política WDAC, desligar o SAC) na
seção 1 de [docs/FASE-3.md](docs/FASE-3.md). **O certificado EV tem o maior prazo
externo do projeto** — se for o caminho, comece já.

---

## Apontar para o Supabase

O modo local usa PostgREST, que é exatamente o que o Supabase expõe em
`/rest/v1`, e o JWT local carrega as mesmas claims do Supabase Auth. Então o RLS
exercitado localmente é o mesmo de produção.

**1. Banco**

```powershell
$env:MONITOR_DB_URL = 'postgresql://postgres.PROJETO:SENHA@aws-0-sa-east-1.pooler.supabase.com:5432/postgres'
.\scripts\apply-migrations.ps1 -Twice -Seed
.\scripts\run-tests.ps1
```

Habilite **pg_cron** em Database > Extensions e reaplique a migration `0011`.
Sem ele as partições futuras acabam em ~3 meses e **a ingestão para**.

**2. Ingestão**

```powershell
supabase secrets set INGEST_SHARED_SECRET='<32+ caracteres aleatorios>'
supabase functions deploy ingest --no-verify-jwt
.\scripts\test-ingest-http.ps1 -FunctionUrl 'https://PROJETO.supabase.co/functions/v1/ingest' -SharedSecret '<segredo>'
```

`--no-verify-jwt` é obrigatório (os agentes não têm JWT do Supabase); em troca a
função valida o segredo compartilhado em tempo constante.

**3. Dashboard**

Em `dashboard/config.js`, troque para o bloco `authMode: 'supabase'` e preencha
`restUrl`, `authUrl` e `anonKey`. Depois dê acesso de admin ao seu usuário:

```sql
insert into public.user_roles (user_id, role, note)
values ('<uuid de Authentication > Users>', 'admin', 'TI')
on conflict (user_id) do update set role = 'admin';
```

**4. Agentes**

```powershell
.\scripts\provision-machine.ps1 -SiteCode BSB-001 -Label 'PDV 01' `
  -IngestUrl 'https://PROJETO.supabase.co/functions/v1/ingest' `
  -OutConfig C:\temp\config-pdv01.json
# acrescente o sharedSecret ao config.json, depois, na máquina alvo (elevado):
.\agent\tools\instalar-servico.ps1 -ConfigPath C:\temp\config-pdv01.json
```

---

## Estrutura

```
supabase/migrations/   13 migrations idempotentes
supabase/seed/         seed de exemplo + métricas sintéticas (opcional)
supabase/tests/        4 suítes SQL, guardas permanentes das regras
supabase/functions/    Edge Function de ingestão + testes de lógica
dashboard/             HTML + JS puro, Chart.js autohospedado, zero innerHTML
agent/src/             Worker Service .NET 8, coleta CIM
agent/tests/           32 testes (não executáveis nesta máquina — ver Fase 3)
agent/tools/           validação de WQL, checagem de App Control, instalação
scripts/               subir stack, migrations, testes, provisionamento
docs/                  um documento por fase, com o que deu errado
```

---

## Antes de mexer

**Rode a suíte depois de qualquer alteração de schema.** Os testes SQL não são
checagens de uma vez — são guardas permanentes. `01_estrutura_e_regras.sql`
falha se uma view perder `security_invoker`, se uma função `SECURITY DEFINER`
esquecer o `search_path`, se `anon` ganhar privilégio em `public`, ou se uma
partição ficar legível fora do pai.

**Toda decisão não óbvia está comentada no código, e o que deu errado está nos
documentos de fase.** Se algo parecer estranho, provavelmente há um comentário
explicando por que a alternativa evidente não funciona.

**Scripts `.ps1` precisam de BOM UTF-8.** O PowerShell 5.1 lê `.ps1` como ANSI
sem BOM, e um acento vira caractere de aspas que quebra a análise sintática.
Verificação:

```powershell
Get-ChildItem -Recurse -Filter *.ps1 | ForEach-Object {
  $e = $null
  [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e) | Out-Null
  if ($e.Count) { "$($_.Name): $($e[0].Message)" }
}
```
