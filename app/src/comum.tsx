// =============================================================================
// Peças que o handoff pede e a biblioteca ainda não cobre
// =============================================================================
// O handoff é explícito: onde a biblioteca não alcança — paleta ⌘K, tabela densa
// da frota, linha do tempo, tabelas de inventário e auditoria — construir com
// `style` + variáveis CSS, na mesma densidade. É o que está aqui.
//
// Nada neste arquivo escreve cor literal: tudo sai de `var(--*)`, senão o tema
// claro quebraria em metade da interface.
// =============================================================================

import * as React from 'react';
import { Botao } from '@cajupar/sentinela-ds';
import type { Ausencia } from './api';

// -----------------------------------------------------------------------------
// SemDado
// -----------------------------------------------------------------------------

/**
 * A faixa que uma tela mostra quando o dado dela ainda não é coletado.
 *
 * ESTA É A ALTERNATIVA A INVENTAR NÚMERO, e a razão de ela existir é simples:
 * um painel de operação que mostra "312 cupons no spool" para um sistema que
 * nunca contou cupom nenhum treina a pessoa a não confiar em NENHUM número da
 * tela — inclusive nos que estão certos.
 *
 * Então a tela mostra o layout, e diz em voz alta o que falta e por quê. Quem
 * abrir entende o que vai ver quando a coleta existir, e não é enganado
 * enquanto isso.
 */
export function SemDado({ ausencia, children }: { ausencia: Ausencia; children?: React.ReactNode }) {
  return (
    <div
      style={{
        display: 'flex', gap: 12, alignItems: 'flex-start',
        padding: '14px 16px', marginBottom: 16,
        borderRadius: 'var(--r-m)',
        background: 'color-mix(in srgb, var(--warn) 8%, transparent)',
        border: '1px solid color-mix(in srgb, var(--warn) 26%, transparent)',
      }}
      role="status"
    >
      <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="var(--warn)"
           strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"
           style={{ flex: '0 0 auto', marginTop: 1 }}>
        <circle cx="12" cy="12" r="9" /><path d="M12 8v5" /><path d="M12 16h.01" />
      </svg>
      <div style={{ minWidth: 0 }}>
        <div style={{ fontSize: 12.5, fontWeight: 700, color: 'var(--warn)', marginBottom: 3 }}>
          {ausencia.o_que} — sem coleta ainda
        </div>
        <p style={{ margin: 0, fontSize: 11.5, color: 'var(--fg2)', textWrap: 'pretty' }}>
          {ausencia.porque}
        </p>
        <p style={{ margin: '5px 0 0', fontSize: 11, color: 'var(--fg3)', textWrap: 'pretty' }}>
          <strong style={{ color: 'var(--fg2)' }}>Falta:</strong> {ausencia.falta}
        </p>
        {children}
      </div>
    </div>
  );
}

// -----------------------------------------------------------------------------
// Painel
// -----------------------------------------------------------------------------

export function Bloco({
  titulo, sub, acoes, children, style,
}: {
  titulo?: string; sub?: string; acoes?: React.ReactNode;
  children?: React.ReactNode; style?: React.CSSProperties;
}) {
  return (
    <section
      style={{
        background: 'var(--pnl)', border: '1px solid var(--bd)',
        borderRadius: 'var(--r-g)', padding: '16px 18px', minWidth: 0, ...style,
      }}
    >
      {(titulo || acoes) && (
        <header style={{ display: 'flex', alignItems: 'baseline', gap: 10, marginBottom: sub ? 2 : 12 }}>
          {titulo && (
            <h2 style={{ margin: 0, fontSize: 13.5, fontWeight: 700, letterSpacing: '-.01em' }}>
              {titulo}
            </h2>
          )}
          <div style={{ marginLeft: 'auto', display: 'flex', gap: 8, alignItems: 'center' }}>{acoes}</div>
        </header>
      )}
      {sub && <p style={{ margin: '0 0 12px', fontSize: 11, color: 'var(--fg2)' }}>{sub}</p>}
      {children}
    </section>
  );
}

