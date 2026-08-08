// =============================================================================
// Primitivos — os tijolos da linguagem do Sentinela
// =============================================================================
// NENHUM destes componentes escreve CSS proprio. Eles aplicam as classes do
// styles.css que ja roda em producao, e e por isso que o que aparece aqui e
// exatamente o que aparece no painel de verdade — inclusive o tema claro, que
// vem de graca porque as variaveis sao as mesmas.
//
// A REGRA DE COR MANDA EM TUDO: vermelho e reservado para offline e limiar
// estourado. Se qualquer coisa pode ficar vermelha, nada chama atencao.
// =============================================================================

import * as React from 'react';

/** Estado de saude. E o eixo em torno do qual a interface inteira gira. */
export type Tom = 'ok' | 'alerta' | 'ruim' | 'neutro';

/** Estado de uma maquina. `degradado` e DERIVADO: responde, mas com problema. */
export type EstadoMaquina =
  | 'online'
  | 'degradado'
  | 'offline'
  | 'never'
  | 'manutencao'
  | 'disabled';

const juntar = (...cs: Array<string | false | null | undefined>) =>
  cs.filter(Boolean).join(' ');

// -----------------------------------------------------------------------------
// Ponto
// -----------------------------------------------------------------------------

export interface PontoProps {
  /** Cor do ponto. */
  tom?: Tom;
  /**
   * Pulsa devagar. Reserve para o que esta acontecendo AGORA — um ponto que
   * pulsa sem motivo treina a pessoa a ignorar o que pulsa.
   */
  pulsando?: boolean;
  className?: string;
}

/**
 * Bolinha de estado. O menor sinal da interface: aparece dentro de selos, ao
 * lado de rotulos e no cabecalho da lateral.
 */
export function Ponto({ tom = 'neutro', pulsando = false, className }: PontoProps) {
  return (
    <i
      aria-hidden="true"
      className={juntar(
        'ponto',
        tom === 'ok' && 'ponto-ok',
        tom === 'alerta' && 'ponto-alerta',
        tom === 'ruim' && 'ponto-ruim',
        className,
      )}
      style={pulsando ? undefined : { animation: 'none' }}
    />
  );
}

// -----------------------------------------------------------------------------
// Selo
// -----------------------------------------------------------------------------

export interface SeloProps {
  tom?: Tom;
  /** Numero em destaque, antes do rotulo. Ex.: **12** offline */
  valor?: React.ReactNode;
  /** Esmaece quando o valor e zero: "0 offline" nao deve gritar. */
  zero?: boolean;
  /** Mostra a bolinha de estado a esquerda. */
  comPonto?: boolean;
  children?: React.ReactNode;
  className?: string;
}

/**
 * Contador com estado, do cabecalho. Le-se "3 degradados" de relance, sem
 * precisar entrar em nada.
 */
export function Selo({
  tom = 'neutro', valor, zero = false, comPonto = true, children, className,
}: SeloProps) {
  return (
    <span
      className={juntar(
        'selo',
        tom === 'ok' && 'selo-ok',
        tom === 'alerta' && 'selo-alerta',
        tom === 'ruim' && 'selo-ruim',
        zero && 'zero',
        className,
      )}
    >
      {comPonto && <Ponto tom={tom} />}
      {valor !== undefined && <b>{valor}</b>}
      {children}
    </span>
  );
}

// -----------------------------------------------------------------------------
// Etiqueta
// -----------------------------------------------------------------------------

export interface EtiquetaProps {
  estado: EstadoMaquina;
  children?: React.ReactNode;
  className?: string;
}

const ROTULO_ESTADO: Record<EstadoMaquina, string> = {
  online: 'online',
  degradado: 'degradado',
  offline: 'offline',
  never: 'nunca vista',
  manutencao: 'manutenção',
  disabled: 'inativa',
};

