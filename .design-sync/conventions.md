# Sentinela — como construir com esta biblioteca

Linguagem visual do centro de operações da Cajupar: um painel de monitoramento
que fica aberto o turno inteiro, muitas vezes numa TV de sala técnica.

## Envolva tudo em `<Sentinela>`

**Sem essa raiz, tudo renderiza ilegível.** Ela é quem define `data-tema` e o
fundo (`--bg`); sem ela os componentes herdam a cor da página hospedeira e o
texto claro do tema escuro cai sobre fundo branco — o número da métrica some.

```jsx
import { Sentinela, Tira, Cartao } from '@cajupar/sentinela-ds';

<Sentinela>
  <Tira rotulo="Frota online" valor="39" unidade="de 47" nota="83% reportando" />
</Sentinela>
```

`tema="claro"` troca o sistema inteiro — todas as cores são variáveis CSS, não
há uma segunda folha de estilo. `malha={false}` desliga a grade decorativa do
fundo ao embutir em outra página.

## Não escreva classes CSS

Este sistema **não é utilitário**. Não existe `bg-surface-1`, `p-4`, `gap-md`.
Toda a linguagem está nos componentes e em **variáveis CSS**. Para o seu próprio
layout (grades, espaçamentos entre componentes), use `style` com as variáveis:

| variável | uso |
|---|---|
| `--bg` | fundo da aplicação |
| `--pnl`, `--pnl2` | superfície de painel e de painel secundário |
| `--bd`, `--bd2` | borda e borda sutil |
| `--fg`, `--fg2`, `--fg3` | texto principal, secundário, terciário |
| `--ok`, `--warn`, `--crit` | saudável, atenção, crítico |
| `--info`, `--vio` | link e realce |
| `--r-p`, `--r-m`, `--r-g` | raio pequeno, médio, grande |
| `--fonte`, `--mono` | pilha de texto e monoespacada |

```jsx
<div style={{ display: 'grid', gap: 12, background: 'var(--pnl)',
              border: '1px solid var(--bd)', borderRadius: 'var(--r-m)', padding: 14 }}>
```

Classes utilitárias existentes e legítimas: `mono` (monoespacada com números de
largura fixa), `dica` (texto de apoio), `secao-lateral` (rótulo de seção).

## A regra de cor manda em tudo

**Vermelho é reservado** para offline e limiar estourado. Se qualquer coisa pode
ficar vermelha, nada chama atenção. Âmbar é "responde, mas com problema". Verde
é saudável.

Componentes com contagem (`Tira`, `Selo`, `Vista`) têm `zero` — zero problema
não pode ter o mesmo peso visual que dez.

## Estados de máquina

`online` · `degradado` · `offline` · `never` · `manutencao` · `disabled`

`degradado` é **derivado**, não vem do agente: a máquina responde, mas está com
serviço parado ou disco no limite. Sem ele ficaria verde ao lado de uma
saudável.

## Ação destrutiva

`<Botao variante="perigo">` para o que derruba loja ou apaga histórico, e
`armado` para o segundo clique. A confirmação em duas etapas vale **só** para o
que não tem volta — fazer confirmar tudo ensina a confirmar sem ler.

`<ZonaPerigo>` fica no fim do painel, separada, e o aviso diz **o que se perde**.

## Sobreposições

`Painel` (gaveta), `Modal` e `Brinde` são `position: fixed` — posicionam-se pela
janela. Numa aplicação normal isso é o certo. Para renderizá-los dentro de uma
área limitada, um ancestral precisa de `transform: translateZ(0)`, que cria o
contexto de contenção.

## Onde está a verdade

Leia antes de estilizar: `_ds/<pasta>/styles.css` e o que ele importa —
`tokens/` tem as variáveis e o tema claro, `_ds_bundle.css` tem os componentes.
Cada componente tem seu `.prompt.md` com a API e exemplos.

## Exemplo idiomático

```jsx
<Sentinela>
  <div style={{ display: 'grid', gap: 14, padding: 16 }}>
    <div style={{ display: 'flex', gap: 8 }}>
      <Selo tom="ok" valor={39}>ok</Selo>
      <Selo tom="ruim" valor={3}>offline</Selo>
    </div>

    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 12 }}>
      <Tira rotulo="Frota online" valor="39" unidade="de 47" nota="83% reportando" />
      <Tira rotulo="Degradados" valor="5" tom="alerta" nota="serviço parado" />
      <Tira rotulo="Incidentes" valor="0" zero nota="nenhum aberto" />
    </div>

    <CartaoLoja
      nome="Sudoeste" codigo="BSB-001" situacao="estavel"
      hosts={[{ rotulo: 'PDV 01', estado: 'online' },
              { rotulo: 'PDV 02', estado: 'degradado' }]}
      celulas={[{ rotulo: 'ONLINE', valor: '2/2', tom: 'ok' }]}
    />
  </div>
</Sentinela>
```
