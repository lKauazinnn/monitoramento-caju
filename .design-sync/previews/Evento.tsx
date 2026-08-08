// Evento — uma linha do historico da maquina.
import * as React from 'react';
import { Evento, ListaEventos } from '@cajupar/sentinela-ds';

/**
 * O historico como ele aparece no painel de detalhe.
 *
 * O tipo fica em monoespacada e CRU (`alert_open`, nao "Alerta aberto") de
 * proposito: e o mesmo texto que esta no banco, e quem investiga um incidente
 * procura por ele.
 */
export const HistoricoDeUmaMaquina = () => (
  <div style={{ maxWidth: 620 }}>
    <ListaEventos>
      <Evento tipo="alert_open" quando="13:20" severidade="critical"
              mensagem="PDV 02: sem contato há 14 min" />
      <Evento tipo="command_result" quando="13:36" severidade="warning"
              mensagem="comando restart_service em PDV 02: FALHOU" />
      <Evento tipo="command_queued" quando="13:34"
              mensagem="comando restart_service enfileirado para PDV 02" />
      <Evento tipo="machine_first_seen" quando="11:02"
              mensagem="primeiro contato do agente ps-1.3.1 (host DESKTOP-K7N6IMC)" />
    </ListaEventos>
  </div>
);

/**
 * Lista vazia DIZ que esta vazia.
 *
 * Uma lista em branco sem explicacao parece defeito de carregamento, e a
 * pessoa fica esperando por algo que nunca vem.
 */
export const SemEventos = () => (
  <div style={{ maxWidth: 620 }}>
    <ListaEventos vazio="Nenhum evento nas últimas 24 h." />
  </div>
);
