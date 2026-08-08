// Barra — uso de CPU, memoria e disco.
import * as React from 'react';
import { Barra } from '@cajupar/sentinela-ds';

const rot: React.CSSProperties = {
  fontSize: 10.5, letterSpacing: '.08em', textTransform: 'uppercase',
  color: 'var(--fg3)', display: 'block', marginBottom: 5,
};

/** Como aparece no painel de detalhe, com o rotulo em cima. */
export const UsoDeRecursos = () => (
  <div style={{ display: 'grid', gap: 14, maxWidth: 420 }}>
    <div><span style={rot}>CPU · 29%</span><Barra pct={29} /></div>
    <div><span style={rot}>Memória · 61%</span><Barra pct={61} /></div>
    <div><span style={rot}>Disco C: · 78%</span><Barra pct={78} /></div>
  </div>
);

/**
 * Passando do limiar, a barra fica vermelha.
 *
 * O limiar e por chamada porque disco e CPU nao doem no mesmo ponto: 85% de
 * CPU num PDV e pico de movimento; 85% de disco e chamado na semana que vem.
 */
export const LimiarEstourado = () => (
  <div style={{ display: 'grid', gap: 14, maxWidth: 420 }}>
    <div><span style={rot}>CPU · 88% (limiar 90)</span><Barra pct={88} /></div>
    <div><span style={rot}>CPU · 94% (limiar 90)</span><Barra pct={94} /></div>
    <div><span style={rot}>Disco · 88% (limiar 80)</span><Barra pct={88} limiar={80} /></div>
  </div>
);
