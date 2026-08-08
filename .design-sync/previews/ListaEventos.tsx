// ListaEventos — o recipiente do historico.
import * as React from 'react';
import { ListaEventos, Evento } from '@cajupar/sentinela-ds';

/** Com conteudo. */
export const ComEventos = () => (
  <div style={{ maxWidth: 620 }}>
    <ListaEventos>
      <Evento tipo="alert_recovered" quando="14:02" mensagem="PDV 02 voltou a responder" />
      <Evento tipo="command_result" quando="13:58"
              mensagem="comando run_test_collection em PDV 01: sucesso" />
      <Evento tipo="rollup_run" quando="13:07" mensagem="consolidação horária: 2.184 amostras" />
    </ListaEventos>
  </div>
);

/** Vazia, com o motivo escrito. */
export const Vazia = () => (
  <div style={{ maxWidth: 620 }}>
    <ListaEventos vazio="Nenhum evento nas últimas 24 h." />
  </div>
);
