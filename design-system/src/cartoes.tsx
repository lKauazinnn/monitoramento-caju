// =============================================================================
// Cartoes — como uma maquina e uma loja aparecem na grade
// =============================================================================
// A grade e a tela inicial do centro de operacoes, e ela responde uma pergunta
// so: "o que precisa de mim agora?". Por isso cada cartao carrega o estado na
// borda esquerda — da para varrer trinta lojas sem ler uma palavra.
// =============================================================================

import * as React from 'react';
import { Etiqueta, Ponto, Spark, type EstadoMaquina, type Tom } from './primitivos';

const juntar = (...cs: Array<string | false | null | undefined>) =>
  cs.filter(Boolean).join(' ');

// -----------------------------------------------------------------------------
// HostQuad
// -----------------------------------------------------------------------------

export interface HostQuadProps {
  /** Nome da maquina. Vira o aria-label — e como o teste a encontra. */
  rotulo: string;
  estado: EstadoMaquina;
  onClick?: () => void;
  className?: string;
}

/**
 * Quadradinho de uma maquina dentro do cartao da loja.
 *
 * E o mapa de calor da loja: vinte PDVs cabem num cartao, e um vermelho no meio
 * de verdes salta aos olhos sem precisar de lista.
 */
export function HostQuad({ rotulo, estado, onClick, className }: HostQuadProps) {
  return (
    <button
      type="button"
      className={juntar('host-quad', `hq-${estado}`, className)}
      aria-label={`${rotulo}, ${estado}`}
      onClick={onClick}
    />
  );
}

// -----------------------------------------------------------------------------
// Cartao de maquina
// -----------------------------------------------------------------------------

export interface MetricaCartao {
  rotulo: string;
  valor: React.ReactNode;
  tom?: Tom;
}

export interface CartaoProps {
  nome: string;
  /**
   * Estado DERIVADO, nao o cru. Uma maquina que responde mas esta com o Spooler
   * parado nao pode ficar verde ao lado de uma saudavel.
   */
  estado: EstadoMaquina;
  /** Loja / marca, na segunda linha. */
  contexto?: string;
  /** Ha quanto tempo teve contato. Ex.: "há 12s" */
  visto?: string;
  /** Ate quatro. Mais que isso vira ruido e a pessoa para de ler. */
  metricas?: MetricaCartao[];
  /** Ex.: "2 de 3 serviços" */
  servicos?: string;
  onClick?: () => void;
  className?: string;
}

/** Cartao de uma maquina na grade. */
export function Cartao({
  nome, estado, contexto, visto, metricas = [], servicos, onClick, className,
}: CartaoProps) {
  return (
    <article
      className={juntar('cartao', `cartao-${estado}`, className)}
      role="button"
      tabIndex={0}
      aria-label={`${nome}, ${estado}`}
      onClick={onClick}
    >
      <div className="cartao-topo">
        <span className="cartao-nome">{nome}</span>
        <Etiqueta estado={estado} />
      </div>

      {contexto && <div className="cartao-status">{contexto}</div>}

      {metricas.length > 0 && (
        <div className="metricas">
          {metricas.map((m) => (
            <div className="metrica" key={m.rotulo}>
              <span className="metrica-rot">{m.rotulo}</span>
              <span className={juntar('metrica-val', m.tom && m.tom !== 'neutro' && m.tom)}>
                {m.valor}
              </span>
            </div>
          ))}
        </div>
      )}

      <div className="cartao-pe">
        {servicos && <span className="cartao-servicos">{servicos}</span>}
        {visto && <span className="cartao-visto">{visto}</span>}
      </div>
    </article>
  );
}

// -----------------------------------------------------------------------------
// Cartao de loja
// -----------------------------------------------------------------------------

export type SituacaoLoja = 'estavel' | 'atencao' | 'incidente' | 'parada';

export interface HostDaLoja {
  rotulo: string;
  estado: EstadoMaquina;
}

export interface CelulaLoja {
  rotulo: string;
  valor: React.ReactNode;
  tom?: Tom;
}

export interface CartaoLojaProps {
  nome: string;
  /** Codigo curto da loja. Ex.: BSB-001 */
  codigo: string;
  /**
   * Situacao da loja inteira. `parada` e quando NENHUMA maquina responde — e
   * merece cor propria porque e diferente de "algumas com problema".
   */
  situacao: SituacaoLoja;
  /** Uma por maquina; vira o mapa de calor. */
  hosts: HostDaLoja[];
  /** Numeros do rodape: online, CPU media, disco. */
  celulas?: CelulaLoja[];
  onAbrirHost?: (rotulo: string) => void;
  className?: string;
}

