# Produção: publicar em HTTPS e monitorar lojas remotas

O teste na LAN aponta para `http://192.168.14.222:3010`. Esse endereço **não
existe** em outra loja, e é HTTP puro. Este documento é o caminho para o endereço
que funciona de qualquer rede.

---

## O que muda, e o que não muda

Só o **endereço** para onde o agente fala. Nada mais.

|  | Teste na LAN | Produção |
|---|---|---|
| Ingestão | `http://192.168.14.222:3010` | `https://<projeto>.supabase.co/functions/v1/ingest` |
| Quem serve | contêiner `monitor-ingest` | Edge Function |
| Banco | Postgres no Docker | Postgres do Supabase |
| Dashboard | abre direto, sem login | login obrigatório |
| Agente | idêntico | idêntico |
| Comando de instalação | idêntico, outro endereço | idêntico, outro endereço |

O agente é o mesmo arquivo, e o contrato de ingestão é o mesmo código: a Edge
Function e o endpoint local importam o **mesmo `lib.ts`**. O que você validou na
sua mesa é o que vai rodar na loja.

---

## Por que Edge Function, e não as alternativas

O servidor não tem IP público. Nenhuma máquina tem. Isso descarta "abrir uma
porta" antes de começar.

**Edge Function (o caminho escolhido).** HTTPS com certificado válido, sem custo.
Não existe conexão de entrada: o agente sai na 443, que toda loja já tem porque o
PDV depende disso. Nada a manter no ar do seu lado.

**Publicar o seu servidor.** Precisa de domínio, certificado e um túnel
(Cloudflare Tunnel é o realista) ou redirecionamento de porta. Funciona, mas a
disponibilidade passa a ser sua e há mais peças para quebrar. Só vale se houver
motivo para o dado não sair da sua infraestrutura.

**Pela VPN IPsec.** Tecnicamente a menor mudança: `10.x.0.100:3010`.
**Não faça isso como caminho principal.** A VPN é exatamente o tipo de coisa cuja
queda o monitoramento precisa *relatar*. Se a ingestão depende do túnel, o dia em
que o túnel cair é o dia em que toda a rede aparece offline e você não sabe se o
problema são as lojas ou a VPN. No máximo, caminho alternativo.

---

## Antes de rodar: o que buscar no painel do Supabase

