// Cartao — uma maquina na grade.
import * as React from 'react';
import { Cartao } from '@cajupar/sentinela-ds';

const grade: React.CSSProperties = {
  display: 'grid', gridTemplateColumns: 'repeat(2, minmax(220px, 1fr))', gap: 12,
};

/** O uso canonico: maquina saudavel, com as tres metricas que importam. */
export const MaquinaSaudavel = () => (
  <div style={{ maxWidth: 300 }}>
    <Cartao
      nome="PDV 01"
      estado="online"
      contexto="BSB-001 — Sudoeste"
      visto="há 12s"
      servicos="3 de 3 serviços"
      metricas={[
        { rotulo: 'CPU', valor: '29%' },
        { rotulo: 'MEM', valor: '61%' },
        { rotulo: 'DISCO', valor: '22%' },
      ]}
    />
  </div>
);

/**
 * Os estados, como aparecem na grade de verdade.
 *
 * `degradado` e o que justifica o componente: a maquina RESPONDE, mas esta com
 * o Spooler parado. Sem um estado proprio ela ficaria verde ao lado de uma
 * saudavel, e o problema so apareceria quando alguem reclamasse.
 */
export const PorEstado = () => (
  <div style={grade}>
    <Cartao nome="PDV 01" estado="online" contexto="BSB-001 — Sudoeste"
            visto="há 12s" servicos="3 de 3 serviços"
            metricas={[{ rotulo: 'CPU', valor: '29%' }, { rotulo: 'MEM', valor: '61%' }]} />
    <Cartao nome="PDV 02" estado="degradado" contexto="BSB-001 — Sudoeste"
            visto="há 40s" servicos="2 de 3 serviços"
            metricas={[{ rotulo: 'CPU', valor: '88%', tom: 'alerta' }, { rotulo: 'MEM', valor: '74%' }]} />
    <Cartao nome="CAIXA 01" estado="offline" contexto="BSB-004 — Asa Norte" visto="há 14 min" />
    <Cartao nome="ADM 01" estado="never" contexto="SP-011 — Pinheiros" />
  </div>
);

/** Em manutencao declarada: nao gera alerta, e a etiqueta explica por que. */
export const EmManutencao = () => (
  <div style={{ maxWidth: 300 }}>
    <Cartao nome="SERVIDOR 01" estado="manutencao" contexto="BSB-001 — Sudoeste"
            visto="há 2 min" servicos="1 de 4 serviços" />
  </div>
);
