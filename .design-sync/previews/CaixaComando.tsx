// CaixaComando — o comando de uma linha para colar no terminal da loja.
import * as React from 'react';
import { CaixaComando } from '@cajupar/sentinela-ds';

const INSTALAR =
  "& ([scriptblock]::Create((irm 'https://zrdglshzhlflnakflnki.supabase.co/functions/v1/ingest/instalar.ps1'))) " +
  "-Servidor 'https://zrdglshzhlflnakflnki.supabase.co/functions/v1/ingest' -Token 'mon_a1b2c3d4e5f6a7b8c9d0' -Servicos 'Spooler,Dhcp'";

/**
 * O comando de instalacao, do tamanho que ele tem de verdade.
 *
 * O texto quebra em QUALQUER ponto de proposito: token e URL sao longos, e
 * cortar no fim esconderia justamente a parte que muda de loja para loja.
 */
export const ComandoDeInstalacao = () => (
  <div style={{ maxWidth: 520 }}>
    <CaixaComando comando={INSTALAR} />
  </div>
);

/** Um comando curto, para comparar. */
export const ComandoCurto = () => (
  <div style={{ maxWidth: 520 }}>
    <CaixaComando comando="node scripts/verificar-comandos.mjs" />
  </div>
);
