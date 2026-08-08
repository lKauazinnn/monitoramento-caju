# Sentinela — monitoramento multi-loja

Monitoramento 24/7 de máquinas Windows espalhadas por lojas atrás de NAT, **sem
depender de VPN**. Um agente em cada PC coleta e envia; um painel mostra o que
está quebrado agora e o que aconteceu no mês.

Este documento descreve o sistema inteiro: o que existe, por que foi feito assim,
e o que ainda não existe.

---

## Onde tudo roda

| Peça | Onde | Depende do seu PC? |
|---|---|---|
| **Painel** | Vercel — <https://monitoramento-cajupar.vercel.app> | não |
| **Ingestão** | Edge Function no Supabase | não |
| **Banco** | PostgreSQL 16 do Supabase (`zrdglshzhlflnakflnki`, us-east-2) | não |
| **Agente** | cada PC de loja, PowerShell 5.1 | não |
| **Stack local** | Docker nesta máquina, para desenvolver | — |

Desligar o PC do TI não derruba nada de produção.

### A decisão que molda a arquitetura

**Nenhuma máquina tem IP público.** Por isso o agente só faz conexão **de
saída**, na 443, para um endpoint HTTPS. A loja não precisa de porta liberada, de
redirecionamento no roteador nem de VPN — precisa do mesmo acesso à internet que
o PDV já usa.

A VPN IPsec existe no grupo, mas o monitoramento **não passa por ela**, de
propósito: a VPN é o tipo de coisa cuja queda o monitoramento precisa *relatar*.
Se a ingestão dependesse do túnel, o dia em que ele caísse seria o dia em que
toda a rede apareceria offline sem ninguém saber se o problema é a loja ou a VPN.

```
   PC da loja                          Supabase                      Vercel
┌────────────────┐                ┌──────────────────┐         ┌──────────────┐
│ agente.ps1     │                │ Edge Function    │         │  painel      │
│ coleta a cada  │ ── POST 443 ─► │ /functions/v1/   │         │  (estático)  │
│ 60s (CIM)      │   só de saída  │ ingest           │         └──────┬───────┘
│ spool em disco │                │   ↓ ingest_batch │                │
└────────────────┘                │ PostgreSQL       │ ◄──────────────┘
                                  │ + pg_cron        │   RPC autenticado (RLS)
                                  └──────────────────┘
```

---

## O que o painel mostra

### Faixa de incidente
Vermelha, no topo, pulsando. Acende **só** para alerta crítico **não
reconhecido** — se acendesse para qualquer coisa viraria papel de parede e
deixaria de funcionar no dia em que importa.

**Reconhecer não fecha o alerta**: ele continua aberto no histórico até a
condição se desfazer. Só cala a faixa. Sem esse escape, um problema que leva dois
dias para resolver deixaria a tela vermelha por dois dias.

O favicon muda de cor junto (verde / laranja / vermelho) — quem deixa o painel
numa aba de fundo não vê faixa nenhuma, e aquele é o único pixel que sobra. Há
som opcional, **desligado por padrão**, que toca uma vez por incidente novo,
nunca em laço e nunca na primeira carga.

### Barra lateral
- **Vistas**: Visão geral, Offline, Degradados, Nunca vistas — cada uma é um
  filtro real com a contagem do que vai mostrar.
- **Marcas**: aparece quando há mais de uma.
- **Relatório mensal**.
- **Pulso da ingestão**: amostras/min, com sparkline. Responde "os dados estão
  chegando?" sem depender de nenhuma máquina específica estar reportando. A bolha
  só fica verde quando dado está mesmo chegando.
- **Latência ao gateway**: média das máquinas online.
- Tema claro/escuro e som.

### Faixa de KPIs
Hosts online, degradados, offline, serviços parados, disco crítico, ingestão.
**Zero apaga a tira** — um "0 degradados" aceso de laranja ensina a equipe a
ignorar laranja.

As tiras contam sempre a **frota inteira**, mesmo com filtro ativo (filtrar por
"offline" e ver o contador de offline zerar seria absurdo). Quando há filtro, a
tela avisa isso em laranja.

