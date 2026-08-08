// =============================================================================
// Operacao — o que aparece quando algo esta acontecendo
// =============================================================================
// Estes sao os componentes que existem por causa de um turno ruim: a faixa que
// nao deixa passar batido, a lista de eventos, o historico do que foi mandado
// para a maquina. Nenhum deles enfeita nada.
// =============================================================================

import * as React from 'react';
import { Botao, type Tom } from './primitivos';

const juntar = (...cs: Array<string | false | null | undefined>) =>
  cs.filter(Boolean).join(' ');

// -----------------------------------------------------------------------------
// Faixa de incidente
// -----------------------------------------------------------------------------

export interface FaixaIncidenteProps {
  titulo: string;
  /** O que esta errado, em uma linha. */
  descricao?: string;
  /** Loja, maquina, ha quanto tempo. */
  tags?: string[];
  quando?: string;
  /** `critical` pulsa. Use com parcimonia: tudo pulsando e nada pulsando. */
  severidade?: 'warning' | 'critical';
  onReconhecer?: () => void;
  onAbrir?: () => void;
  className?: string;
}

/**
 * Faixa fixa no topo, para o incidente aberto mais grave.
 *
 * Existe porque notificacao externa nao resolve o caso real: quem opera esta
 * OLHANDO a tela. O aviso tem que competir com o resto da tela, e ganhar.
 */
export function FaixaIncidente({
  titulo, descricao, tags = [], quando, severidade = 'critical',
  onReconhecer, onAbrir, className,
}: FaixaIncidenteProps) {
  return (
    <div
      className={juntar('faixa-incidente', severidade === 'critical' ? 'if-crit' : 'if-alerta', className)}
      role="status"
    >
      <span className="if-icone" aria-hidden="true">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2"
             strokeLinecap="round" strokeLinejoin="round" width="18" height="18">
          <path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z" />
          <path d="M12 9v4" />
          <path d="M12 17h.01" />
        </svg>
      </span>

      <div className="if-corpo">
        <div className="if-titulo">{titulo}</div>
        {descricao && <div className="if-desc">{descricao}</div>}
        {tags.length > 0 && (
          <div className="if-tags">
            {tags.map((t) => <span className="if-tag mono" key={t}>{t}</span>)}
          </div>
        )}
      </div>

      {quando && <span className="if-quando mono">{quando}</span>}

      {onAbrir && <Botao variante="secundario" onClick={onAbrir}>Abrir</Botao>}
      {onReconhecer && (
        <Botao variante="perigo" onClick={onReconhecer}>Reconhecer</Botao>
      )}
    </div>
  );
}

// -----------------------------------------------------------------------------
// Evento
// -----------------------------------------------------------------------------

export interface EventoProps {
  /** Tipo cru do banco. Ex.: alert_open, command_result */
  tipo: string;
  mensagem: string;
  quando: string;
  severidade?: 'info' | 'warning' | 'critical';
  className?: string;
}

/**
 * Uma linha do historico da maquina.
 *
 * O tipo fica em monoespacada e cru de proposito: e o mesmo texto que esta no
 * banco, e quem investiga precisa procurar por ele.
 */
export function Evento({ tipo, mensagem, quando, severidade = 'info', className }: EventoProps) {
  return (
    <li
      className={juntar(
        'evento',
        severidade === 'warning' && 'evento-warning',
        severidade === 'critical' && 'evento-critical',
        className,
      )}
    >
      <span className="evento-quando mono">{quando}</span>
      <span className="evento-tipo mono">{tipo}</span>
      <span className="evento-msg">{mensagem}</span>
    </li>
  );
}

export interface ListaEventosProps {
  children?: React.ReactNode;
  /** Texto quando nao ha nada. Lista vazia sem explicacao parece defeito. */
  vazio?: string;
  className?: string;
}

/** Lista de eventos. Diz quando esta vazia. */
export function ListaEventos({ children, vazio = 'Nenhum evento.', className }: ListaEventosProps) {
  const temFilho = React.Children.count(children) > 0;
  return (
    <ul className={juntar('eventos', className)}>
      {temFilho ? children : <li className="evento-vazio">{vazio}</li>}
    </ul>
  );
}

// -----------------------------------------------------------------------------
// Comando
// -----------------------------------------------------------------------------

