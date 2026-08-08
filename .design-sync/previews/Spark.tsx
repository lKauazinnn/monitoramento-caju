// Spark — tendencia sem eixo, sem legenda e sem ocupar espaco.
import * as React from 'react';
import { Spark } from '@cajupar/sentinela-ds';

const cx: React.CSSProperties = { display: 'grid', gap: 16, maxWidth: 420 };
const rot: React.CSSProperties = {
  fontSize: 10.5, letterSpacing: '.08em', textTransform: 'uppercase',
  color: 'var(--fg3)', display: 'block', marginBottom: 6,
};

/** Uma serie normal de ingestao ao longo da ultima hora. */
export const Tendencia = () => (
  <div style={cx}>
    <div><span style={rot}>amostras/min</span>
      <Spark valores={[8, 11, 9, 12, 10, 13, 11, 14, 12, 13, 15, 14]} /></div>
    <div><span style={rot}>fila de disco</span>
      <Spark valores={[1, 1, 2, 1, 4, 7, 11, 9, 6, 3, 2, 1]} tom="alerta" /></div>
  </div>
);

/**
 * SERIE CURTA NAO E DEFEITO A ESCONDER.
 *
 * Uma frota recem-instalada tem duas amostras. Mostrar duas barras e mais
 * honesto que desenhar uma linha que sugere uma tendencia que ninguem mediu —
 * e este componente existe nesta forma por causa disso.
 */
export const FrotaNova = () => (
  <div style={cx}>
    <div><span style={rot}>duas amostras</span><Spark valores={[3, 5]} /></div>
    <div><span style={rot}>uma amostra</span><Spark valores={[4]} /></div>
    <div><span style={rot}>nenhuma ainda</span><Spark valores={[]} /></div>
  </div>
);

/** A variante estreita, da barra lateral. */
export const NaBarraLateral = () => (
  <div style={{ maxWidth: 190 }}>
    <span style={rot}>ingestão</span>
    <Spark valores={[4, 7, 6, 9, 8, 10, 9, 11, 9, 10]} lateral />
  </div>
);
