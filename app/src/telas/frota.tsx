// =============================================================================
// Tela 2 — Frota
// =============================================================================
// Achar máquinas por qualquer combinação de filtros. A diferença para a tabela
// do NOC: aqui os cabeçalhos ordenam, as facetas contam, e a lista pagina.
// =============================================================================

import * as React from 'react';
import { Etiqueta } from '@cajupar/sentinela-ds';
import * as api from './../api';
import type { Host } from './../api';
import { Bloco, Faceta, Tabela, Valor, tomDoPercentual, tomDoDisco, desdeQuando } from './../comum';
import type { Coluna } from './../comum';
import { porGravidade, corDoEstado } from './noc';
import type { PropsTela } from './noc';

type Ordem = 'gravidade' | 'host' | 'cpu' | 'mem' | 'disco' | 'temp';

export function TelaFrota({ hosts, abrirHost }: PropsTela) {
  const [tipo, setTipo] = React.useState('todos');
  const [estado, setEstado] = React.useState('qualquer');
  const [ordem, setOrdem] = React.useState<Ordem>('gravidade');
  const [limite, setLimite] = React.useState(60);

  const tipos = React.useMemo(() => {
    const m = new Map<string, number>();
    for (const h of hosts) m.set(h.role_code, (m.get(h.role_code) ?? 0) + 1);
    return [...m].sort();
  }, [hosts]);

  const estados = React.useMemo(() => {
    const m = new Map<string, number>();
    for (const h of hosts) {
      const e = api.estadoDe(h);
      m.set(e, (m.get(e) ?? 0) + 1);
    }
    return m;
  }, [hosts]);

  const filtrados = React.useMemo(() => {
    let l = hosts;
    if (tipo !== 'todos') l = l.filter((h) => h.role_code === tipo);
    if (estado !== 'qualquer') l = l.filter((h) => api.estadoDe(h) === estado);
    return [...l].sort(COMPARADOR[ordem]);
  }, [hosts, tipo, estado, ordem]);

  const filtroAtivo = tipo !== 'todos' || estado !== 'qualquer';

  return (
    <Bloco
      titulo="Frota"
      sub={`${filtrados.length} de ${hosts.length} máquina(s) · clique numa linha para abrir o painel lateral`}
    >
      {/* ---------------------------------------------------- facetas --- */}
      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', alignItems: 'center', marginBottom: 14 }}>
        <Faceta rotulo="Todos" contagem={hosts.length} ativo={tipo === 'todos'}
                onClick={() => setTipo('todos')} />
        {tipos.map(([t, n]) => (
          <Faceta key={t} rotulo={t} contagem={n} ativo={tipo === t} onClick={() => setTipo(t)} />
        ))}

        <span style={{ width: 1, height: 20, background: 'var(--bd)', margin: '0 5px' }} />

        <Faceta rotulo="Qualquer" contagem={hosts.length} ativo={estado === 'qualquer'}
                onClick={() => setEstado('qualquer')} />
        {(['online', 'degradado', 'offline', 'never', 'manutencao'] as const).map((e) => (
          <Faceta key={e} rotulo={ROTULO[e]} contagem={estados.get(e) ?? 0}
                  ativo={estado === e} onClick={() => setEstado(e)} />
        ))}

        {filtroAtivo && (
          <button
            type="button"
            onClick={() => { setTipo('todos'); setEstado('qualquer'); }}
            style={{
              marginLeft: 'auto', all: 'unset', cursor: 'pointer',
              fontSize: 11.5, color: 'var(--info)',
            }}
          >
            Limpar filtros
          </button>
        )}
      </div>

      <Tabela
        colunas={COLUNAS}
        linhas={filtrados.slice(0, limite)}
        chaveDe={(h) => h.machine_id}
        ordem={ordem}
        onOrdenar={(c) => setOrdem(c as Ordem)}
        onAbrir={(h) => abrirHost(h.machine_id)}
        vazio={filtroAtivo ? 'Nenhuma máquina com esses filtros.' : 'Nenhuma máquina cadastrada.'}
      />

      <div style={{
        display: 'flex', alignItems: 'center', gap: 12,
        marginTop: 12, fontSize: 11, color: 'var(--fg3)',
      }}>
        <span>Exibindo {Math.min(limite, filtrados.length)} de {filtrados.length}</span>
        {filtrados.length > limite && (
          <button
            type="button"
            onClick={() => setLimite(limite + 50)}
            style={{ all: 'unset', cursor: 'pointer', color: 'var(--info)' }}
          >
            Carregar mais 50
          </button>
        )}
      </div>
    </Bloco>
  );
}