Crie o projeto em [supabase.com/dashboard](https://supabase.com/dashboard) e
anote quatro coisas:

| O que | Onde | É segredo? |
|---|---|---|
| **project ref** | na URL: `/dashboard/project/SEU_REF` | não |
| **senha do banco** | Settings → Database | **sim** |
| **anon key** | Settings → API | não (é pública por desenho; o RLS protege) |
| **service_role key** | Settings → API | **sim, total** |

> A `service_role_key` dá acesso completo ao banco, ignorando RLS. Ela nunca entra
> em arquivo do repositório, nunca vai para o dashboard e nunca vai para o agente.
> Os scripts a pedem no terminal e não a gravam em lugar nenhum.

Autentique a CLI uma vez:

```powershell
supabase login
```

Se a CLI não estiver instalada: `winget install -e --id Supabase.CLI`. Sem ela, o
script cai para `npx -y supabase@latest` automaticamente.

---

## Publicar

```powershell
.\scripts\publicar-supabase.ps1 -ProjetoRef SEU_REF `
  -AnonKey 'eyJ...' -EmailAdmin 'kaualarsson@cajupar.com' -SenhaAdmin 'uma senha forte'
```

A senha do banco e a service_role key são pedidas no terminal, sem aparecer na
tela. Os três últimos parâmetros são opcionais: sem eles o dashboard continua
apontado para a stack local (e você ainda pode ver as lojas pelo terminal, veja
abaixo).

O script faz, na ordem:

1. confere pré-requisitos e se os scripts embutidos estão em dia
2. roda os testes de lógica da função — não publica código que já falha aqui
3. liga o repositório ao projeto e aplica as 17 migrations
4. define `INGEST_SHARED_SECRET` como variável de ambiente da função
5. publica a Edge Function
6. grava endereço e segredo em `ingest_config`
7. **verifica por HTTPS, de verdade**
8. grava `.env.producao` (fora do git) e `dashboard/config.producao.js`

### O passo 7 é o motivo de isto ser um script

Publicar é fácil. A pergunta que importa é *"está no ar e aceitando métrica?"*, e
essa só se responde tentando. As verificações:

- `healthz` responde, e **sem** o segredo não conta nada sobre o parque
- `healthz` **com** o segredo alcança o banco
- `instalar.ps1` e `agente.ps1` são servidos em HTTPS e têm conteúdo de PowerShell
- segredo errado → **401**
- segredo certo com token inválido → **401**
- **uma ingestão real ponta a ponta**: cria marca, loja e máquina de teste, emite
  token, envia uma amostra por HTTPS, confirma que foi aceita, e apaga tudo

A última é a única que prova o caminho inteiro. Sem ela, todas as outras podem
passar com a ingestão quebrada no último metro.

Se alguma falhar, o script sai com erro e diz para não instalar em loja nenhuma —
um agente instalado contra um endpoint quebrado fica coletando e falhando em
silêncio.

### Conferir depois, sem republicar

```powershell
.\scripts\publicar-supabase.ps1 -ProjetoRef SEU_REF -SoVerificar
```

---

## Instalar numa loja

### 1. Gere o comando

Pelo terminal, sem depender do dashboard:

```powershell
.\scripts\comando-para-loja.ps1 -Loja BSB-003 -CriarLoja -NomeLoja "Cajupar Sudoeste" `
  -Rotulo "PDV 01" -Servicos 'Spooler,Dhcp' -ComTarefa
```

O comando sai pronto e já vai para a área de transferência.

Ou pelo dashboard, se você o apontou para produção: **+ Adicionar PC**. Os dois
caminhos produzem o mesmo comando, porque os dois leem o endereço e o segredo do
mesmo lugar — `ingest_config`, no banco.

### 2. Rode na máquina da loja

PowerShell **como administrador** (necessário para o `-ComTarefa`) e cole.

`-ComTarefa` não é detalhe: sem ele o agente morre quando a sessão termina e não
volta depois de reiniciar o Windows. Com ele, roda como tarefa agendada sob
SYSTEM — e aí **temperatura e SMART** também passam a ser coletados, porque
exigem privilégio.

### 3. Veja chegar

```powershell
.\scripts\ver-producao.ps1 -Loja BSB-003 -Vigiar
```

Reconsulta a cada 15 s. Use enquanto instala.

---

## O token e o segredo

**Token da máquina.** Um por máquina. O banco guarda apenas o hash SHA-256 —
não existe como lê-lo de novo. Se perder, gere outro (o antigo pode ser revogado
depois). São revogáveis individualmente.

**Segredo compartilhado.** Um só, para toda a frota. Ele existe porque a função
roda com `verify_jwt = false` — os agentes não têm JWT do Supabase, têm o token
próprio deles. Em troca, a função valida esse segredo **em tempo constante, antes
de tocar no banco**.

Ele mora em dois lugares e em nenhum outro:

- variável de ambiente da Edge Function (lado servidor)
- `public.ingest_config`, tabela **sem policy e sem grant** — só função
  `SECURITY DEFINER` a lê, e o segredo só sai para admin

Ele **não** está em `config.js`, nem em `dev-config.json`, nem em qualquer arquivo
que o navegador baixe. Isso é deliberado e há um teste que reprova se voltar a
estar: o dashboard é um site estático, e ali "arquivo de configuração" significa
"público".

Guarde-o num gerenciador de senhas. Ele está em `.env.producao`, que não vai para
o git.

---

## Dashboard em produção

```powershell
Copy-Item dashboard\config.producao.js dashboard\config.js -Force
```

Para voltar à stack local: `git checkout dashboard/config.js`.

Em produção existe login (`login.html`) e ele é obrigatório. O atalho sem login da
stack local só é aceitável porque ela escuta apenas em loopback.

O `publicar-supabase.ps1` já criou o usuário, concedeu `admin` em
`public.user_roles` e **conferiu que o login funciona** — inclusive que, pela
visão do RLS, o usuário é admin e recebe o endereço da ingestão.

Para hospedar o dashboard (Vercel/Netlify), publique a pasta `dashboard/` como
site estático. Não há build. Confirme que `config.js` é o de produção antes de
subir.

---

## Quando uma loja não aparece

O instalador testa a conexão **antes** de instalar qualquer coisa, e o erro dele
já distingue os dois casos. Em HTTPS ele manda verificar, nesta ordem:

1. a máquina tem internet — `Test-NetConnection 1.1.1.1 -Port 443`
2. o nome resolve — `Resolve-DnsName <projeto>.supabase.co`
3. a rede da loja não bloqueia a saída na 443 nem exige proxy
4. o TLS fecha — `Invoke-RestMethod 'https://.../ingest/healthz'`
5. a função está publicada e com os segredos definidos

O item 4 merece atenção: o PowerShell 5.1 herda o `SecurityProtocol` padrão do
.NET Framework, que em Windows sem atualização ainda negocia SSL3/TLS 1.0 — e o
Supabase recusa. O agente e o instalador **forçam TLS 1.2/1.3** por isso. Sem
esse cuidado o erro que aparece é "a conexão subjacente foi fechada", que joga o
diagnóstico para firewall e certificado quando o problema é a versão do protocolo.

Se o agente instalou mas nada chega, o log está em
`%ProgramData%\MonitorAgent\agente-ps.log`.

---

## O que continua pendente

Honestidade sobre o que este caminho **não** resolve:

- **Agente .NET bloqueado pelo Smart App Control.** O agente em produção é o
  PowerShell (`ps-1.1.0`), que não passa por essa política. O .NET compila sem
  aviso e não executa em máquina com SAC ligado; resolver exige certificado de
  assinatura de código EV — o item de maior prazo externo do projeto.
- **Fase 5** (avaliação de alertas, Telegram, e-mail) tem a fundação no banco, mas
  não há job avaliando regra nem enviando notificação. Hoje o dashboard mostra; ele
  não avisa.
- **Fase 7** (rollup horário, relatório mensal, retenção) tem as tabelas e o
  `pg_cron`, mas os jobs de relatório não existem.
- **Retenção e partições** dependem do `pg_cron`, que precisa estar habilitado no
  projeto (Database → Extensions). A migration 0011 é tolerante: se a extensão não
  existir, ela avisa e segue, e as partições passam a depender de criação manual.
