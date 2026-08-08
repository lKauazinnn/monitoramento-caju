// Marca — o selo do produto, no topo da lateral.
import * as React from 'react';
import { Marca } from '@cajupar/sentinela-ds';

/** Com o escopo: quantas lojas e maquinas a sessao alcanca. */
export const ComEscopo = () => (
  <div style={{ maxWidth: 210 }}>
    <Marca escopo="12 lojas · 47 máquinas" />
  </div>
);

/** Sem escopo, enquanto o painel ainda esta carregando. */
export const Carregando = () => (
  <div style={{ maxWidth: 210 }}>
    <Marca escopo="carregando" />
  </div>
);
