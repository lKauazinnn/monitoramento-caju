# Notas da sincronizacao — Cajupar / Sentinela

## O que esta biblioteca e

`design-system/` NAO existia neste repositorio. O painel de producao
(`dashboard/`) e JavaScript puro com CSS escrito a mao — nao havia componente
React nenhum para sincronizar. A biblioteca foi CONSTRUIDA a partir da
linguagem visual que ja estava em producao.

**A decisao central, e a que mais importa para quem mexer nisto depois:**

O CSS **nao foi reescrito**. `design-system/build.mjs` COPIA
`dashboard/styles.css` a cada build. Duas versoes da mesma linguagem visual e
como as duas divergem — o painel muda, a biblioteca nao, e os desenhos feitos
com ela passam a mostrar um produto que nao existe.

Consequencia pratica: **para mudar o visual, mude `dashboard/styles.css`.**
Mexer em `design-system/src/sentinela.css` nao adianta — o arquivo e gerado e
sobrescrito no proximo build.

O build faz exatamente duas adaptacoes, e falha alto se qualquer uma nao casar
(um seletor que mudou no painel tem que ser tratado aqui, nao ignorado):

1. `html[data-tema="light"]` -> `[data-tema="light"]`, porque aqui o tema e
   aplicado num `<div>` (o componente `Sentinela`), nao no `<html>`.
2. `html, body { ... }` vira `.sentinela-raiz { ... }`, senao a folha pintaria
   o fundo do editor de quem usa a biblioteca.

## Fontes

O painel nao carrega fonte nenhuma, de proposito: loja com internet ruim
abriria o centro de operacoes com o texto de metrica trocado no meio do turno.
Ele usa a pilha do sistema.

A biblioteca serve `Inter` e `JetBrains Mono` (`design-system/fontes/`), que sao
os PROXIMOS NOMES DA PROPRIA PILHA do painel — nao substitutos. No Windows das
lojas, `Segoe UI Variable` e `Cascadia Mono` continuam vindo antes e ganhando;
o efeito e so em sistemas que nao os tem, como o renderizador da ferramenta de
desenho, onde antes o texto caia para a fonte generica.

Ambas sao SIL OFL 1.1, subconjunto latino, so os pesos que o painel usa
(400/600/700/800 e 400/600). Vieram de `@fontsource`, copiadas para dentro do
pacote: `extraFonts` e limitado ao repositorio.

## Animacao nas capturas

`.btn-perigo.armado` usa `pulseDot`, que vai a opacidade .32 e escala .8. Uma
foto tirada no meio do ciclo mostra o botao lavado e menor — **cheguei a
diagnosticar isso como defeito de contraste olhando a captura, e estava
errado.**

`design-system/conferir.mjs` emula `prefers-reduced-motion: reduce` antes de
qualquer foto. O CSS do painel ja respeita essa preferencia desligando animacao
e transicao, entao nao foi preciso mexer no design. Ao vivo a animacao continua
existindo. **Qualquer captura nova precisa fazer o mesmo.**

## Estado da sincronizacao

- projeto: `c86663b9-2ee7-46de-8246-e925a13f0738` ("Cajupar — Centro de operacoes"),
  criado vazio para esta importacao. Ha um projeto "Design System" de julho no
  mesmo espaco que NAO tem relacao com este repositorio — nao mexer.
- caminho de envio: incremental (projeto comecou vazio).
- escopo escolhido pelo usuario: cartao rico para os 26 componentes.
- playwright `1.62.1` casa com o chromium build `1234` ja em cache nesta
  maquina. Instalar outra versao falha com "Executable doesn't exist".
- `npm` aqui exige `npm approve-scripts esbuild` antes de o binario funcionar.

## Riscos para a proxima sincronizacao

- **`build.mjs` depende de dois trechos literais do `dashboard/styles.css`.**
  Se alguem reescrever o bloco `html, body` ou o seletor de tema, o build FALHA
  (de proposito). Ajuste as duas substituicoes, nao remova a checagem.
- **A biblioteca nao tem teste proprio de comportamento**, so a conferencia
  visual (`node design-system/conferir.mjs`, 15 verificacoes). Componente novo
  entra sem rede de protecao alem do olho.
- **`design-system/demo/` nao faz parte do pacote.** E a pagina que eu olho para
  comparar com o painel. Se um componente novo nao entrar nela, ele nunca sera
  conferido visualmente.
- Os 26 componentes cobrem a linguagem visual, mas o painel tem classes que
  ainda nao viraram componente (`.rel-tabela`, `.grafico-caixa`, `.busca-caixa`,
  `.usuario-chip`). Sao candidatos naturais para a proxima rodada.

## Avisos conhecidos do validate

- `[FONT_MISSING] "Cascadia Mono"` — **legitimo, nao perseguir.** E o primeiro
  nome da pilha monoespacada do painel, e e fonte da Microsoft: existe no
  Windows das lojas e nao se redistribui. O proximo nome da MESMA pilha,
  JetBrains Mono, e servido pela biblioteca, entao a familia esta coberta por
  um membro da pilha que nos enviamos — nao e substituto.

## Decisoes de apresentacao dos cartoes

- 15 componentes usam `cardMode: column`. Esta e uma biblioteca de PAINEL:
  cartao, faixa, linha de evento e de comando sao largos por natureza, e em
  grade o terceiro exemplo era cortado pela celula. Nada disso apareceu como
  erro — apareceu na FOLHA DE CONTATO, que e o unico lugar onde "passou nas
  verificacoes e esta feio" fica visivel.
- `Painel`, `Modal` e `Brinde` sao `position: fixed`. Os previews deles usam um
  **palco** (`transform: translateZ(0)` num ancestral, que cria contexto de
  contencao) para caberem no cartao sem mentir sobre o componente. `Brinde`
  ainda precisou de `cardMode: single` por cima disso.
- `cfg.provider = Sentinela`. **Sem essa raiz, TODO cartao renderiza com as
  cores do tema escuro sobre fundo branco** e o texto some. Foi o primeiro
  achado do conjunto de calibracao, e vale para quem consome a biblioteca
  tambem — esta no cabecalho de convencoes.

## Riscos adicionais para a proxima sincronizacao

- O cabecalho `.design-sync/conventions.md` nomeia variaveis, classes, props e
  estados. Ha um script de validacao em
  `scratchpad/validar-convencoes.mjs` (nao versionado) que confere todos contra
  o build; se o painel renomear um token, o cabecalho passa a mentir em
  silencio. **Revalide os nomes a cada sincronizacao.**
- Os 26 previews em `.design-sync/previews/` sao versionados e nao sao tocados
  pelo conversor. Componente novo na biblioteca entra com cartao simples ate
  alguem escrever o preview dele.