export type EstadoComando =
  | 'pending' | 'sent' | 'acked' | 'succeeded' | 'failed' | 'expired' | 'canceled';

export interface ComandoProps {
  /** Nome legivel da acao. Ex.: "Reiniciar serviço" */
  acao: string;
  estado: EstadoComando;
  quando: string;
  /**
   * Simulacao. O rotulo diz, e a listagem tambem: um dry-run que se parece com
   * execucao real ensina a nao confiar na simulacao.
   */
  simulacao?: boolean;
  /** Saida do agente. Pode ser longa e ter caminho de arquivo. */
  resultado?: string;
  /** So faz sentido enquanto o comando ainda esta na fila. */
  onCancelar?: () => void;
  className?: string;
}

const ROTULO_ESTADO_CMD: Record<EstadoComando, string> = {
  pending: 'na fila',
  sent: 'entregue',
  acked: 'em execução',
  succeeded: 'concluído',
  failed: 'falhou',
  expired: 'expirou',
  canceled: 'cancelado',
};

/**
 * Uma linha do historico de acao remota.
 *
 * A barra da esquerda carrega o estado: da para varrer a lista sem ler.
 */
export function Comando({
  acao, estado, quando, simulacao = false, resultado, onCancelar, className,
}: ComandoProps) {
  return (
    <li className={juntar('comando', `cmd-${estado}`, className)}>
      <div className="cmd-topo">
        <strong>{acao}{simulacao ? ' (simulação)' : ''}</strong>
        <span className="cmd-estado">{ROTULO_ESTADO_CMD[estado]}</span>
      </div>
      <div className="cmd-quando">{quando}</div>
      {resultado && <div className="cmd-texto">{resultado}</div>}
      {onCancelar && estado === 'pending' && (
        <button type="button" className="btn-mini" onClick={onCancelar}>Cancelar</button>
      )}
    </li>
  );
}

// -----------------------------------------------------------------------------
// Item da fila de atencao
// -----------------------------------------------------------------------------

export interface ItemFilaProps {
  titulo: string;
  detalhe: string;
  tom?: Tom;
  onClick?: () => void;
  className?: string;
}

/**
 * Uma linha da fila de atencao — a lista do que precisa de alguem agora,
 * ordenada por gravidade.
 */
export function ItemFila({ titulo, detalhe, tom = 'alerta', onClick, className }: ItemFilaProps) {
  return (
    <li className={juntar('item-fila', className)} onClick={onClick}>
      <span
        className="fi-sinal"
        style={{
          background: tom === 'ruim' ? 'var(--crit)'
            : tom === 'alerta' ? 'var(--warn)'
            : 'var(--ok)',
        }}
        aria-hidden="true"
      />
      <span className="fi-texto">{titulo}</span>
      <span className="fi-detalhe mono">{detalhe}</span>
    </li>
  );
}

// -----------------------------------------------------------------------------
// Brinde (aviso passageiro)
// -----------------------------------------------------------------------------

export interface BrindeProps {
  mensagem: string;
  erro?: boolean;
  className?: string;
}

/** Aviso passageiro de canto. Erro fica mais tempo e muda de cor. */
export function Brinde({ mensagem, erro = false, className }: BrindeProps) {
  return (
    <div className={juntar('brinde', erro && 'brinde-erro', className)} role="status">
      {mensagem}
    </div>
  );
}

// -----------------------------------------------------------------------------
// Zona de perigo
// -----------------------------------------------------------------------------

export interface ZonaPerigoProps {
  titulo: string;
  /** Diga o que se perde. "Nao ha como desfazer" e informacao, nao enfeite. */
  aviso: string;
  children?: React.ReactNode;
  className?: string;
}

/**
 * Bloco separado, no fim, para o que nao tem volta.
 *
 * Fica longe do uso rotineiro de proposito: um botao que apaga historico nao
 * pode ficar ao lado de um que so atualiza a tela.
 */
export function ZonaPerigo({ titulo, aviso, children, className }: ZonaPerigoProps) {
  return (
    <section className={juntar('zona-perigo', className)}>
      <h3>{titulo}</h3>
      <p className="dica">{aviso}</p>
      {children}
    </section>
  );
}
