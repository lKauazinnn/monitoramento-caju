// Vista — o item da barra lateral.
import * as React from 'react';
import { Vista } from '@cajupar/sentinela-ds';

/**
 * A navegacao inteira do painel.
 *
 * Cada item e um FILTRO real com a contagem do que vai mostrar, nao um destino
 * de navegacao: este sistema tem UMA tela, e link morto seria tao ruim quanto
 * numero inventado.
 */
export const NavegacaoDaOperacao = () => (
  <nav style={{ display: 'grid', gap: 2, maxWidth: 210 }}>
    <Vista rotulo="Visão geral" contagem={47} ativa />
    <Vista rotulo="Offline" contagem={3} tom="ruim" />
    <Vista rotulo="Degradados" contagem={5} tom="alerta" />
    <Vista rotulo="Nunca vistas" contagem={0} />
  </nav>
);

/** Contagem zero esmaece, pelo mesmo motivo do Selo e da Tira. */
export const ContagemZero = () => (
  <nav style={{ display: 'grid', gap: 2, maxWidth: 210 }}>
    <Vista rotulo="Offline" contagem={0} tom="ruim" />
    <Vista rotulo="Offline" contagem={3} tom="ruim" />
  </nav>
);
