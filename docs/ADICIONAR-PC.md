# Como conectar outros PCs ao monitoramento

## O modelo, em uma frase

**O agente liga para o servidor. O servidor nunca liga para o agente.**

É por isso que nenhuma máquina de loja precisa de IP público, de porta liberada
ou de redirecionamento no roteador. Ela só precisa conseguir sair para a rede —
o que toda loja já tem, porque o PDV depende disso.

```
PC da loja                                    servidor
+-------------------+                    +------------------+
| agente.ps1        |                    | /ingest          |
| coleta a cada 60s |  --- POST -------> | valida o token   |
| grava no spool    |    (só de saída)   | grava no banco   |
| envia o lote      |                    +------------------+
+-------------------+                             |
                                            dashboard lê
```

Se o link cair, o agente **não perde dado**: continua coletando para um arquivo
local (até 20.000 pontos ou 72 h) e despeja tudo quando a conexão volta. O
gráfico fica sem buraco.

---

## Passo a passo (o que você faz)

1. No dashboard, clique em **+ Adicionar PC**.
2. Preencha nome, loja, perfil e os serviços a vigiar. Confirme.
3. Copie o comando que aparece.
4. No outro PC, abra o **PowerShell** (não o cmd) e cole.

O comando é uma linha. Ele faz, nesta ordem:

1. testa se alcança o servidor **antes** de instalar qualquer coisa;
2. baixa o `agente.ps1` para `%ProgramData%\MonitorAgent\`;
3. grava o `config.json` com o token daquela máquina;
4. faz uma coleta de teste e mostra o resultado;
5. sobe o agente em segundo plano.

Em menos de um minuto a máquina aparece no dashboard.

### O agente volta depois de reiniciar o Windows?

Do jeito padrão, **não** — ele vive só até a sessão terminar. Para ele voltar
sozinho, rode o mesmo comando com `-ComTarefa` no fim, num PowerShell **como
administrador**. Isso registra uma tarefa agendada que roda como SYSTEM, e de
quebra libera duas coletas que exigem privilégio: **temperatura** e **SMART**.

Em produção, use sempre `-ComTarefa`.

### O token

Cada máquina tem o seu, e o banco guarda apenas o hash SHA-256 — nem eu nem
você conseguem ler o token de volta depois. Por isso o comando **não é mostrado
outra vez**. Se perder, cadastre a máquina de novo e revogue o token antigo.

---

## Testando na sua rede, agora

É o teste certo para fazer primeiro: ele exercita o caminho inteiro (cadastro,
token, download, coleta, ingestão, dashboard), faltando só a distância.

### 1. Libere a porta no SERVIDOR

Este é o único ajuste que falta, e é no PC servidor, não no cliente. Num
PowerShell **elevado**, aqui:

```powershell
New-NetFirewallRule -DisplayName 'Monitoramento (ingestao)' `
  -Direction Inbound -Protocol TCP -LocalPort 3010 -Action Allow `
  -RemoteAddress 192.168.14.0/24
```

O `-RemoteAddress` restringe à sua LAN: a porta não fica aberta para tudo, só
para quem está na mesma rede.

### 2. Cadastre e cole

Siga o passo a passo acima no segundo PC. Se o instalador não alcançar o
servidor, ele para e diz exatamente o que checar — ele não instala pela metade.

### 3. Prove a resiliência (o teste que realmente importa)

Isto é o que vai acontecer todo dia nas lojas de verdade, então vale ver
funcionando antes:

1. Desconecte a rede do segundo PC (ou pare a stack no servidor).
2. Espere passar o `offline_timeout_seconds`. O cartão fica **OFFLINE**.
3. Religue.
4. O agente despeja o spool e o gráfico preenche o período todo, **sem buraco**.

Se isso funciona na sua mesa, funciona a 900 km.

---

## Levando para as outras lojas

Aqui o teste local para de valer, e é honesto dizer por quê: hoje o comando
aponta para `http://192.168.14.222:3010`. Esse endereço **não existe** em outra
loja, e é HTTP puro — o que contraria a regra de "tudo em HTTPS, sem exceção
para rede interna".

Para loja remota o endpoint de ingestão precisa ser alcançável pela internet, em
HTTPS. Três caminhos, na ordem em que eu recomendo:

### A. Edge Function no Supabase — é para onde este projeto foi desenhado

O agente passa a postar em `https://<projeto>.supabase.co/functions/v1/ingest`.

- HTTPS com certificado válido, de graça;
- nenhum problema de NAT: não existe entrada, só saída;
- a loja não precisa de nada além de sair na 443;
- o código já existe e **compartilha o mesmo `lib.ts`** do endpoint local, então
  o contrato de ingestão é idêntico ao que você já testou.

O que muda no PC da loja: uma linha no `config.json` (`ingestUrl`). Nada mais.

**Custo real:** você passa a depender do Supabase e precisa cadastrar os
segredos lá (`service_role_key` e o segredo compartilhado ficam **só** como
variável de ambiente do lado servidor — nunca no agente).

### B. Publicar o seu servidor em HTTPS

Precisa de domínio, certificado TLS e um jeito de entrar da internet — que o
servidor não tem, porque não tem IP público. Na prática significa um túnel
(Cloudflare Tunnel é o realista) ou redirecionamento de porta no site do
servidor.

Funciona, mas o número de peças para manter no ar sobe, e a disponibilidade
passa a ser sua. Só vale se houver motivo para o dado não sair da sua infra.

### C. Por cima da VPN IPsec

Tecnicamente é a menor mudança: o agente aponta para `10.x.0.100:3010`.

**Eu não faria isso como caminho principal.** A VPN é exatamente o tipo de coisa
cuja queda você quer que o monitoramento **relate** — e não que o cegue. Se a
ingestão depende do túnel, o dia em que o túnel cair é o dia em que a loja
inteira aparece offline sem você saber se o problema é a loja ou a VPN. Use no
máximo como caminho alternativo.

---

## Resumo da recomendação

| Fase | Endpoint | Quando |
|---|---|---|
| Teste na sua rede | `http://192.168.14.222:3010` | agora, com o segundo PC |
| Produção | Edge Function em `https://…supabase.co` | antes da primeira loja remota |
| Alternativa | VPN `10.x.0.100` | só como reserva |

Depois de trocar para o Supabase, **teste com uma máquina** antes de sair
instalando na frota. O comando do dashboard passa a sair com a URL nova
automaticamente.
