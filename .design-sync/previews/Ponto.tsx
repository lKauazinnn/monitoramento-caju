// Ponto — o menor sinal da interface.
import * as React from 'react';
import { Ponto } from '@cajupar/sentinela-ds';

const cel: React.CSSProperties = { display: 'flex', alignItems: 'center', gap: 8, fontSize: 12.5 };

/** Um de cada tom, com o que cada cor significa. */
export const PorTom = () => (
  <div style={{ display: 'grid', gap: 10 }}>
    <span style={cel}><Ponto tom="ok" /> respondendo normalmente</span>
    <span style={cel}><Ponto tom="alerta" /> responde, mas com problema</span>
    <span style={cel}><Ponto tom="ruim" /> sem contato</span>
    <span style={cel}><Ponto tom="neutro" /> nunca reportou</span>
  </div>
);

/**
 * `pulsando` e para o que esta acontecendo AGORA.
 *
 * Um ponto que pulsa sem motivo treina a pessoa a ignorar o que pulsa — e ai o
 * que importa passa batido junto.
 */
export const PulsoDaIngestao = () => (
  <span style={cel}><Ponto tom="ok" pulsando /> 182 amostras/min chegando</span>
);
