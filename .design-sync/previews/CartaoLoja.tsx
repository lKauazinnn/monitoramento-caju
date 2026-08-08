// CartaoLoja — a visao que a operacao usa de verdade.
//
// Ninguem pensa em "maquina 47": pensa em "a loja do Sudoeste esta ruim". O
// mapa de calor no meio do cartao e o que responde isso de relance.
import * as React from 'react';
import { CartaoLoja } from '@cajupar/sentinela-ds';

const CELULAS_OK = [
  { rotulo: 'ONLINE', valor: '4/4', tom: 'ok' as const },
  { rotulo: 'CPU', valor: '31%' },
  { rotulo: 'DISCO', valor: '46%' },
];

/** O uso canonico: loja inteira de pe. */
export const LojaEstavel = () => (
  <CartaoLoja
    nome="Sudoeste"
    codigo="BSB-001"
    situacao="estavel"
    hosts={[
      { rotulo: 'PDV 01', estado: 'online' },
      { rotulo: 'PDV 02', estado: 'online' },
      { rotulo: 'PDV 03', estado: 'online' },
      { rotulo: 'ADM 01', estado: 'online' },
    ]}
    celulas={CELULAS_OK}
  />
);

/**
 * As quatro situacoes, em ordem de gravidade.
 *
 * `parada` tem cor propria porque e diferente de "algumas com problema":
 * nenhuma maquina responde, e isso normalmente e queda de energia ou de link,
 * nao defeito de PC.
 */
export const PorSituacao = () => (
  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
    <CartaoLoja
      nome="Sudoeste" codigo="BSB-001" situacao="estavel"
      hosts={[{ rotulo: 'PDV 01', estado: 'online' }, { rotulo: 'PDV 02', estado: 'online' },
              { rotulo: 'PDV 03', estado: 'online' }, { rotulo: 'ADM 01', estado: 'online' }]}
      celulas={CELULAS_OK}
    />
    <CartaoLoja
      nome="Águas Claras" codigo="BSB-002" situacao="atencao"
      hosts={[{ rotulo: 'PDV 01', estado: 'online' }, { rotulo: 'PDV 02', estado: 'degradado' },
              { rotulo: 'ADM 01', estado: 'online' }]}
      celulas={[{ rotulo: 'ONLINE', valor: '3/3', tom: 'ok' },
                { rotulo: 'CPU', valor: '77%', tom: 'alerta' },
                { rotulo: 'DISCO', valor: '38%' }]}
    />
    <CartaoLoja
      nome="Asa Norte" codigo="BSB-004" situacao="incidente"
      hosts={[{ rotulo: 'PDV 01', estado: 'online' }, { rotulo: 'PDV 02', estado: 'offline' },
              { rotulo: 'CAIXA 01', estado: 'degradado' }, { rotulo: 'ADM 01', estado: 'online' }]}
      celulas={[{ rotulo: 'ONLINE', valor: '2/4', tom: 'ruim' },
                { rotulo: 'CPU', valor: '54%' },
                { rotulo: 'DISCO', valor: '12%', tom: 'ruim' }]}
    />
    <CartaoLoja
      nome="Pinheiros" codigo="SP-011" situacao="parada"
      hosts={[{ rotulo: 'PDV 01', estado: 'offline' }, { rotulo: 'PDV 02', estado: 'offline' },
              { rotulo: 'ADM 01', estado: 'offline' }]}
      celulas={[{ rotulo: 'ONLINE', valor: '0/3', tom: 'ruim' },
                { rotulo: 'CPU', valor: '—' },
                { rotulo: 'DISCO', valor: '—' }]}
    />
  </div>
);

/**
 * Loja grande: vinte PDVs cabem num cartao.
 *
 * E o argumento do mapa de calor — um vermelho no meio de verdes salta aos
 * olhos sem precisar de lista, e uma lista de vinte linhas nao caberia aqui.
 */
export const LojaGrande = () => (
  <CartaoLoja
    nome="Shopping Iguatemi" codigo="SP-003" situacao="atencao"
    hosts={[
      ...Array.from({ length: 9 }, (_, i) => ({
        rotulo: `PDV ${String(i + 1).padStart(2, '0')}`, estado: 'online' as const,
      })),
      { rotulo: 'PDV 10', estado: 'degradado' as const },
      ...Array.from({ length: 6 }, (_, i) => ({
        rotulo: `PDV ${i + 11}`, estado: 'online' as const,
      })),
      { rotulo: 'PDV 17', estado: 'offline' as const },
      { rotulo: 'ADM 01', estado: 'online' as const },
      { rotulo: 'ADM 02', estado: 'online' as const },
      { rotulo: 'COZINHA', estado: 'online' as const },
    ]}
    celulas={[{ rotulo: 'ONLINE', valor: '19/20', tom: 'alerta' },
              { rotulo: 'CPU', valor: '44%' },
              { rotulo: 'DISCO', valor: '51%' }]}
  />
);
