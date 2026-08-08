// =============================================================================
// Estrutura — a raiz, a navegacao e as superficies
// =============================================================================

import * as React from 'react';
import { Botao, Ponto, type Tom } from './primitivos';

const juntar = (...cs: Array<string | false | null | undefined>) =>
  cs.filter(Boolean).join(' ');

// -----------------------------------------------------------------------------
// Sentinela (raiz)
// -----------------------------------------------------------------------------

export interface SentinelaProps {
  /**
   * Tema. O escuro e o padrao: este painel foi feito para ficar aberto o turno
   * inteiro, muitas vezes numa TV de sala tecnica.
   */
  tema?: 'escuro' | 'claro';
  /** A malha de fundo. Decorativa; desligue quando embutir em outra pagina. */
  malha?: boolean;
  children?: React.ReactNode;
  className?: string;
}

/**
 * Raiz do sistema. **Envolva tudo nela.**
 *
 * E ela que fixa `data-tema` e o fundo, e sem isso os componentes herdam a cor
 * da pagina hospedeira e o contraste some — botao cinza sobre cinza, numero
 * ilegivel. O tema claro do sistema inteiro sai daqui, trocando UMA
 * propriedade: todas as cores sao variaveis CSS.
 */
export function Sentinela({ tema = 'escuro', malha = true, children, className }: SentinelaProps) {
  return (
    <div
      data-tema={tema === 'claro' ? 'light' : 'dark'}
      className={juntar('sentinela-raiz', className)}
      style={{
        background: 'var(--bg)',
        color: 'var(--fg)',
        font: '13px/1.5 var(--fonte)',
        position: 'relative',
        minHeight: '100%',
      }}
    >
      {malha && <div className="malha" aria-hidden="true" />}
      <div style={{ position: 'relative', zIndex: 1 }}>{children}</div>
    </div>
  );
}

// -----------------------------------------------------------------------------
// Vista (navegacao)
// -----------------------------------------------------------------------------

export interface VistaProps {
  rotulo: string;
  /** Quantas maquinas este filtro vai mostrar. */
  contagem?: React.ReactNode;
  tom?: Tom;
  ativa?: boolean;
  icone?: React.ReactNode;
  onClick?: () => void;
  className?: string;
}

/**
 * Item da barra lateral.
 *
 * Cada um e um FILTRO real com a contagem do que vai mostrar — nao um destino
 * de navegacao. Este sistema tem uma tela so, e link morto seria tao ruim
 * quanto numero inventado.
 */
export function Vista({
  rotulo, contagem, tom = 'neutro', ativa = false, icone, onClick, className,
}: VistaProps) {
  const zero = contagem === 0 || contagem === '0';
  return (
    <button
      type="button"
      className={juntar('vista', ativa && 'ativa', className)}
      onClick={onClick}
    >
      {icone}
      <span className="vista-rot">{rotulo}</span>
      {contagem !== undefined && (
        <span
          className={juntar(
            'vista-num', 'mono',
            tom === 'alerta' && 'alerta',
            tom === 'ruim' && 'ruim',
            zero && 'zero',
          )}
        >
          {contagem}
        </span>
      )}
    </button>
  );
}

// -----------------------------------------------------------------------------
// Segmentado
// -----------------------------------------------------------------------------

export interface OpcaoSegmento {
  valor: string;
  rotulo: string;
}

export interface SegmentadoProps {
  opcoes: OpcaoSegmento[];
  valor: string;
  onChange?: (valor: string) => void;
  className?: string;
}

/** Alternador curto: faixa de tempo, modo de agrupamento. */
export function Segmentado({ opcoes, valor, onChange, className }: SegmentadoProps) {
  return (
    <div className={juntar('segmentado', className)} role="tablist">
      {opcoes.map((o) => (
        <button
          key={o.valor}
          type="button"
          role="tab"
          aria-selected={o.valor === valor}
          className={juntar('seg', o.valor === valor && 'ativa')}
          onClick={() => onChange?.(o.valor)}
        >
          {o.rotulo}
        </button>
      ))}
    </div>
  );
}

// -----------------------------------------------------------------------------
// Painel (gaveta lateral)
// -----------------------------------------------------------------------------

export interface PainelProps {
  titulo: string;
  /** Segunda linha: loja, marca, codigo. */
  sub?: string;
  aberto?: boolean;
  onFechar?: () => void;
  children?: React.ReactNode;
  className?: string;
}

