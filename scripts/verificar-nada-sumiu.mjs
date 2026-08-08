// =============================================================================
// A trava: NENHUMA função pode sumir numa mudança de interface
// =============================================================================
// Rode com:  node scripts/verificar-nada-sumiu.mjs
//
// POR QUE ESTE ARQUIVO EXISTE, escrito sem rodeio:
//
// Eu reconstruí o painel para melhorar a aparência e publiquei uma versão que
// tinha PERDIDO oito ações — reiniciar serviço, limpar temporários, reiniciar,
// ligar, suspender, agendar reinício, remover máquina e cancelar comando.
// Sobrou "Testar coleta". Os testes que eu tinha verificavam que a tela
// renderizava, que não explodia e que não inventava número. Nenhum deles
// verificava que ela continuava FAZENDO o que fazia.
//
// Esta lista é o contrato. Toda melhoria de interface roda isto antes de
// publicar, e ele reprova se qualquer controle desaparecer. Mudar o visual de
// um botão é livre; fazer o botão sumir, não.
//
// Para acrescentar uma função nova: acrescente a linha aqui junto.
// Para REMOVER uma de propósito: remova a linha aqui, no mesmo commit, e diga
// no commit por que ela deixou de existir. O que não pode é sumir calado.
// =============================================================================

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

const raiz = fileURLToPath(new URL('..', import.meta.url));
const html = readFileSync(join(raiz, 'dashboard', 'index.html'), 'utf8');
const js = readFileSync(join(raiz, 'dashboard', 'dash.js'), 'utf8');

/**
 * Cada linha: [id do elemento, o que ele faz].
 *
 * O id é o contrato — o texto do botão e a cor podem mudar à vontade numa
 * melhoria de interface, o id não. É por isso que a trava é por id.
 */
const CONTROLES = [
  // ---------------------------------------------------------- ações remotas
  ['btn-restart-service', 'reiniciar um serviço crítico da máquina'],
  ['acao-servico', 'escolher QUAL serviço reiniciar'],
  ['btn-clear-temp', 'limpar arquivos temporários'],
  ['btn-test-collection', 'pedir uma coleta de teste'],
  ['btn-restart-machine', 'reiniciar o PC (dois cliques)'],
  ['btn-agendar-reinicio', 'agendar o reinício para as 4h'],
  ['btn-wake', 'ligar o PC pela rede (Wake-on-LAN)'],
  ['btn-sleep', 'suspender o PC'],
  ['acao-simular', 'simular antes de agir — o padrão'],
  ['acao-historico', 'histórico de comandos, com cancelar'],
  ['acao-aviso', 'o motivo de um botão estar bloqueado'],

  // ------------------------------------------------------------- destrutivo
  ['zona-perigo', 'a seção separada do que não tem volta'],
  ['btn-remover-maquina', 'remover a máquina e todo o histórico dela'],

  // ------------------------------------------------------------------ painel
  ['painel', 'a gaveta de detalhe da máquina'],
  ['painel-dados', 'a ficha: hostname, IP, MAC, uptime'],
  ['painel-eventos', 'os eventos recentes da máquina'],
  ['btn-fechar-painel', 'fechar a gaveta'],
  ['grafico-cpu', 'o gráfico de CPU'],
  ['grafico-mem', 'o gráfico de memória'],
  ['grafico-disco', 'o gráfico de disco'],

  // ------------------------------------------------------------------ frota
  ['busca', 'buscar máquina, host, loja ou IP'],
  ['conteudo', 'a grade de máquinas e lojas'],
  ['nav-marcas', 'filtrar por marca'],
  ['escopo-kpi', 'o aviso de que os KPIs seguem o filtro'],

  // --------------------------------------------------------------- incidente
  ['faixa-incidente', 'a faixa do incidente aberto'],
  ['fi-reconhecer', 'reconhecer o incidente'],

  // ---------------------------------------------------------------- cadastro
  ['btn-adicionar', 'cadastrar um PC novo'],
  ['modal-add', 'o passo a passo do cadastro'],
  ['add-comando', 'o comando de instalação para copiar'],

  // --------------------------------------------------------------- relatório
  ['btn-relatorio', 'abrir o relatório mensal'],
  ['modal-relatorio', 'o relatório'],

  // ------------------------------------------------------------------- geral
  ['btn-tema', 'alternar tema claro e escuro'],
  ['btn-som', 'ligar o som de alerta'],
  ['faixa-demo', 'a faixa de dados de demonstração'],
  ['btn-remover-demo', 'remover os dados de demonstração'],
  ['brinde', 'os avisos passageiros'],

  // ------------------------------------------------------- paleta de comandos
  ['paleta', 'a paleta de comandos (Ctrl K)'],
  ['paleta-busca', 'o campo de busca da paleta'],
  ['paleta-lista', 'os resultados da paleta'],

  // ------------------------------------------------------ atualizar a frota
  ['btn-atualizar-agentes', 'atualizar os agentes de toda a frota'],
  ['modal-atualizar', 'o resultado da atualização de frota'],
  ['atualizar-resumo', 'quantas máquinas vão se atualizar'],
  ['atualizar-lista', 'quais máquinas ainda precisam de visita'],
];

/**
 * Comportamentos que não são um id, e que também não podem sumir.
 *
 * Estes são os que doem mais quando somem, porque não deixam buraco visível na
 * tela — a pessoa só descobre quando aperta e nada acontece.
 */
const COMPORTAMENTOS = [
  ['armarPerigo', 'a confirmação em dois cliques da ação destrutiva'],
  ['enfileirar_comando', 'a chamada que enfileira uma ação remota'],
  ['cancelar_comando', 'cancelar um comando ainda na fila'],
  ['ligar_maquina', 'a chamada de Wake-on-LAN pelo vizinho'],
  ['agendar_reinicio', 'o reinício agendado no fuso da loja'],
  ['reconhecer_alerta', 'reconhecer um alerta'],
  ['remover_maquina_ui', 'a remoção da máquina'],
  ['acoes_da_maquina', 'o servidor dizendo o que pode ser oferecido'],
  ['refletirModoSimulacao', 'o rótulo do botão dizer que vai simular'],
  ['ligarPaleta', 'Ctrl K abre a paleta'],
];

let passou = 0; const falhas = [];

console.log('\n== controles da interface ==');
for (const [id, oQueFaz] of CONTROLES) {
  const existe = html.includes(`id="${id}"`);
  if (existe) { passou++; }
  else {
    falhas.push(`${id} — ${oQueFaz}`);
    console.log(`  SUMIU  ${id}\n         era: ${oQueFaz}`);
  }
}
console.log(`  ${passou} de ${CONTROLES.length} controles presentes`);

console.log('\n== comportamentos ==');
let passouC = 0;
for (const [marca, oQueFaz] of COMPORTAMENTOS) {
  if (js.includes(marca)) { passouC++; }
  else {
    falhas.push(`${marca} — ${oQueFaz}`);
    console.log(`  SUMIU  ${marca}\n         era: ${oQueFaz}`);
  }
}
console.log(`  ${passouC} de ${COMPORTAMENTOS.length} comportamentos presentes`);

if (falhas.length === 0) {
  console.log('\nNada sumiu. Pode publicar.');
} else {
  console.log(`\n${falhas.length} FUNÇÃO(ÕES) SUMIU(RAM):`);
  falhas.forEach((f) => console.log(`  - ${f}`));
  console.log('\nSe a remoção foi de propósito, apague a linha correspondente');
  console.log('neste arquivo NO MESMO COMMIT, com o motivo na mensagem.');
  process.exit(1);
}
