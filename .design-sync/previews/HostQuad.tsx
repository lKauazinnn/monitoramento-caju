// HostQuad — o quadradinho de uma maquina no mapa de calor da loja.
import * as React from 'react';
import { HostQuad } from '@cajupar/sentinela-ds';

/**
 * O mapa de calor de uma loja de vinte PDVs.
 *
 * E o argumento inteiro do componente: um vermelho no meio de verdes salta aos
 * olhos sem lista, sem rolagem e sem ninguem procurar.
 */
export const MapaDeCalor = () => (
  <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap', maxWidth: 300 }}>
    {Array.from({ length: 11 }, (_, i) => (
      <HostQuad key={i} rotulo={`PDV ${i + 1}`} estado="online" />
    ))}
    <HostQuad rotulo="PDV 12" estado="degradado" />
    {Array.from({ length: 5 }, (_, i) => (
      <HostQuad key={i} rotulo={`PDV ${i + 13}`} estado="online" />
    ))}
    <HostQuad rotulo="PDV 18" estado="offline" />
    <HostQuad rotulo="ADM 01" estado="online" />
    <HostQuad rotulo="COZINHA" estado="never" />
  </div>
);

/** Um de cada estado, para saber que cor e o que. */
export const PorEstado = () => (
  <div style={{ display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap', fontSize: 11.5, color: 'var(--fg2)' }}>
    {([['online', 'online'], ['degradado', 'degradado'], ['offline', 'offline'],
       ['never', 'nunca vista'], ['manutencao', 'manutenção'], ['disabled', 'inativa']] as const)
      .map(([e, r]) => (
        <span key={e} style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
          <HostQuad rotulo={r} estado={e} /> {r}
        </span>
      ))}
  </div>
);