/**
 * Gaveta de detalhe, que entra pela direita.
 *
 * Gaveta e nao pagina de proposito: quem investiga uma maquina nao quer perder
 * a grade de vista — o contexto de "e so essa ou a loja inteira?" continua
 * atras.
 */
export function Painel({ titulo, sub, aberto = true, onFechar, children, className }: PainelProps) {
  if (!aberto) return null;
  return (
    <>
      <div className="cortina" onClick={onFechar} />
      <aside className={juntar('painel', className)} aria-label={`Detalhe de ${titulo}`}>
        <header className="painel-topo">
          <div>
            <h2>{titulo}</h2>
            {sub && <p className="painel-sub mono">{sub}</p>}
          </div>
          <button type="button" className="btn-fechar" aria-label="Fechar" onClick={onFechar}>
            &times;
          </button>
        </header>
        <div className="painel-corpo">{children}</div>
      </aside>
    </>
  );
}

// -----------------------------------------------------------------------------
// Ficha de dados
// -----------------------------------------------------------------------------

export interface LinhaFicha {
  rotulo: string;
  valor: React.ReactNode;
}

export interface FichaProps {
  linhas: LinhaFicha[];
  className?: string;
}

/**
 * Lista de rotulo e valor do painel de detalhe.
 *
 * Campo sem dado mostra travessao, nunca some: uma ficha que encolhe esconde
 * que algo deixou de ser reportado.
 */
export function Ficha({ linhas, className }: FichaProps) {
  return (
    <dl className={juntar('dados', className)}>
      {linhas.map((l) => (
        <React.Fragment key={l.rotulo}>
          <dt>{l.rotulo}</dt>
          <dd>{l.valor === null || l.valor === undefined || l.valor === '' ? '—' : l.valor}</dd>
        </React.Fragment>
      ))}
    </dl>
  );
}

// -----------------------------------------------------------------------------
// Modal
// -----------------------------------------------------------------------------

export interface ModalProps {
  titulo: string;
  aberto?: boolean;
  /** Para conteudo tabular, como o relatorio mensal. */
  largo?: boolean;
  onFechar?: () => void;
  children?: React.ReactNode;
  className?: string;
}

/** Caixa central, para o que interrompe o fluxo: cadastrar PC, ver relatorio. */
export function Modal({ titulo, aberto = true, largo = false, onFechar, children, className }: ModalProps) {
  if (!aberto) return null;
  return (
    <>
      <div className="cortina" onClick={onFechar} />
      <div
        className={juntar('modal', largo && 'modal-largo', className)}
        role="dialog"
        aria-modal="true"
        aria-label={titulo}
      >
        <header className="modal-topo">
          <h2>{titulo}</h2>
          <button type="button" className="btn-fechar" aria-label="Fechar" onClick={onFechar}>
            &times;
          </button>
        </header>
        <div className="modal-corpo">{children}</div>
      </div>
    </>
  );
}

// -----------------------------------------------------------------------------
// Caixa de comando
// -----------------------------------------------------------------------------

export interface CaixaComandoProps {
  /** O comando a copiar. Vai em monoespacada, quebrando em qualquer ponto. */
  comando: string;
  onCopiar?: () => void;
  className?: string;
}

/**
 * Bloco de um comando para colar no terminal da loja.
 *
 * O texto quebra em qualquer ponto porque um comando de instalacao tem token e
 * URL longos, e cortar no fim esconderia justamente a parte que muda.
 */
export function CaixaComando({ comando, onCopiar, className }: CaixaComandoProps) {
  return (
    <div className={juntar('comando-caixa', className)}>
      <code className="mono">{comando}</code>
      <Botao variante="secundario" onClick={onCopiar}>Copiar</Botao>
    </div>
  );
}

// -----------------------------------------------------------------------------
// Marca
// -----------------------------------------------------------------------------

export interface MarcaProps {
  /** Escopo atual. Ex.: "12 lojas · 47 máquinas" */
  escopo?: string;
  className?: string;
}

/** Selo do produto, no topo da barra lateral. */
export function Marca({ escopo, className }: MarcaProps) {
  return (
    <div className={juntar('marca-app', className)}>
      <div className="marca-selo" aria-hidden="true">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2"
             strokeLinecap="round" strokeLinejoin="round">
          <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z" />
          <path d="m9 12 2 2 4-4" />
        </svg>
      </div>
      <div className="marca-texto">
        <span className="marca-nome-app">Sentinela</span>
        {escopo && <span className="mono etiqueta-micro">{escopo}</span>}
      </div>
    </div>
  );
}
