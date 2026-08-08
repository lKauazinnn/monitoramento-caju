// Brinde — o aviso passageiro de canto.
import * as React from 'react';
import { Brinde } from '@cajupar/sentinela-ds';

/**
 * O PALCO.
 *
 * Gaveta, modal e brinde sao \`position: fixed\` — eles se posicionam pela
 * JANELA, nao pelo elemento que os contem. Dentro de um cartao de preview isso
 * os faz escapar para fora e renderizar sobre o fundo branco da pagina, com o
 * texto claro do tema escuro em cima: some.
 *
 * \`transform\` num ancestral cria um contexto de contencao — a partir dai
 * \`fixed\` passa a se posicionar por ELE. E o unico jeito de mostrar uma
 * sobreposicao dentro de um cartao sem mentir sobre o componente: ele continua
 * sendo o mesmo componente fixo, so que num palco do tamanho do cartao.
 *
 * No aplicativo de verdade nada disto e necessario — la a janela E o palco.
 */
const Palco = ({ children, altura = 420 }: { children: React.ReactNode; altura?: number }) => (
  <div
    style={{
      position: 'relative',
      transform: 'translateZ(0)',
      height: altura,
      overflow: 'hidden',
      borderRadius: 12,
      background: 'var(--bg)',
      border: '1px solid var(--bd2)',
    }}
  >
    {children}
  </div>
);

/** Confirmacao de uma acao que deu certo. */
export const Confirmacao = () => (
  <Palco altura={150}>
    <Brinde mensagem="Comando enviado em modo simulação." />
  </Palco>
);

/**
 * Erro fica mais tempo e muda de cor.
 *
 * A mensagem carrega o MOTIVO, nao so "falhou": quem le esta tentando decidir
 * o proximo passo, e "erro ao enviar" nao ajuda a decidir nada.
 */
export const Erro = () => (
  <Palco altura={150}>
    <Brinde erro mensagem="esta máquina foi reiniciada há menos de 30 min" />
  </Palco>
);
