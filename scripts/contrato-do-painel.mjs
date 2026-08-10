// =============================================================================
// O contrato do painel
// =============================================================================
// A lista do que o painel FAZ, separada de quem confere. Existem duas
// conferencias sobre ela e elas precisam olhar a mesma lista:
//
//   verificar-nada-sumiu.mjs   le os arquivos e procura o id no HTML
//   verificar-painel-vivo.mjs  abre o navegador e procura o id no DOM montado
//
// Duas copias da lista viveriam divergindo, e a que ficasse para tras passaria
// a aprovar o que a outra reprova. Fonte unica, como o timeout de offline no
// banco.
//
// Para acrescentar uma funcao nova: acrescente a linha aqui.
// Para REMOVER uma de proposito: remova a linha aqui, no mesmo commit, e diga
// no commit por que ela deixou de existir. O que nao pode e sumir calado.
// =============================================================================

/**
 * Cada linha: [id do elemento, o que ele faz].
 *
 * O id é o contrato — o texto do botão e a cor podem mudar à vontade numa
 * melhoria de interface, o id não. É por isso que a trava é por id.
 */
export const CONTROLES = [
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

  // ---------------------------------------------------------------- sessão
  ['btn-sair', 'sair da sessão'],
  ['rotulo-usuario', 'quem está logado'],
  ['usuario-papel', 'com qual papel'],
];

/**
 * Comportamentos que não são um id, e que também não podem sumir.
 *
 * Estes são os que doem mais quando somem, porque não deixam buraco visível na
 * tela — a pessoa só descobre quando aperta e nada acontece.
 */
export const COMPORTAMENTOS = [
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
