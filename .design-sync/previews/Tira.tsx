// Tira — a tira de KPI do topo do centro de operacoes.
//
// Conteudo real, dos numeros que o painel mostra de verdade. Nada de "foo":
// estes cartoes sao lidos por gente e imitados pelo agente de design.
import * as React from 'react';
import { Tira } from '@cajupar/sentinela-ds';

/** O uso canonico: o numero, a unidade, e uma linha dizendo o que ele significa. */
export const FrotaOnline = () => (
  <Tira
    rotulo="Frota online"
    valor="39"
    unidade="de 47"
    nota="83% da frota reportando"
    spark={[30, 33, 36, 38, 39, 39, 38, 39]}
  />
);

/** O eixo que mais muda a aparencia: o tom. Um de cada, lado a lado. */
export const PorGravidade = () => (
  <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 12 }}>
    <Tira rotulo="Estáveis" valor="39" tom="ok" nota="nenhum problema" />
    <Tira rotulo="Degradados" valor="5" tom="alerta" nota="serviço parado ou disco baixo" />
    <Tira rotulo="Offline" valor="3" tom="ruim" nota="BSB-004, SP-011" />
  </div>
);

/**
 * `zero` esmaece a tira.
 *
 * Zero incidente nao pode ter o mesmo peso visual que dez: se tudo grita,
 * nada chama atencao. A comparacao lado a lado e o que mostra a diferenca.
 */
export const ZeroEsmaece = () => (
  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
    <Tira rotulo="Incidentes" valor="0" zero nota="nenhum aberto" />
    <Tira rotulo="Incidentes" valor="2" tom="ruim" nota="BSB-004 há 14 min" />
  </div>
);
