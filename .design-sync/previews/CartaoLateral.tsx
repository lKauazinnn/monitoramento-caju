// CartaoLateral — um numero que se olha o tempo todo.
import * as React from 'react';
import { CartaoLateral } from '@cajupar/sentinela-ds';

/**
 * O pulso da ingestao.
 *
 * Responde "os dados estao chegando?" sem depender de nenhuma maquina
 * especifica estar reportando — e por isso ele fica fixo na lateral, nao na
 * grade.
 */
export const PulsoDaIngestao = () => (
  <div style={{ maxWidth: 200 }}>
    <CartaoLateral
      titulo="Ingestão" valor="182" unidade="amostras/min" tom="ok"
      nota="fluxo normal" spark={[4, 7, 6, 9, 8, 10, 9, 11, 9, 10]}
    />
  </div>
);

/** Sem sparkline nem bolinha: um numero simples. */
export const LatenciaDoGateway = () => (
  <div style={{ maxWidth: 200 }}>
    <CartaoLateral titulo="Latência ao gateway" valor="11.3 ms" nota="média das online" />
  </div>
);

/** Quando o fluxo cai, a bolinha e a nota mudam junto. */
export const IngestaoParada = () => (
  <div style={{ maxWidth: 200 }}>
    <CartaoLateral
      titulo="Ingestão" valor="0" unidade="amostras/min" tom="ruim"
      nota="nada chegando há 6 min" spark={[9, 8, 10, 7, 4, 1, 0, 0]}
    />
  </div>
);