### Carga da frota
CPU e memória médias, com faixas de 1h / 24h / 7d / 30d. Vem de dado agregado, e
com série curta desenha o ponto — uma linha precisa de dois pontos para existir, e
uma frota nova não pode parecer quebrada.

### Fila de atenção
Derivada do estado **atual**, imediata. Diferente da faixa de incidente, que
mostra o alerta **formal** (o que passou pela histerese). É a diferença entre "um
pico agora" e "isto está acontecendo há dez minutos".

### Frota
Dois modos, e a escolha fica salva no navegador:

- **Lojas** (padrão): um cartão por loja com **heatmap de hosts** — um quadrado
  por máquina, colorido pelo estado, clicável. É o que faz a tela caber em
  dezenas de lojas sem virar rolagem infinita. As lojas são ordenadas por
  **gravidade**, não por código.
- **Máquinas**: marca → loja → cartão por PC, com CPU, memória, disco e
  temperatura.

Loja **sem nenhuma máquina** também aparece: sumir não é o mesmo que não existir,
e loja invisível não teria como ser removida.

### Painel de detalhe
Abre ao clicar em qualquer máquina ou quadrado. Traz identificação completa
(hostname, IP, sistema, CPU, núcleos, memória, versão do agente, uptime, desvio
de relógio, latência, sinalizadores, GUID), três gráficos, eventos recentes e a
zona de remoção.

### Relatório mensal
Disponibilidade, CPU média e p95, disco mínimo, reinícios, alertas e horas em
alerta — por máquina, com seletor de mês e **exportação em planilha**.

> **Disponibilidade** = amostras recebidas ÷ amostras esperadas no mês. É quanto
> do tempo a máquina esteve **reportando** — não é uptime do Windows. Uma máquina
> ligada mas sem rede conta como indisponível, porque para o monitoramento ela
> estava muda.

CSV com `;` e vírgula decimal, com BOM: é o que faz o Excel em português abrir com
as colunas separadas. **Não é PDF** de propósito — o relatório existe para ser
filtrado, ordenado e colado num e-mail; PDF é bonito e é um beco sem saída.

---

## O agente

`agent/agente-powershell.ps1` (`ps-1.1.0`). Coleta por **CIM**, nunca por
`PerformanceCounter` com nome de categoria — nome de categoria é traduzido no
Windows pt-BR e quebraria em toda máquina da rede.

Coleta: CPU, memória, uptime, discos por volume, serviços críticos, temperatura,
latência até o gateway, contagem de processos e threads.