const ROTULO_SITUACAO: Record<SituacaoLoja, string> = {
  estavel: 'estável',
  atencao: 'atenção',
  incidente: 'incidente',
  parada: 'parada',
};

/**
 * Cartao de uma loja, com o mapa de calor das maquinas dela.
 *
 * E a visao que a operacao usa de verdade: ninguem pensa em "maquina 47",
 * pensa em "a loja do Sudoeste esta ruim".
 */
export function CartaoLoja({
  nome, codigo, situacao, hosts, celulas = [], onAbrirHost, className,
}: CartaoLojaProps) {
  return (
    <article className={juntar('cartao-loja', `cl-${situacao}`, className)}>
      <div className="cl-cab">
        <div>
          <div className="cl-nome">{nome}</div>
          <div className="cl-meta mono">{codigo}</div>
        </div>
        <span className={juntar('cl-selo', `cl-selo-${situacao}`)}>
          {ROTULO_SITUACAO[situacao]}
        </span>
      </div>

      <div className="mapa-hosts">
        {hosts.map((h) => (
          <HostQuad
            key={h.rotulo}
            rotulo={h.rotulo}
            estado={h.estado}
            onClick={onAbrirHost ? () => onAbrirHost(h.rotulo) : undefined}
          />
        ))}
      </div>

      {celulas.length > 0 && (
        <div className="cl-celulas">
          {celulas.map((c) => (
            <div className="cel" key={c.rotulo}>
              <span className="cel-rot">{c.rotulo}</span>
              <span className={juntar('cel-val', c.tom && c.tom !== 'neutro' && c.tom)}>
                {c.valor}
              </span>
            </div>
          ))}
        </div>
      )}
    </article>
  );
}

// -----------------------------------------------------------------------------
// Tira (KPI)
// -----------------------------------------------------------------------------

export interface TiraProps {
  rotulo: string;
  valor: React.ReactNode;
  unidade?: string;
  /** Uma linha explicando o numero. Sem ela, um KPI e so um numero solto. */
  nota?: string;
  tom?: Tom;
  /** Esmaece: zero problema nao deve ter o mesmo peso visual que dez. */
  zero?: boolean;
  /** Serie curta abaixo do numero. */
  spark?: number[];
  className?: string;
}

/** Tira de KPI do topo. Numero grande, rotulo pequeno, e o porque embaixo. */
export function Tira({
  rotulo, valor, unidade, nota, tom = 'neutro', zero = false, spark, className,
}: TiraProps) {
  return (
    <div
      className={juntar(
        'tira',
        tom === 'alerta' && 'tira-alerta',
        tom === 'ruim' && 'tira-ruim',
        zero && 'zero',
        className,
      )}
    >
      <span className="tira-rot mono">{rotulo}</span>
      <div className="tira-valor">
        <strong className="mono">{valor}</strong>
        {unidade && <span className="tira-unid">{unidade}</span>}
      </div>
      {spark && <Spark valores={spark} tom={tom} />}
      {nota && <p className="tira-nota">{nota}</p>}
    </div>
  );
}

// -----------------------------------------------------------------------------
// Cartao lateral
// -----------------------------------------------------------------------------

export interface CartaoLateralProps {
  titulo: string;
  valor: React.ReactNode;
  unidade?: string;
  nota?: string;
  /** Bolinha no canto do titulo, para pulso de ingestao. */
  tom?: Tom;
  spark?: number[];
  className?: string;
}

/** Cartao compacto da barra lateral: um numero que se olha o tempo todo. */
export function CartaoLateral({
  titulo, valor, unidade, nota, tom, spark, className,
}: CartaoLateralProps) {
  return (
    <section className={juntar('cartao-lateral', className)} aria-label={titulo}>
      <div className="cl-topo">
        <span className="secao-lateral mono">{titulo}</span>
        {tom && <Ponto tom={tom} />}
      </div>
      <div className="cl-numero">
        <strong className="mono">{valor}</strong>
        {unidade && <span className="cl-unidade">{unidade}</span>}
      </div>
      {spark && <Spark valores={spark} tom={tom ?? 'ok'} lateral />}
      {nota && <p className="cl-nota">{nota}</p>}
    </section>
  );
}