/** Etiqueta de estado de maquina, usada no canto dos cartoes. */
export function Etiqueta({ estado, children, className }: EtiquetaProps) {
  return (
    <span className={juntar('etiqueta', `etiqueta-${estado}`, className)}>
      {children ?? ROTULO_ESTADO[estado]}
    </span>
  );
}

// -----------------------------------------------------------------------------
// Botao
// -----------------------------------------------------------------------------

export type VarianteBotao = 'primario' | 'secundario' | 'perigo' | 'acao' | 'mini';

export interface BotaoProps extends Omit<React.ButtonHTMLAttributes<HTMLButtonElement>, 'className'> {
  variante?: VarianteBotao;
  /** Ocupa a linha inteira. */
  largo?: boolean;
  /**
   * Primeiro clique dado, aguardando confirmacao.
   *
   * A confirmacao em duas etapas e a unica protecao contra apagar historico por
   * engano — e vale APENAS para acao destrutiva. Fazer confirmar tudo ensina a
   * confirmar sem ler, e ai a confirmacao do que importa perde o sentido.
   */
  armado?: boolean;
  children?: React.ReactNode;
  className?: string;
}

const CLASSE_BOTAO: Record<VarianteBotao, string> = {
  primario: 'btn-primario',
  secundario: 'btn-secundario',
  perigo: 'btn-perigo',
  acao: 'btn-acao',
  mini: 'btn-mini',
};

/** Botao. `perigo` e para o que derruba loja ou apaga historico. */
export function Botao({
  variante = 'secundario', largo = false, armado = false,
  children, className, type = 'button', ...resto
}: BotaoProps) {
  return (
    <button
      type={type}
      className={juntar(CLASSE_BOTAO[variante], largo && 'largo', armado && 'armado', className)}
      {...resto}
    >
      {children}
    </button>
  );
}

// -----------------------------------------------------------------------------
// Spark
// -----------------------------------------------------------------------------

export interface SparkProps {
  /** Serie a desenhar. Cada valor vira uma barra. */
  valores: number[];
  /** Teto da escala. Sem ele, usa o maior valor da serie. */
  maximo?: number;
  tom?: Tom;
  /** Variante estreita, para a barra lateral. */
  lateral?: boolean;
  className?: string;
}

/**
 * Faixa de barras. Responde "esta subindo ou descendo?" sem eixo, sem legenda
 * e sem ocupar espaco.
 *
 * Serie curta NAO e um defeito a esconder: uma frota recem-instalada tem duas
 * amostras, e mostrar duas barras e mais honesto que desenhar uma linha que
 * sugere tendencia inexistente.
 */
export function Spark({ valores, maximo, tom = 'ok', lateral = false, className }: SparkProps) {
  if (!valores.length) {
    return <div className={juntar('spark', lateral && 'spark-lateral', 'spark-vazio', className)} />;
  }

  const teto = maximo ?? Math.max(...valores, 1);

  return (
    <div className={juntar('spark', lateral && 'spark-lateral', className)} aria-hidden="true">
      {valores.map((v, i) => (
        <span
          key={i}
          style={{
            height: `${Math.max(4, Math.min(100, (v / teto) * 100))}%`,
            background: tom === 'ruim' ? 'var(--crit)'
              : tom === 'alerta' ? 'var(--warn)'
              : tom === 'neutro' ? 'var(--fg3)'
              : 'var(--ok)',
          }}
        />
      ))}
    </div>
  );
}

// -----------------------------------------------------------------------------
// Barra
// -----------------------------------------------------------------------------

export interface BarraProps {
  /** 0 a 100. */
  pct: number;
  /** Acima disto a barra fica vermelha. */
  limiar?: number;
  className?: string;
}

/** Barra de preenchimento, para uso de CPU, memoria e disco. */
export function Barra({ pct, limiar = 90, className }: BarraProps) {
  const v = Math.max(0, Math.min(100, pct));
  return (
    <div className={juntar('barra', className)}>
      <div
        className={juntar('barra-fill', v >= limiar && 'barra-fill-ruim')}
        style={{ width: `${v}%` }}
      />
    </div>
  );
}
