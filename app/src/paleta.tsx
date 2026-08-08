// =============================================================================
// Paleta de comandos (⌘K)
// =============================================================================
// Busca comandos e hosts ao mesmo tempo. Num parque de 200 máquinas, achar
// "PDV 07 da Asa Norte" por navegação custa quatro cliques e a memória de onde
// ela está; por busca custa três letras.
// =============================================================================

import * as React from 'react';
import * as api from './api';
import type { Host } from './api';
import { Ico } from './icones';
import type { Vistas } from './App';

interface Item {
  id: string;
  titulo: string;
  sub: string;
  cat: 'nav' | 'ação' | 'host';
  ico: string;
  tom?: string;
  chaves: string;
  ativar: () => void;
}

export function Paleta({
  hosts, onFechar, onIr, onHost, onTema,
}: {
  hosts: Host[];
  onFechar: () => void;
  onIr: (v: Vistas) => void;
  onHost: (id: string) => void;
  onTema: () => void;
}) {
  const [q, setQ] = React.useState('');
  const campo = React.useRef<HTMLInputElement>(null);

  // ~20ms: o campo só existe depois que o navegador pintou o diálogo, e focar
  // antes disso não faz nada — a paleta abriria sem cursor.
  React.useEffect(() => {
    const t = setTimeout(() => campo.current?.focus(), 20);
    return () => clearTimeout(t);
  }, []);

  const itens = React.useMemo<Item[]>(() => {
    const nav: Item[] = ([
      ['noc', 'Visão geral', 'o estado da frota agora', 'grade'],
      ['frota', 'Frota', 'todas as máquinas, com filtros', 'servidor'],
      ['incidente', 'Incidente', 'conduzir um incidente aberto', 'aviso'],
      ['inventario', 'Inventário', 'hardware e software', 'caixa'],
      ['alertas', 'Regras & ruído', 'o que dispara alerta, e quanto disso é ruído', 'sino'],
      ['auditoria', 'Auditoria', 'quem fez o quê, e quando', 'escudo'],
      ['plantao', 'Plantão', 'o que exige alguém agora', 'telefone'],
    ] as const).map(([v, titulo, sub, ico]) => ({
      id: `nav-${v}`, titulo, sub, cat: 'nav' as const, ico,
      chaves: `${titulo} ${sub} ${v}`,
      ativar: () => onIr(v as Vistas),
    }));

    const acoes: Item[] = [
      {
        id: 'ac-tema', titulo: 'Alternar tema', sub: 'claro e escuro',
        cat: 'ação', ico: 'lua', chaves: 'tema claro escuro dark light',
        ativar: onTema,
      },
      {
        id: 'ac-sair', titulo: 'Sair', sub: 'encerrar a sessão',
        cat: 'ação', ico: 'chave', chaves: 'sair logout sessão',
        ativar: api.encerrarSessao,
      },
    ];

    const h: Item[] = hosts.map((x) => {
      const e = api.estadoDe(x);
      return {
        id: `h-${x.machine_id}`,
        titulo: x.label,
        sub: `${x.site_code} · ${x.ip_lan ?? 'sem IP'} · ${e}`,
        cat: 'host' as const,
        ico: 'monitor',
        tom: e === 'offline' ? 'var(--crit)' : e === 'degradado' ? 'var(--warn)' : 'var(--ok)',
        chaves: `${x.label} ${x.hostname ?? ''} ${x.ip_lan ?? ''} ${x.site_code} ${x.site_name} ${x.mac_address ?? ''}`,
        ativar: () => onHost(x.machine_id),
      };
    });

    return [...nav, ...acoes, ...h];
  }, [hosts, onIr, onHost, onTema]);

  const termo = q.trim().toLowerCase();

  const resultados = React.useMemo(() => {
    if (!termo) {
      // Busca vazia: os destinos, e os hosts que mais precisam de alguém —
      // ordenados por gravidade, não alfabeticamente.
      const criticos = itens
        .filter((i) => i.cat === 'host')
        .sort((a, b) => peso(b.tom) - peso(a.tom))
        .slice(0, 5);
      return [...itens.filter((i) => i.cat !== 'host').slice(0, 6), ...criticos];
    }
    return itens.filter((i) => i.chaves.toLowerCase().includes(termo)).slice(0, 30);
  }, [itens, termo]);

  const primeiro = resultados[0];

  return (
    <>
      <div
        onClick={onFechar}
        style={{
          position: 'fixed', inset: 0, zIndex: 80,
          background: 'rgba(2,4,8,.55)', backdropFilter: 'blur(3px)',
        }}
      />
      <div
        role="dialog"
        aria-modal="true"
        aria-label="Paleta de comandos"
        style={{
          position: 'fixed', left: '50%', top: '12vh', transform: 'translateX(-50%)',
          zIndex: 81, width: 620, maxWidth: '92vw', maxHeight: '66vh',
          display: 'flex', flexDirection: 'column',
          background: 'var(--pnl)', backdropFilter: 'blur(20px)',
          border: '1px solid var(--bd)', borderRadius: 'var(--r-g)',
          boxShadow: 'var(--sh)', overflow: 'hidden',
        }}
      >
        <div style={{
          display: 'flex', alignItems: 'center', gap: 10,
          padding: '13px 16px', borderBottom: '1px solid var(--bd2)',
        }}>
          <Ico n="busca" tam={17} />
          <input
            ref={campo}
            value={q}
            onChange={(e) => setQ(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter' && primeiro) primeiro.ativar(); }}
            placeholder="máquina, loja, IP, ou um comando"
            style={{
              all: 'unset', flex: 1, fontFamily: 'var(--fonte)',
              fontSize: 14, color: 'var(--fg)',
            }}
          />
        </div>

        <div style={{ overflowY: 'auto', padding: 6 }}>
          {resultados.length === 0 && (
            <div style={{ padding: '26px 14px', fontSize: 12, color: 'var(--fg3)', textAlign: 'center' }}>
              Nada encontrado para «{q}»
            </div>
          )}

          {resultados.map((i, n) => (
            <button
              key={i.id}
              type="button"
              onClick={i.ativar}
              style={{
                all: 'unset', boxSizing: 'border-box',
                display: 'flex', alignItems: 'center', gap: 11, width: '100%',
                padding: '9px 11px', borderRadius: 'var(--r-m)', cursor: 'pointer',
                background: n === 0 ? 'var(--hov)' : 'transparent',
              }}
              onMouseEnter={(e) => { e.currentTarget.style.background = 'var(--hov)'; }}
              onMouseLeave={(e) => { e.currentTarget.style.background = n === 0 ? 'var(--hov)' : 'transparent'; }}
            >
              <span style={{
                display: 'grid', placeItems: 'center', width: 26, height: 26,
                borderRadius: 8, flex: '0 0 auto',
                background: `color-mix(in srgb, ${i.tom ?? 'var(--info)'} 14%, transparent)`,
                color: i.tom ?? 'var(--info)',
              }}>
                <Ico n={i.ico} tam={14} />
              </span>
              <span style={{ minWidth: 0, flex: 1 }}>
                <span style={{ display: 'block', fontSize: 12.5, fontWeight: 600 }}>{i.titulo}</span>
                <span className="mono" style={{
                  display: 'block', fontSize: 10, color: 'var(--fg3)',
                  overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
                }}>
                  {i.sub}
                </span>
              </span>
              <span className="mono" style={{
                fontSize: 9, padding: '2px 6px', borderRadius: 4,
                border: '1px solid var(--bd)', color: 'var(--fg3)', flex: '0 0 auto',
              }}>
                {i.cat}
              </span>
            </button>
          ))}
        </div>

        <div style={{
          padding: '8px 14px', borderTop: '1px solid var(--bd2)',
          fontSize: 10, color: 'var(--fg3)', display: 'flex', gap: 14,
        }}>
          <span>↵ abrir</span>
          <span>⌘K alternar</span>
          <span style={{ marginLeft: 'auto' }} className="mono">
            {resultados.length} resultado(s)
          </span>
        </div>
      </div>
    </>
  );
}

const peso = (tom?: string) =>
  tom === 'var(--crit)' ? 3 : tom === 'var(--warn)' ? 2 : 1;