// -----------------------------------------------------------------------------
// Tabela densa
// -----------------------------------------------------------------------------

export interface Coluna<T> {
  chave: string;
  rotulo: string;
  largura: string;
  /** Cabeçalho vira botão de ordenação quando isto existe. */
  ordena?: boolean;
  alinhaDireita?: boolean;
  render: (linha: T) => React.ReactNode;
}

/**
 * A tabela da frota — 30px por linha, mono nos números.
 *
 * Densidade é o ponto: quem opera precisa ver 60 máquinas sem rolar. Linha alta
 * é confortável para ler cinco itens e inútil para varrer duzentos.
 */
export function Tabela<T>({
  colunas, linhas, chaveDe, ordem, onOrdenar, onAbrir, vazio = 'Nada aqui.',
}: {
  colunas: Coluna<T>[];
  linhas: T[];
  chaveDe: (l: T) => string;
  ordem?: string;
  onOrdenar?: (chave: string) => void;
  onAbrir?: (l: T) => void;
  vazio?: string;
}) {
  const grade = colunas.map((c) => c.largura).join(' ');

  return (
    <div style={{ overflowX: 'auto' }}>
      <div style={{ minWidth: 780 }}>
        <div
          style={{
            display: 'grid', gridTemplateColumns: grade,
            background: 'var(--pnl2)', borderRadius: 'var(--r-p)',
            padding: '6px 14px', marginBottom: 2,
          }}
        >
          {colunas.map((c) => (
            <button
              key={c.chave}
              type="button"
              disabled={!c.ordena}
              onClick={c.ordena && onOrdenar ? () => onOrdenar(c.chave) : undefined}
              style={{
                all: 'unset',
                cursor: c.ordena ? 'pointer' : 'default',
                fontFamily: 'var(--mono)', fontSize: 8.5, letterSpacing: '.13em',
                textTransform: 'uppercase',
                color: ordem === c.chave ? 'var(--fg)' : 'var(--fg3)',
                textAlign: c.alinhaDireita ? 'right' : 'left',
                whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
              }}
            >
              {c.rotulo}{ordem === c.chave ? ' ↓' : ''}
            </button>
          ))}
        </div>

        {linhas.length === 0 && (
          <div style={{ padding: '22px 14px', fontSize: 11.5, color: 'var(--fg3)' }}>{vazio}</div>
        )}

        {linhas.map((l) => (
          <div
            key={chaveDe(l)}
            data-linha={chaveDe(l)}
            onClick={onAbrir ? () => onAbrir(l) : undefined}
            style={{
              display: 'grid', gridTemplateColumns: grade, alignItems: 'center',
              padding: '7px 14px', borderBottom: '1px solid var(--bd2)',
              cursor: onAbrir ? 'pointer' : 'default', minHeight: 30,
              transition: 'background .13s ease',
            }}
            onMouseEnter={(e) => { e.currentTarget.style.background = 'var(--hov)'; }}
            onMouseLeave={(e) => { e.currentTarget.style.background = 'transparent'; }}
          >
            {colunas.map((c) => (
              <div
                key={c.chave}
                style={{
                  minWidth: 0, fontSize: 11.5,
                  textAlign: c.alinhaDireita ? 'right' : 'left',
                  whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
                }}
              >
                {c.render(l)}
              </div>
            ))}
          </div>
        ))}
      </div>
    </div>
  );
}

// -----------------------------------------------------------------------------
// Chip de faceta
// -----------------------------------------------------------------------------

