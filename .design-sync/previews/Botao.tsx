// Botao — as cinco variantes, e o que separa `perigo` das outras.
import * as React from 'react';
import { Botao } from '@cajupar/sentinela-ds';

const linha: React.CSSProperties = { display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap' };

/** As variantes, em ordem de peso visual. */
export const Variantes = () => (
  <div style={linha}>
    <Botao variante="primario">+ Adicionar PC</Botao>
    <Botao variante="secundario">Abrir</Botao>
    <Botao variante="acao">Testar coleta</Botao>
    <Botao variante="perigo">Reiniciar o PC</Botao>
    <Botao variante="mini">Cancelar</Botao>
  </div>
);

/**
 * `armado` e o segundo passo de uma acao destrutiva.
 *
 * A confirmacao em duas etapas e a unica protecao contra apagar historico por
 * engano — e vale SO para o que nao tem volta. Fazer confirmar tudo ensina a
 * confirmar sem ler, e ai a confirmacao do que importa perde o sentido.
 */
export const ConfirmacaoEmDoisPassos = () => (
  <div style={linha}>
    <Botao variante="perigo">Remover máquina</Botao>
    <Botao variante="perigo" armado>Confirmar: apagar tudo</Botao>
  </div>
);

/** `largo` ocupa a linha: usado dentro da zona de perigo e em modais. */
export const Largo = () => (
  <div style={{ display: 'grid', gap: 8, maxWidth: 340 }}>
    <Botao variante="primario" largo>Cadastrar e gerar comando</Botao>
    <Botao variante="perigo" largo>Remover máquina</Botao>
  </div>
);

/** Desabilitado: o painel usa para acao que a maquina nao sabe executar. */
export const Desabilitado = () => (
  <div style={linha}>
    <Botao variante="acao" disabled>Reiniciar serviço</Botao>
    <Botao variante="perigo" disabled>Reiniciar o PC</Botao>
  </div>
);
