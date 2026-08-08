// Segmentado — o alternador curto de faixa de tempo.
import * as React from 'react';
import { Segmentado } from '@cajupar/sentinela-ds';

/** As faixas do grafico de detalhe, com "24 h" ativa. */
export const FaixaDeTempo = () => (
  <Segmentado
    valor="24h"
    opcoes={[
      { valor: '24h', rotulo: '24 h' },
      { valor: '7d', rotulo: '7 d' },
      { valor: '30d', rotulo: '30 d' },
    ]}
  />
);

/** Tambem serve para trocar o agrupamento da grade. */
export const Agrupamento = () => (
  <Segmentado
    valor="lojas"
    opcoes={[
      { valor: 'lojas', rotulo: 'Lojas' },
      { valor: 'maquinas', rotulo: 'Máquinas' },
    ]}
  />
);
