// ZonaPerigo — o bloco separado do que nao tem volta.
import * as React from 'react';
import { ZonaPerigo, Botao } from '@cajupar/sentinela-ds';

/**
 * Fica no FIM do painel, longe do uso rotineiro.
 *
 * Um botao que apaga historico nao pode ficar ao lado de um que so atualiza a
 * tela — e o aviso diz o que se perde, porque "esta acao e irreversivel" nao
 * informa nada sobre o que sera perdido.
 */
export const RemoverMaquina = () => (
  <div style={{ maxWidth: 460 }}>
    <ZonaPerigo
      titulo="Remover esta máquina"
      aviso="Apaga o cadastro e todo o histórico dela: métricas, discos, serviços, tokens e eventos. Não há como desfazer. Para apenas parar de monitorar sem perder o histórico, desative a máquina."
    >
      <Botao variante="perigo" largo>Remover máquina</Botao>
    </ZonaPerigo>
  </div>
);

/** A versao da loja inteira, que leva as maquinas junto. */
export const RemoverLoja = () => (
  <div style={{ maxWidth: 460 }}>
    <ZonaPerigo
      titulo="Remover a loja BSB-004"
      aviso="Remove a loja e as 4 máquinas dela, com todo o histórico. A trilha de auditoria sobrevive, mas sem vínculo com a loja apagada."
    >
      <Botao variante="perigo" largo>Remover loja e máquinas</Botao>
    </ZonaPerigo>
  </div>
);
