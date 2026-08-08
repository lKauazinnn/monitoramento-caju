// Etiqueta — o estado da maquina, no canto do cartao.
import * as React from 'react';
import { Etiqueta } from '@cajupar/sentinela-ds';

/**
 * Os seis estados.
 *
 * `degradado` e DERIVADO, nao vem do agente: e a maquina que responde mas
 * esta com servico parado ou disco no limite. Sem ele, ela ficaria verde ao
 * lado de uma saudavel.
 */
export const TodosOsEstados = () => (
  <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
    <Etiqueta estado="online" />
    <Etiqueta estado="degradado" />
    <Etiqueta estado="offline" />
    <Etiqueta estado="never" />
    <Etiqueta estado="manutencao" />
    <Etiqueta estado="disabled" />
  </div>
);
