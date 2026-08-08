# O que falta para o app bater com o handoff

Conferido item a item contra `design_handoff_sentinela_noc/README.md`.
Marcado com **[servidor]** o que depende de dado que ainda não é coletado.

## Tela 1 — Visão geral

- [ ] **Gráfico "Carga da frota"** (variação A) — área SVG de 190px, CPU azul e
      memória violeta, 3 linhas de grade, faixa de pico destacada, eixo X com 7
      marcas (00h…agora) e `Segmentado` de janela 1h/24h/7d/30d.
      Dado existe: `metrics_hourly` e `metrics`.
- [ ] **Fila de alertas** no formato do handoff — ícone 26px em quadrado
      tingido a 14%, dois chips mono (host e nome da regra). Hoje usa `ItemFila`
      simples, sem os chips.
- [x] Faixa de 6 KPIs com sparkline
- [x] Variação B (tabela densa) + distribuição por estado + saturação por perfil
- [x] Variação C (heatmap) com hover 1.28 e legenda

## Tela 2 — Frota

- [x] Facetas com contagem, separador, resumo e "Limpar"
- [x] Cabeçalhos ordenáveis com `↓` na coluna ativa
- [x] Paginação 60 + "Carregar mais 50"

## Tela 3 — War-room

- [ ] **Barra de progresso indeterminada** (`sweep`, 2.6s) no topo da faixa
- [ ] **Cronômetro "Aberto há N min"** em mono 19px
- [ ] **Linha do tempo** no grid `52px 14px 1fr` com chip de fonte
      (coletor / regra / correlação / notificação / ação humana) **[servidor]**
- [ ] **Runbook de 5 passos** com contador feitos/total, ✓ por passo,
      esverdeamento e gravação na auditoria **[servidor]**
- [ ] **Impacto no negócio** — receita em risco, cupons no spool, budget de
      erro **[servidor]**
- [ ] **Sala de guerra** — participantes, papéis, notificar **[servidor]**
- [x] Faixa do incidente com Reconhecer
- [x] Máquinas sem contato (o impacto que dá para medir hoje)

## Tela 4 — Inventário

- [x] Agregações de SO, agente, memória e processador (dado real)
- [ ] **Tabela de software monitorado** com cobertura **[servidor]**
- [ ] **Fim de vida & garantia** **[servidor]**
- [ ] **Deriva de configuração** vs. baseline da marca **[servidor]**

## Tela 5 — Regras & ruído

- [x] Lista de regras com escopo, histerese, silêncio e toggle
- [ ] **Rota de escalada** em 4 degraus (0/5/15/30 min) — hoje é um parágrafo
- [ ] **Ruído por regra** em barra empilhada verde/vermelha, ordenada pelo pior
- [ ] Ligar/desligar regra de verdade (falta a chamada no servidor) **[servidor]**

## Tela 6 — Auditoria

- [x] Facetas, tabela, exportar CSV
- [ ] **Coluna Autor** com avatar de iniciais — `events.payload.actor` existe
- [ ] **Coluna Origem** (IP / coletor / api-gw / cron)
- [ ] **Coluna Hash** encadeado **[servidor]**

## Tela 7 — Plantão

- [x] Moldura de telefone, KPIs, "Precisa de você agora", lojas em risco
- [x] Botões de 44px

## Gaveta do host

- [x] Chips, 6 medidores, ficha, serviços, comandos, eventos
- [ ] **3 séries de 24h** em SVG de 52px com pico e média
- [ ] **Rodapé fixo com 4 ações**: Reconhecer, Silenciar 2h, Diagnóstico,
      Revogar token (destrutiva, com `armado`)

## Interações

- [x] ⌘K com comandos e hosts, Enter no primeiro, Esc, rodapé com contagem
- [x] Toasts 4200ms no canto inferior direito
- [x] Tema em `data-tema`
- [x] Telemetria com cadência configurável e pausável
- [ ] **`sweep`** — animação da barra indeterminada
- [ ] Gaveta abre por resultado da busca (hoje abre, mas a paleta fecha antes)

## Publicação

- `app/vercel.json` — o CSP do painel novo. **`style-src` precisou de
  `'unsafe-inline'`**: eu tinha raciocinado que os estilos do React passariam
  por CSSOM e não seriam bloqueados, e a verificação em produção provou o
  contrário. `script-src 'self'` continua estrito, que é o que protege de
  execução de código.
  Para voltar ao CSP fechado seria preciso trocar todo `style={{…}}` por classe
  em folha de estilo — um trabalho grande, e anotado aqui como opção.
- `scripts/verificar-noc-producao.mjs` confere o painel no ar: login real,
  dado de produção, zero violação de CSP.
- `scripts/verificar-dashboard-publicado.mjs` testa a estrutura do painel
  ANTIGO (`#app`, `#pulso-min`). **Está obsoleto** — precisa ser reescrito ou
  removido.
- O deploy criou por engano um projeto Vercel chamado `publicar` (nome da
  pasta). O painel certo está em `monitoramento-cajupar`; o projeto `publicar`
  pode ser apagado no painel da Vercel.