const ROTULO: Record<string, string> = {
  online: 'Online', degradado: 'Degradado', offline: 'Offline',
  never: 'Nunca vista', manutencao: 'Manutenção',
};

const COMPARADOR: Record<Ordem, (a: Host, b: Host) => number> = {
  gravidade: porGravidade,
  host: (a, b) => a.label.localeCompare(b.label, 'pt-BR'),
  cpu: (a, b) => (b.cpu_pct ?? -1) - (a.cpu_pct ?? -1),
  mem: (a, b) => (b.mem_pct ?? -1) - (a.mem_pct ?? -1),
  // Disco ao contrário: MENOS livre é pior, então vem primeiro.
  disco: (a, b) => (a.disk_min_free_pct ?? 101) - (b.disk_min_free_pct ?? 101),
  temp: (a, b) => (b.cpu_temp_c ?? -1) - (a.cpu_temp_c ?? -1),
};

const COLUNAS: Coluna<Host>[] = [
  {
    chave: 'host', rotulo: 'Host', largura: '1.5fr', ordena: true,
    render: (h) => (
      <span style={{ display: 'flex', alignItems: 'center', gap: 7, minWidth: 0 }}>
        <i style={{ width: 6, height: 6, borderRadius: '50%', flex: '0 0 auto',
                    background: corDoEstado(api.estadoDe(h)) }} />
        <span style={{ fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis' }}>{h.label}</span>
      </span>
    ),
  },
  { chave: 'loja', rotulo: 'Loja', largura: '.85fr',
    render: (h) => <span style={{ color: 'var(--fg2)' }}>{h.site_code}</span> },
  { chave: 'tipo', rotulo: 'Tipo', largura: '.55fr',
    render: (h) => <span style={{ color: 'var(--fg3)', fontSize: 11 }}>{h.role_code}</span> },
  { chave: 'estado', rotulo: 'Estado', largura: '.7fr',
    render: (h) => <Etiqueta estado={api.estadoDe(h)} /> },
  { chave: 'cpu', rotulo: 'CPU', largura: '.7fr', ordena: true, alinhaDireita: true,
    render: (h) => <Valor n={h.cpu_pct} sufixo="%" tom={tomDoPercentual(h.cpu_pct)} /> },
  { chave: 'mem', rotulo: 'Mem', largura: '.7fr', ordena: true, alinhaDireita: true,
    render: (h) => <Valor n={h.mem_pct} sufixo="%" tom={tomDoPercentual(h.mem_pct)} /> },
  { chave: 'disco', rotulo: 'Disco', largura: '.7fr', ordena: true, alinhaDireita: true,
    render: (h) => <Valor n={h.disk_min_free_pct} sufixo="%" tom={tomDoDisco(h.disk_min_free_pct)} /> },
  { chave: 'temp', rotulo: 'Temp', largura: '.55fr', ordena: true, alinhaDireita: true,
    render: (h) => <Valor n={h.cpu_temp_c} sufixo="°" tom={tomDoPercentual(h.cpu_temp_c, 75, 85)} /> },
  { chave: 'hb', rotulo: 'HB', largura: '.65fr', alinhaDireita: true,
    render: (h) => <span className="mono" style={{ fontSize: 10, color: 'var(--fg3)' }}>
      {desdeQuando(h.seconds_since_seen)}</span> },
  { chave: 'agente', rotulo: 'Agente', largura: '.6fr', alinhaDireita: true,
    render: (h) => <span className="mono" style={{ fontSize: 10, color: 'var(--fg3)' }}>
      {h.agent_version ?? '—'}</span> },
];
