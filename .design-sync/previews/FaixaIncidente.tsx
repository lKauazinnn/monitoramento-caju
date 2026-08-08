// FaixaIncidente — o aviso que nao pode passar batido.
import * as React from 'react';
import { FaixaIncidente } from '@cajupar/sentinela-ds';

/**
 * O incidente aberto mais grave, fixo no topo.
 *
 * Existe porque notificacao externa nao resolve o caso real: quem opera esta
 * OLHANDO a tela. O aviso tem que competir com o resto da tela — e ganhar.
 */
export const IncidenteCritico = () => (
  <FaixaIncidente
    titulo="BSB-004 · PDV 02 sem contato há 14 min"
    descricao="A loja tem outras 3 máquinas respondendo normalmente."
    tags={['BSB-004', 'PDV 02', 'crítico']}
    quando="14 min"
    onReconhecer={() => {}}
    onAbrir={() => {}}
  />
);

/**
 * `warning` nao pulsa.
 *
 * Se tudo pulsa, nada pulsa: o pulso fica reservado para o que derruba loja.
 */
export const Aviso = () => (
  <FaixaIncidente
    severidade="warning"
    titulo="SP-003 · disco C: com 9% livre em 2 máquinas"
    descricao="No ritmo atual, enche em cerca de 6 dias."
    tags={['SP-003', 'disco']}
    quando="2 h"
    onReconhecer={() => {}}
  />
);

/** Sem acoes: so o aviso, quando ninguem pode agir dali. */
export const SoAviso = () => (
  <FaixaIncidente
    titulo="Pinheiros · loja inteira sem contato"
    descricao="Nenhuma das 3 máquinas responde. Costuma ser queda de energia ou de link, não defeito de PC."
    tags={['SP-011', 'loja parada']}
    quando="8 min"
  />
);
