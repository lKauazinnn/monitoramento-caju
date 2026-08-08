// Sentinela — a raiz. ENVOLVA TUDO NELA.
import * as React from 'react';
import { Sentinela, Marca, Vista, Tira, Cartao, Selo } from '@cajupar/sentinela-ds';

const Conteudo = () => (
  <div style={{ display: 'grid', gridTemplateColumns: '190px 1fr', gap: 16, padding: 14 }}>
    <div style={{ display: 'grid', gap: 10, alignContent: 'start' }}>
      <Marca escopo="12 lojas · 47 máquinas" />
      <Vista rotulo="Visão geral" contagem={47} ativa />
      <Vista rotulo="Offline" contagem={3} tom="ruim" />
    </div>
    <div style={{ display: 'grid', gap: 12 }}>
      <div style={{ display: 'flex', gap: 8 }}>
        <Selo tom="ok" valor={39}>ok</Selo>
        <Selo tom="ruim" valor={3}>offline</Selo>
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
        <Tira rotulo="Frota online" valor="39" unidade="de 47" nota="83% reportando" />
        <Tira rotulo="Offline" valor="3" tom="ruim" nota="BSB-004, SP-011" />
      </div>
      <Cartao nome="PDV 01" estado="online" contexto="BSB-001 — Sudoeste" visto="há 12s"
              metricas={[{ rotulo: 'CPU', valor: '29%' }, { rotulo: 'MEM', valor: '61%' }]} />
    </div>
  </div>
);

/**
 * O tema escuro e o padrao.
 *
 * Este painel foi feito para ficar aberto o turno inteiro, muitas vezes numa TV
 * de sala tecnica — e claro numa sala escura cansa a vista em uma hora.
 */
export const TemaEscuro = () => (
  <Sentinela tema="escuro" malha={false}><Conteudo /></Sentinela>
);

/**
 * O tema claro sai trocando UMA propriedade.
 *
 * Todas as cores sao variaveis CSS, entao `tema="claro"` reescreve o sistema
 * inteiro — nao ha uma segunda folha de estilo para manter em dia.
 */
export const TemaClaro = () => (
  <Sentinela tema="claro" malha={false}><Conteudo /></Sentinela>
);
