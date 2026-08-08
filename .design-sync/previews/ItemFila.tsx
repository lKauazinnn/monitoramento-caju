// ItemFila — uma linha da fila de atencao.
import * as React from 'react';
import { ItemFila } from '@cajupar/sentinela-ds';

/**
 * A lista do que precisa de alguem agora, do pior para o menos grave.
 *
 * E a resposta para "o que eu faco primeiro?", que a grade sozinha nao da.
 */
export const FilaDeAtencao = () => (
  <ul style={{ listStyle: 'none', margin: 0, padding: 0, maxWidth: 520 }}>
    <ItemFila titulo="CAIXA 01 · sem contato" detalhe="há 14 min" tom="ruim" />
    <ItemFila titulo="Pinheiros · loja inteira parada" detalhe="há 8 min" tom="ruim" />
    <ItemFila titulo="PDV 02 · Spooler parado" detalhe="há 6 min" tom="alerta" />
    <ItemFila titulo="ADM 01 · disco C: com 8% livre" detalhe="há 2 h" tom="alerta" />
    <ItemFila titulo="PDV 07 · 31 dias sem reiniciar" detalhe="ontem" tom="ok" />
  </ul>
);
