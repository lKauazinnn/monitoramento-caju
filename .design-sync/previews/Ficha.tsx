// Ficha — a lista de rotulo e valor do painel de detalhe.
//
// E o componente mais denso em TEXTO da biblioteca, e por isso o melhor para
// ver se a tipografia chegou: se as fontes nao carregarem, e aqui que a
// proporcao quebra primeiro — o valor em monoespacada ao lado do rotulo em
// sans-serif e a comparacao mais dura que existe.
import * as React from 'react';
import { Ficha } from '@cajupar/sentinela-ds';

/** O uso canonico: a ficha de uma maquina, como ela aparece no painel. */
export const FichaDeMaquina = () => (
  <Ficha
    linhas={[
      { rotulo: 'Status', valor: 'online' },
      { rotulo: 'Hostname', valor: 'DESKTOP-K7N6IMC' },
      { rotulo: 'Último contato', valor: 'há 12s' },
      { rotulo: 'Perfil', valor: 'Estação administrativa' },
      { rotulo: 'IP na LAN', valor: '10.0.2.25' },
      { rotulo: 'MAC da placa', valor: 'c8:7f:54:c6:c9:92' },
      { rotulo: 'Sistema', valor: 'Microsoft Windows 10 Pro' },
      { rotulo: 'CPU', valor: 'Intel(R) Core(TM) i5-6600T CPU @ 2.70GHz' },
      { rotulo: 'Memória total', valor: '7.9 GB' },
      { rotulo: 'Versão do agente', valor: 'ps-1.3.1' },
      { rotulo: 'Uptime', valor: '1h 57m' },
      { rotulo: 'Desvio de relógio', valor: '-1s' },
    ]}
  />
);

/**
 * Campo sem dado mostra travessao — nunca some.
 *
 * Uma ficha que encolhe esconde que algo DEIXOU de ser reportado, e isso e
 * exatamente o sintoma que se quer ver: um agente que parou de coletar disco
 * some com a linha, e ninguem percebe que a informacao sumiu.
 */
export const CamposVazios = () => (
  <Ficha
    linhas={[
      { rotulo: 'Status', valor: 'offline' },
      { rotulo: 'Hostname', valor: 'PDV-02' },
      { rotulo: 'MAC da placa', valor: '' },
      { rotulo: 'Latência gateway', valor: null as unknown as string },
      { rotulo: 'Sinalizadores', valor: 'nenhum' },
      { rotulo: 'GUID', valor: 'e3a5c9b7-b2b1-465e-a5d4-a82295bc9beb' },
    ]}
  />
);