export function Faceta({
  rotulo, contagem, ativo, onClick,
}: { rotulo: string; contagem?: number; ativo?: boolean; onClick?: () => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      style={{
        display: 'inline-flex', alignItems: 'center', gap: 6,
        padding: '6px 11px', borderRadius: 'var(--r-p)',
        border: `1px solid ${ativo ? 'color-mix(in srgb, var(--info) 40%, transparent)' : 'var(--bd)'}`,
        background: ativo ? 'color-mix(in srgb, var(--info) 12%, transparent)' : 'transparent',
        color: ativo ? 'var(--info)' : 'var(--fg2)',
        fontFamily: 'var(--fonte)', fontSize: 11.5, cursor: 'pointer',
        transition: 'background .13s ease, color .13s ease, border-color .13s ease',
      }}
    >
      {rotulo}
      {contagem !== undefined && (
        <span className="mono" style={{ fontSize: 9.5, opacity: .6 }}>{contagem}</span>
      )}
    </button>
  );
}

// -----------------------------------------------------------------------------
// Valor
// -----------------------------------------------------------------------------

/**
 * Um número medido — ou um travessão.
 *
 * O travessão não é enfeite: ele distingue "medimos zero" de "não medimos". Um
 * disco em 0% livre e um disco que não reportou são situações opostas, e mostrar
 * "0%" para as duas esconde exatamente a que é urgente.
 */
export function Valor({
  n, sufixo = '', casas = 0, tom,
}: { n: number | null | undefined; sufixo?: string; casas?: number; tom?: string }) {
  if (n === null || n === undefined || Number.isNaN(n)) {
    return <span className="mono" style={{ color: 'var(--fg3)' }}>—</span>;
  }
  return (
    <span className="mono" style={{ color: tom }}>
      {n.toFixed(casas)}{sufixo}
    </span>
  );
}

export function tomDoPercentual(n: number | null, limiar = 85, critico = 95): string | undefined {
  if (n === null) return undefined;
  if (n >= critico) return 'var(--crit)';
  if (n >= limiar) return 'var(--warn)';
  return undefined;
}

export function tomDoDisco(livre: number | null): string | undefined {
  if (livre === null) return undefined;
  if (livre <= 5) return 'var(--crit)';
  if (livre <= 15) return 'var(--warn)';
  return undefined;
}

// -----------------------------------------------------------------------------
// Utilidades de tempo
// -----------------------------------------------------------------------------

export function desdeQuando(segundos: number | null | undefined): string {
  if (segundos === null || segundos === undefined) return 'nunca';
  if (segundos < 90) return `há ${Math.round(segundos)}s`;
  if (segundos < 5400) return `há ${Math.round(segundos / 60)} min`;
  if (segundos < 172800) return `há ${Math.round(segundos / 3600)} h`;
  return `há ${Math.round(segundos / 86400)} dias`;
}

export function uptime(segundos: number | null | undefined): string {
  if (!segundos) return '—';
  const d = Math.floor(segundos / 86400);
  const h = Math.floor((segundos % 86400) / 3600);
  const m = Math.floor((segundos % 3600) / 60);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

export const hora = (iso: string | null) =>
  iso ? new Date(iso).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' }) : '—';

export const dataHora = (iso: string | null) =>
  iso ? new Date(iso).toLocaleString('pt-BR', {
    day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit',
  }) : '—';

// -----------------------------------------------------------------------------
// Erro
// -----------------------------------------------------------------------------

export function Erro({ msg, onTentar }: { msg: string; onTentar?: () => void }) {
  return (
    <div
      style={{
        padding: '14px 16px', borderRadius: 'var(--r-m)',
        background: 'color-mix(in srgb, var(--crit) 8%, transparent)',
        border: '1px solid color-mix(in srgb, var(--crit) 26%, transparent)',
        display: 'flex', alignItems: 'center', gap: 12,
      }}
    >
      <div style={{ minWidth: 0, flex: 1 }}>
        <div style={{ fontSize: 12.5, fontWeight: 700, color: 'var(--crit)' }}>
          Não consegui carregar
        </div>
        <p style={{ margin: '3px 0 0', fontSize: 11.5, color: 'var(--fg2)' }}>{msg}</p>
      </div>
      {onTentar && <Botao variante="secundario" onClick={onTentar}>Tentar de novo</Botao>}
    </div>
  );
}
