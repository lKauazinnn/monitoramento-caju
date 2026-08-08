// Selo — o contador com estado do cabecalho.
import * as React from 'react';
import { Selo } from '@cajupar/sentinela-ds';

const linha: React.CSSProperties = { display: 'flex', gap: 10, flexWrap: 'wrap' };

/** Como aparece no topo do centro de operacoes: le-se de relance. */
export const CabecalhoDaFrota = () => (
  <div style={linha}>
    <Selo tom="ok" valor={39}>ok</Selo>
    <Selo tom="alerta" valor={5}>degradados</Selo>
    <Selo tom="ruim" valor={3}>offline</Selo>
  </div>
);

/**
 * `zero` esmaece.
 *
 * "0 offline" e boa noticia e nao deve ter o mesmo peso de "3 offline". Se
 * qualquer coisa pode gritar, nada chama atencao.
 */
export const ZeroNaoGrita = () => (
  <div style={linha}>
    <Selo tom="ruim" valor={0} zero>offline</Selo>
    <Selo tom="ruim" valor={3}>offline</Selo>
  </div>
);

/** Sem ponto e sem valor: usado para estado da conexao. */
export const SoTexto = () => (
  <div style={linha}>
    <Selo comPonto={false}>conectando</Selo>
    <Selo tom="ok">ingestão normal</Selo>
  </div>
);
