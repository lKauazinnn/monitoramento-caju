// Comando — uma linha do historico de acao remota.
import * as React from 'react';
import { Comando } from '@cajupar/sentinela-ds';

const lista: React.CSSProperties = { listStyle: 'none', margin: 0, padding: 0, maxWidth: 560 };

/**
 * O ciclo de vida de um comando, do mais novo ao mais velho.
 *
 * A barra da esquerda carrega o estado: da para varrer a lista sem ler. E o
 * relato de `expirou` importa tanto quanto o de sucesso — comando que espera
 * numa loja desligada e o caso mais comum, nao a excecao.
 */
export const CicloDeVida = () => (
  <ul style={lista}>
    <Comando acao="Reiniciar serviço" estado="pending" quando="13:41" onCancelar={() => {}} />
    <Comando acao="Testar coleta" estado="sent" quando="13:38" />
    <Comando acao="Reiniciar serviço" estado="succeeded" quando="13:34"
             resultado="serviço 'Spooler': Stopped -> Running" />
    <Comando acao="Limpar temporários" estado="failed" quando="12:50"
             resultado="acesso negado em C:\\Windows\\Temp — 23 arquivos em uso" />
    <Comando acao="Reiniciar o PC" estado="expired" quando="09:12"
             resultado="expirou sem ser executado" />
  </ul>
);

/**
 * Simulacao e marcada no rotulo, nao so na cor.
 *
 * Um dry-run que se parece com execucao real ensina a nao confiar na
 * simulacao — e a simulacao so serve enquanto for confiavel.
 */
export const Simulacao = () => (
  <ul style={lista}>
    <Comando acao="Reiniciar o PC" estado="succeeded" quando="13:20" simulacao
             resultado="SIMULAÇÃO: reiniciaria esta máquina em 15s" />
    <Comando acao="Reiniciar o PC" estado="succeeded" quando="13:44"
             resultado="reinício agendado para daqui a 15s" />
  </ul>
);

/** Cancelar so aparece enquanto o comando ainda esta na fila. */
export const CancelavelSoNaFila = () => (
  <ul style={lista}>
    <Comando acao="Limpar temporários" estado="pending" quando="13:41" onCancelar={() => {}} />
    <Comando acao="Limpar temporários" estado="sent" quando="13:39" onCancelar={() => {}} />
  </ul>
);