### O spool é o que faz isso funcionar em loja
Grava em disco **antes** de tentar enviar (`%ProgramData%\MonitorAgent\`), até
20.000 pontos ou 72 h. Link caiu, a coleta continua; link voltou, ele despeja
tudo e o gráfico fica **sem buraco**. O arquivo sobrevive a reinício.

Máquina **desligada** é outro caso: não havia o que coletar, então o buraco é real
e permanece. Inventar continuidade ali esconderia o incidente.

### Instalação: uma linha
```powershell
& ([scriptblock]::Create((irm 'https://…/ingest/instalar.ps1'))) `
  -Servidor 'https://…/ingest' -Token 'mon_…' -Segredo '…' -ComTarefa
```
Testa a conexão **antes** de instalar, baixa o agente, grava a configuração, faz
uma coleta de teste e sobe. Falhando, para e diz o que verificar — e a lista é
diferente para HTTPS e para rede local, porque as causas são opostas.

**`-ComTarefa` não é opcional em produção.** Sem ele o agente morre com a sessão e
não volta depois de reiniciar o Windows. Com ele, roda como tarefa agendada sob
SYSTEM (`-AtStartup`, `RestartCount 999`) — e aí **temperatura e SMART** também
passam a ser coletados, porque exigem privilégio.

### Duas armadilhas do Windows que estão resolvidas
- **TLS**: o PowerShell 5.1 herda o padrão do .NET Framework, que em Windows sem
  atualização negocia SSL3/TLS 1.0 — e o Supabase recusa. O agente força TLS
  1.2/1.3. Sem isso o erro é "a conexão subjacente foi fechada", que joga o
  diagnóstico para firewall e certificado.
- **BOM**: o `.ps1` em disco precisa de BOM (sem ele o PowerShell lê como ANSI e
  um acento quebra a sintaxe), mas o conteúdo servido por HTTP **não pode** tê-lo:
  vira o primeiro caractere do texto e `param()` deixa de ser a primeira
  instrução. Os dois casos estão tratados, em lugares diferentes.

---

## Alertas

Oito regras, avaliadas a cada 5 minutos pelo `pg_cron`:

| Tipo | Padrão | Severidade |
|---|---|---|
| `offline` | sem contato além da tolerância (180 s) | crítica |
| `disk_low` | < 10% livre | crítica |
| `service_down` | serviço crítico parado | crítica |
| `smart_failing` | SMART prevendo falha | crítica |
| `cpu_sustained` | > 90% | aviso |
| `mem_high` | > 92% | aviso |
| `temp_high` | > 85 °C | aviso |
| `clock_drift` | > 120 s | aviso |

Escopo por **global / marca / loja / perfil / máquina**, e **a regra mais
específica vence** — sem isso, uma regra global de disco a 10% e uma de loja a 5%
abririam dois alertas para o mesmo disco.

**Histerese simétrica**: abre só depois de N amostras violando, e resolve só
depois de N limpas. Abrir devagar e fechar rápido produz o alerta que pisca, e
alerta que pisca é ignorado — o que é pior que alerta ausente, porque dá sensação
de cobertura. Disco e relógio não usam histerese: não oscilam como CPU.

**Cooldown** conta do fechamento. Máquina em **manutenção declarada** não gera
alerta. A recuperação gera **evento próprio** — o "voltou" precisa passar pela
mesma fila do "caiu".

O aviso é **na tela**, não por mensagem. Foi uma escolha: é um painel que alguém
observa.

---

## Retenção e histórico

| Dado | Guardado | Onde |
|---|---|---|
| Métrica crua | 30 dias | partições mensais de `metrics` |
| Rollup horário | 400 dias | `metrics_hourly` |
| Eventos | 3 anos | `events` |

O rollup roda **de hora em hora** (minuto 7) e a manutenção **de madrugada**
(3:17). A ordem importa e está garantida: `run_maintenance` **agrega antes de
apagar**.

E há uma trava: `drop_old_partitions` **recusa** derrubar partição de mês que não
foi consolidado. Se o rollup quebrar por uma semana, o resultado é disco cheio —
não histórico perdido. Disco cheio a gente resolve.

O gráfico usa cru em 24 h (a granularidade de 10 min é o valor) e rollup em 7 d e
30 d, com médias ponderadas por número de amostras — sem o peso, uma hora com três
amostras influiria tanto quanto uma hora cheia.

---

## Segurança

- **`service_role_key` nunca** aparece no agente, no painel ou no repositório. Só
  como variável de ambiente do lado servidor.
- **Um token por máquina**, e o banco guarda apenas o **hash SHA-256**. Não há
  como lê-lo de volta; por isso o comando é mostrado uma única vez. Revogáveis
  individualmente.
- **Segredo compartilhado** da ingestão vive em `ingest_config` — tabela **sem
  policy e sem grant**, alcançável só por função `SECURITY DEFINER`, e entregue
  apenas a admin. Não está em nenhum arquivo que o navegador baixe, e há teste
  que reprova se voltar a estar.
- **RLS deny-by-default**, com escopo por loja. Toda `SECURITY DEFINER` leva
  `SET search_path`, toda view leva `security_invoker = true`.
- **Nenhum `innerHTML`** com dado do banco: só `textContent` e `createElement`. O
  critério de aceite injeta `<script>alert(1)</script>` num hostname e exige que
  apareça como texto literal.
- **CSP estrita** no painel publicado: `default-src 'none'`, sem `unsafe-inline`
  em lugar nenhum — possível porque não há recurso externo (fontes do sistema,
  Chart.js self-hosted).
- Login obrigatório em produção. O atalho sem login existe **só** na stack local,
  que escuta apenas em loopback.

---

## Operação do dia a dia

```powershell
# Subir o ambiente local (ou clique duplo em scripts\dev-up.cmd)
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\dev-up.ps1

# Liberar a porta para outro PC da MESMA rede alcançar (clique duplo, elevado)
scripts\liberar-firewall.cmd

# Publicar/atualizar a produção
.\scripts\publicar-supabase.ps1 -ProjetoRef SEU_REF -TokenAcesso sbp_… -AnonKey eyJ…
.\scripts\publicar-dashboard.ps1

# Cadastrar uma máquina de loja
.\scripts\comando-para-loja.ps1 -Loja BSB-003 -CriarLoja -NomeLoja "…" -Rotulo "PDV 01" -ComTarefa

# Acompanhar
.\scripts\ver-producao.ps1 -Vigiar
.\scripts\trocar-senha-producao.ps1 -Email …
```

> O Windows recusa `.ps1` por padrão. Use `-ExecutionPolicy Bypass` na chamada —
> vale só para aquele processo. **Não** use `Set-ExecutionPolicy` global: baixar a
> proteção do sistema inteiro para rodar um script troca um problema pequeno por
> um permanente.

---

## Verificação

Nenhuma dessas suítes lê código — todas exercitam o sistema de verdade.

| Suíte | Cobre |
|---|---|
| `verificar-navegador.mjs` (72) | painel inteiro num Chrome real, XSS, cadastro, relatório |
| `verificar-e2e.mjs` (35) | API, RLS, ingestão, histórico, critério de aceite de XSS |
| `verificar-remocao.mjs` (14) | remover loja e máquina, e que **um** clique não remove |
| `verificar-faixa-incidente.mjs` (12) | incidente real: acende, reconhece, cala, some |
| `verificar-frota-nova.mjs` (11) | o primeiro dia de uso, que ninguém testa |
| `verificar-edge-function.mjs` (15) | a função sob Deno, antes de publicar |
| `verificar-caminho-da-loja.mjs` (17) | o percurso que o PC da loja faz |
| `verificar-csp.mjs` (8) | a CSP não quebra a página |
| `verificar-dashboard-publicado.mjs` (10) | o site no ar, com login |
| `lib.test.mjs` (41) | lógica pura da Edge Function |
| SQL `01`–`07` | estrutura, RLS, tokens, ingestão, config, alertas, rollup |

**Princípio**: teste que não falha com o defeito presente é pior que teste
nenhum. Vários destes foram escritos, aprovados, e então **desfeita a correção de
propósito** para confirmar que reprovavam.

---

## O que NÃO existe

Sendo explícito, porque saber o limite é parte de confiar na ferramenta.

- **Agente .NET não roda.** Compila sem aviso, mas o **Smart App Control** bloqueia
  binário sem assinatura reputável, em qualquer pasta. Resolver exige certificado
  de assinatura de código EV — o item de maior prazo externo do projeto. Produção
  usa o agente PowerShell, que não passa por essa política.
- **Notificação externa** (Telegram, e-mail, WhatsApp). A fundação existe
  (`channels` nas regras, `notified_at` nos eventos); o envio não foi
  implementado, por escolha: o aviso é na tela.
- **Fase 6 (empacotamento)**: sem MSI, sem assinatura, sem atualização automática
  do agente. Atualizar hoje é rodar o mesmo comando de instalação de novo.
- **SLO e latência de ingestão ponta a ponta**: não são medidos, e por isso não
  aparecem em lugar nenhum. Número inventado em painel de monitoramento é pior que
  campo ausente — a equipe passa a decidir em cima dele.
- **Reconhecimento em massa** de alertas: é um por vez, de propósito.

---

## Pendências do operador

1. **Revogar** o token pessoal (`sbp_…`) em Account → Tokens.
2. **Rotacionar** a `service_role key` e o JWT secret — passaram por canal
   auditado. Rotacionar **não** derruba agente instalado: a máquina da loja só
   carrega o token dela e o segredo compartilhado.
3. **`PC-Brayan`** ainda reporta para o endpoint da LAN, não para produção.
   Reinstalar com o comando novo.
4. Repositório GitHub está **público** — considerar torná-lo privado.
