// =============================================================================
// Tela 1 — Visão geral do NOC
// =============================================================================
// O propósito, do handoff: em 2 segundos o operador sabe se algo exige ação
// agora. Três variações do mesmo dado, porque a pergunta muda com o tamanho do
// parque — cartões para dezenas, tabela para centenas, heatmap para milhares.
// =============================================================================

import * as React from 'react';
import { Tira, CartaoLoja, Cartao, Segmentado, ItemFila, Barra, Etiqueta } from '@cajupar/sentinela-ds';
import * as api from './../api';
import type { Host, Loja } from './../api';
import { Bloco, Faceta, Valor, tomDoPercentual, tomDoDisco, desdeQuando, Tabela } from './../comum';
import type { Coluna } from './../comum';
import { GraficoDeCarga } from './../grafico';

export interface PropsTela {
  hosts: Host[];
  todosHosts: Host[];
  lojas: Loja[];
  abrirHost: (id: string) => void;
  avisar: (t: string, tom?: 'ok' | 'warn' | 'crit' | 'info') => void;
  irPara: (v: import('./../vistas').Vistas) => void;
  carregando: boolean;
}

type Variacao = 'cards' | 'tabela' | 'heatmap';

const NOTA_VARIACAO: Record<Variacao, string> = {
  cards: 'Cartão por loja, com o mapa de calor das máquinas dela.',
  tabela: 'Uma linha por máquina, ordenada por gravidade. É a que carrega mais informação.',
  heatmap: 'Uma faixa por loja. O parque inteiro numa tela.',
};

export function TelaNOC({
  hosts, lojas, abrirHost, marca, setMarca, marcas, carregando,
}: PropsTela & {
  marca: string; setMarca: (m: string) => void; marcas: { code: string; name: string }[];
}) {
  const [variacao, setVariacao] = React.useState<Variacao>('tabela');

  const c = React.useMemo(() => contar(hosts), [hosts]);

  return (
    <>
      {/* ------------------------------------------------------- KPIs --- */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(170px, 1fr))', gap: 10 }}>
        <Tira
          rotulo="Hosts online" valor={c.ok + c.degradado} unidade={`de ${c.total}`}
          nota={c.total ? `${((100 * (c.ok + c.degradado)) / c.total).toFixed(1)}% reportando` : 'sem máquinas'}
          tom={c.total && c.ok + c.degradado < c.total ? 'alerta' : 'ok'}
        />
        <Tira rotulo="Degradados" valor={c.degradado} zero={c.degradado === 0}
              tom={c.degradado ? 'alerta' : 'neutro'}
              nota={c.degradado ? 'serviço parado ou disco no limite' : 'nenhum'} />
        <Tira rotulo="Offline" valor={c.offline} zero={c.offline === 0}
              tom={c.offline ? 'ruim' : 'neutro'}
              nota={c.offline ? c.lojasComOffline.join(', ') : 'nenhum'} />
        <Tira rotulo="Nunca vistas" valor={c.never} zero={c.never === 0}
              nota={c.never ? 'cadastradas, sem primeiro contato' : 'nenhuma'} />
        <Tira rotulo="Em manutenção" valor={c.manutencao} zero={c.manutencao === 0}
              nota={c.manutencao ? 'alertas suprimidos' : 'nenhuma'} />
        <Tira
          rotulo="Agentes desatualizados" valor={c.desatualizados} zero={c.desatualizados === 0}
          tom={c.desatualizados ? 'alerta' : 'neutro'}
          nota={c.versaoAlvo ? `alvo ${c.versaoAlvo}` : 'sem agente reportando'}
        />
      </div>

      {/* --------------------------------------------------- controle --- */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
        <span className="secao-lateral mono">Layout da visão</span>
        <Segmentado
          valor={variacao}
          onChange={(v) => setVariacao(v as Variacao)}
          opcoes={[
            { valor: 'cards', rotulo: 'Cards' },
            { valor: 'tabela', rotulo: 'Tabela densa' },
            { valor: 'heatmap', rotulo: 'Heatmap' },
          ]}
        />
        <span style={{ fontSize: 11, color: 'var(--fg3)' }}>{NOTA_VARIACAO[variacao]}</span>

        {marcas.length > 1 && (
          <div style={{ marginLeft: 'auto', display: 'flex', gap: 6 }}>
            <Faceta rotulo="Todas" ativo={marca === 'todas'} onClick={() => setMarca('todas')} />
            {marcas.map((m) => (
              <Faceta key={m.code} rotulo={m.name} ativo={marca === m.code}
                      onClick={() => setMarca(m.code)} />
            ))}
          </div>
        )}
      </div>

      {carregando && hosts.length === 0 && (
        <Bloco><p style={{ margin: 0, fontSize: 12, color: 'var(--fg3)' }}>Carregando a frota…</p></Bloco>
      )}

      {variacao === 'tabela' && <VariacaoTabela hosts={hosts} abrirHost={abrirHost} />}
      {variacao === 'cards' && <VariacaoCards hosts={hosts} lojas={lojas} abrirHost={abrirHost} />}
      {variacao === 'heatmap' && <VariacaoHeatmap hosts={hosts} lojas={lojas} abrirHost={abrirHost} />}
    </>
  );
}

// -----------------------------------------------------------------------------
// Variação B — tabela densa (padrão: é a que valida a densidade)
// -----------------------------------------------------------------------------

function VariacaoTabela({ hosts, abrirHost }: { hosts: Host[]; abrirHost: (id: string) => void }) {
  const ordenados = React.useMemo(() => [...hosts].sort(porGravidade), [hosts]);
  const dist = React.useMemo(() => contar(hosts), [hosts]);

  return (
    <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0,1fr) 300px', gap: 14, alignItems: 'start' }}>
      <Bloco titulo="Máquinas" sub={`${hosts.length} no escopo · ordenadas por gravidade`}>
        <Tabela
          colunas={COLUNAS_NOC}
          linhas={ordenados}
          chaveDe={(h) => h.machine_id}
          onAbrir={(h) => abrirHost(h.machine_id)}
          vazio="Nenhuma máquina cadastrada neste escopo."
        />
      </Bloco>

      <div style={{ display: 'grid', gap: 14 }}>
        <Bloco titulo="Distribuição por estado">
          {([
            ['Online', dist.ok, 'var(--ok)'],
            ['Degradado', dist.degradado, 'var(--warn)'],
            ['Offline', dist.offline, 'var(--crit)'],
            ['Nunca vista', dist.never, 'var(--fg3)'],
            ['Manutenção', dist.manutencao, 'var(--fg3)'],
          ] as const).map(([rot, n, cor]) => (
            <LinhaBarra key={rot} rotulo={rot} n={n} total={dist.total} cor={cor} />
          ))}
        </Bloco>

        <Bloco titulo="Saturação por perfil" sub="CPU média das que estão reportando">
          {porPerfil(hosts).map((p) => (
            <div key={p.perfil} style={{ marginBottom: 10 }}>
              <div style={{ display: 'flex', fontSize: 11, marginBottom: 4 }}>
                <span style={{ color: 'var(--fg2)' }}>{p.perfil}</span>
                <span className="mono" style={{ marginLeft: 'auto', color: 'var(--fg3)' }}>
                  {p.n} · <Valor n={p.cpu} sufixo="%" tom={tomDoPercentual(p.cpu)} />
                </span>
              </div>
              {p.cpu !== null && <Barra pct={p.cpu} />}
            </div>
          ))}
        </Bloco>
      </div>
    </div>
  );
}

const COLUNAS_NOC: Coluna<Host>[] = [
  {
    chave: 'host', rotulo: 'Host', largura: '1.5fr',
    render: (h) => (
      <span style={{ display: 'flex', alignItems: 'center', gap: 7, minWidth: 0 }}>
        <i style={{
          width: 6, height: 6, borderRadius: '50%', flex: '0 0 auto',
          background: corDoEstado(api.estadoDe(h)),
        }} />
        <span style={{ fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis' }}>{h.label}</span>
      </span>
    ),
  },
  { chave: 'loja', rotulo: 'Loja', largura: '.85fr',
    render: (h) => <span style={{ color: 'var(--fg2)' }}>{h.site_code}</span> },
  { chave: 'tipo', rotulo: 'Tipo', largura: '.6fr',
    render: (h) => <span style={{ color: 'var(--fg3)', fontSize: 11 }}>{h.role_code}</span> },
  { chave: 'estado', rotulo: 'Estado', largura: '.7fr',
    render: (h) => <Etiqueta estado={api.estadoDe(h)} /> },
  { chave: 'cpu', rotulo: 'CPU', largura: '.8fr', alinhaDireita: true,
    render: (h) => <Valor n={h.cpu_pct} sufixo="%" tom={tomDoPercentual(h.cpu_pct)} /> },
  { chave: 'mem', rotulo: 'Mem', largura: '.8fr', alinhaDireita: true,
    render: (h) => <Valor n={h.mem_pct} sufixo="%" tom={tomDoPercentual(h.mem_pct)} /> },
  { chave: 'disco', rotulo: 'Disco livre', largura: '.8fr', alinhaDireita: true,
    render: (h) => <Valor n={h.disk_min_free_pct} sufixo="%" tom={tomDoDisco(h.disk_min_free_pct)} /> },
  { chave: 'temp', rotulo: 'Temp', largura: '.6fr', alinhaDireita: true,
    render: (h) => <Valor n={h.cpu_temp_c} sufixo="°" casas={0} tom={tomDoPercentual(h.cpu_temp_c, 75, 85)} /> },
  { chave: 'hb', rotulo: 'HB', largura: '.7fr', alinhaDireita: true,
    render: (h) => (
      <span className="mono" style={{ fontSize: 10, color: 'var(--fg3)' }}>
        {desdeQuando(h.seconds_since_seen)}
      </span>
    ) },
];

// -----------------------------------------------------------------------------
// Variação A — cards
// -----------------------------------------------------------------------------

/**
 * Carga da frota: a media de cada instante entre as maquinas do escopo.
 *
 * O grafico QUEBRA no buraco em vez de ligar os dois lados: minuto sem amostra
 * nao e uma linha reta, e num painel de monitoramento o buraco e justamente o
 * dado que interessa.
 */
function CargaDaFrota({ hosts }: { hosts: Host[] }) {
  const [faixa, setFaixa] = React.useState<'24h' | '7d' | '30d'>('24h');
  const [pts, setPts] = React.useState<{ t: number; cpu: number | null; mem: number | null }[]>([]);
  const [carregando, setCarregando] = React.useState(true);

  const ids = React.useMemo(() => hosts.map((h) => h.machine_id).join(','), [hosts]);

  React.useEffect(() => {
    let vivo = true;
    setCarregando(true);
    api.cargaDaFrota(ids ? ids.split(',') : [], faixa)
      .then((x) => { if (vivo) { setPts(x); setCarregando(false); } })
      .catch(() => { if (vivo) { setPts([]); setCarregando(false); } });
    return () => { vivo = false; };
  }, [ids, faixa]);

  const marcas = React.useMemo(() => {
    if (pts.length < 2) return [];
    const t0 = pts[0].t; const t1 = pts[pts.length - 1].t;
    return [0, 1, 2, 3, 4, 5, 6].map((i) => {
      const t = t0 + ((t1 - t0) * i) / 6;
      return {
        t,
        rotulo: i === 6 ? 'agora'
          : new Date(t).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' }),
      };
    });
  }, [pts]);

  const reportando = hosts.filter((h) => h.cpu_pct !== null).length;

  return (
    <Bloco
      titulo="Carga da frota"
      sub={`CPU e memória médias · ${reportando} host(s) reportando`}
      acoes={
        <Segmentado
          valor={faixa}
          onChange={(v) => setFaixa(v as '24h' | '7d' | '30d')}
          opcoes={[
            { valor: '24h', rotulo: '24 h' },
            { valor: '7d', rotulo: '7 d' },
            { valor: '30d', rotulo: '30 d' },
          ]}
        />
      }
    >
      <div style={{ display: 'flex', gap: 14, marginBottom: 8, fontSize: 10.5, color: 'var(--fg3)' }}>
        <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
          <i style={{ width: 9, height: 2, background: 'var(--info)', borderRadius: 2 }} /> CPU
        </span>
        <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
          <i style={{ width: 9, height: 2, background: 'var(--vio)', borderRadius: 2 }} /> Memória
        </span>
      </div>

      {carregando
        ? <div style={{ height: 190, display: 'grid', placeItems: 'center',
                        fontSize: 11.5, color: 'var(--fg3)' }}>carregando a série…</div>
        : (
          <GraficoDeCarga
            marcasX={marcas}
            series={[
              { nome: 'CPU', cor: 'var(--info)', pontos: pts.map((x) => ({ t: x.t, v: x.cpu })) },
              { nome: 'Memória', cor: 'var(--vio)', pontos: pts.map((x) => ({ t: x.t, v: x.mem })) },
            ]}
          />
        )}
    </Bloco>
  );
}
function VariacaoCards({
  hosts, lojas, abrirHost,
}: { hosts: Host[]; lojas: Loja[]; abrirHost: (id: string) => void }) {
  const fila = React.useMemo(
    () => [...hosts].sort(porGravidade).filter((h) => api.estadoDe(h) !== 'online').slice(0, 6),
    [hosts],
  );

  const porLoja = React.useMemo(() => {
    const m = new Map<string, Host[]>();
    for (const h of hosts) {
      const l = m.get(h.site_code) ?? [];
      l.push(h); m.set(h.site_code, l);
    }
    return m;
  }, [hosts]);

  return (
    <>
      <CargaDaFrota hosts={hosts} />
      <div style={{ display: 'grid', gridTemplateColumns: '1.55fr 1fr', gap: 14, alignItems: 'start' }}>
        <Bloco titulo="Máquinas que pedem atenção"
               sub="Ordenadas por gravidade. Verde não aparece aqui — é o normal.">
          {fila.length === 0
            ? <p style={{ margin: 0, fontSize: 12, color: 'var(--ok)' }}>
                Nada exigindo ação. Toda a frota reportando normalmente.
              </p>
            : (
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(230px, 1fr))', gap: 10 }}>
                {fila.map((h) => (
                  <Cartao
                    key={h.machine_id}
                    nome={h.label}
                    estado={api.estadoDe(h)}
                    contexto={`${h.site_code} — ${h.site_name}`}
                    visto={desdeQuando(h.seconds_since_seen)}
                    servicos={h.services_down !== null
                      ? `${h.services_down} serviço(s) parado(s)` : undefined}
                    metricas={[
                      { rotulo: 'CPU', valor: h.cpu_pct !== null ? `${h.cpu_pct.toFixed(0)}%` : '—' },
                      { rotulo: 'MEM', valor: h.mem_pct !== null ? `${h.mem_pct.toFixed(0)}%` : '—' },
                    ]}
                    onClick={() => abrirHost(h.machine_id)}
                  />
                ))}
              </div>
            )}
        </Bloco>

        <Bloco titulo="Fila de atenção" sub="O que fazer primeiro">
          {fila.length === 0
            ? <p style={{ margin: 0, fontSize: 12, color: 'var(--fg3)' }}>Fila vazia.</p>
            : (
              <ul style={{ listStyle: 'none', margin: 0, padding: 0 }}>
                {fila.map((h) => {
                  const p = api.problemasDe(h);
                  const e = api.estadoDe(h);
                  return (
                    <ItemFila
                      key={h.machine_id}
                      titulo={`${h.label} · ${p[0] ?? e}`}
                      detalhe={desdeQuando(h.seconds_since_seen)}
                      tom={e === 'offline' ? 'ruim' : e === 'degradado' ? 'alerta' : 'ok'}
                      onClick={() => abrirHost(h.machine_id)}
                    />
                  );
                })}
              </ul>
            )}
        </Bloco>
      </div>

      <Bloco titulo="Lojas">
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(268px, 1fr))', gap: 12 }}>
          {lojas.map((l) => {
            const hs = porLoja.get(l.site_code) ?? [];
            return (
              <CartaoLoja
                key={l.site_id}
                nome={l.site_name}
                codigo={`${l.site_code}${l.vpn_subnet ? ` · ${l.vpn_subnet}` : ''}`}
                situacao={api.situacaoDa(l)}
                hosts={hs.map((h) => ({ rotulo: h.label, estado: api.estadoDe(h) }))}
                onAbrirHost={(rot) => {
                  const h = hs.find((x) => x.label === rot);
                  if (h) abrirHost(h.machine_id);
                }}
                celulas={[
                  { rotulo: 'ONLINE', valor: `${l.machines_online}/${l.machines_total}`,
                    tom: l.machines_online === l.machines_total ? 'ok' : 'ruim' },
                  { rotulo: 'CPU MÉD', valor: l.cpu_avg_online !== null ? `${l.cpu_avg_online.toFixed(0)}%` : '—' },
                  { rotulo: 'DISCO', valor: l.disk_min_free_pct !== null ? `${l.disk_min_free_pct.toFixed(0)}%` : '—',
                    tom: l.disk_min_free_pct !== null && l.disk_min_free_pct <= 15 ? 'ruim' : undefined },
                ]}
              />
            );
          })}
        </div>
      </Bloco>
    </>
  );
}

// -----------------------------------------------------------------------------
// Variação C — heatmap
// -----------------------------------------------------------------------------

function VariacaoHeatmap({
  hosts, lojas, abrirHost,
}: { hosts: Host[]; lojas: Loja[]; abrirHost: (id: string) => void }) {
  return (
    <Bloco
      titulo="Parque inteiro"
      sub="Uma faixa por loja. Cada quadradinho é uma máquina — clique para abrir."
      acoes={
        <div style={{ display: 'flex', gap: 12, fontSize: 10.5, color: 'var(--fg3)' }}>
          {([['ok', 'ok'], ['warn', 'degradado'], ['crit', 'offline'], ['fg3', 'manutenção']] as const)
            .map(([t, r]) => (
              <span key={r} style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
                <i style={{
                  width: 10, height: 10, borderRadius: 3,
                  background: `color-mix(in srgb, var(--${t}) 26%, transparent)`,
                  border: `1px solid color-mix(in srgb, var(--${t}) 44%, transparent)`,
                }} />
                {r}
              </span>
            ))}
        </div>
      }
    >
      {lojas.map((l) => {
        const hs = hosts.filter((h) => h.site_code === l.site_code);
        return (
          <div
            key={l.site_id}
            style={{
              display: 'grid', gridTemplateColumns: '190px minmax(0,1fr) 120px',
              gap: 12, alignItems: 'center',
              padding: '5px 0', borderTop: '1px solid var(--bd2)',
            }}
          >
            <div style={{ minWidth: 0 }}>
              <div style={{ fontSize: 12, fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis' }}>
                {l.site_name}
              </div>
              <div className="mono" style={{ fontSize: 9.5, color: 'var(--fg3)' }}>
                {l.site_code}{l.vpn_subnet ? ` · ${l.vpn_subnet}` : ''}
              </div>
            </div>

            <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap' }}>
              {hs.map((h) => {
                const e = api.estadoDe(h);
                const t = e === 'offline' ? 'crit' : e === 'degradado' ? 'warn'
                  : e === 'online' ? 'ok' : 'fg3';
                return (
                  <button
                    key={h.machine_id}
                    type="button"
                    title={`${h.label} · ${e}${h.cpu_pct !== null ? ` · cpu ${h.cpu_pct.toFixed(0)}%` : ''}`}
                    onClick={() => abrirHost(h.machine_id)}
                    style={{
                      all: 'unset', width: 16, height: 16, borderRadius: 3, cursor: 'pointer',
                      background: `color-mix(in srgb, var(--${t}) 26%, transparent)`,
                      border: `1px solid color-mix(in srgb, var(--${t}) 44%, transparent)`,
                      transition: 'transform .13s ease',
                    }}
                    onMouseEnter={(ev) => { ev.currentTarget.style.transform = 'scale(1.28)'; }}
                    onMouseLeave={(ev) => { ev.currentTarget.style.transform = 'none'; }}
                  />
                );
              })}
              {hs.length === 0 && (
                <span style={{ fontSize: 11, color: 'var(--fg3)' }}>sem máquinas cadastradas</span>
              )}
            </div>

            <div style={{ textAlign: 'right' }}>
              <div className="mono" style={{ fontSize: 11 }}>
                {l.machines_online}/{l.machines_total}
              </div>
              {l.cpu_avg_online !== null && (
                <div style={{ width: 44, marginLeft: 'auto', marginTop: 4 }}>
                  <Barra pct={l.cpu_avg_online} />
                </div>
              )}
            </div>
          </div>
        );
      })}
    </Bloco>
  );
}

// -----------------------------------------------------------------------------
// Cálculos
// -----------------------------------------------------------------------------

const PESO: Record<string, number> = {
  offline: 0, degradado: 1, never: 2, online: 3, manutencao: 4, disabled: 5,
};

/** Pior primeiro; dentro do grupo, maior CPU primeiro. */
export function porGravidade(a: Host, b: Host) {
  const d = PESO[api.estadoDe(a)] - PESO[api.estadoDe(b)];
  if (d !== 0) return d;
  return (b.cpu_pct ?? -1) - (a.cpu_pct ?? -1);
}

export const corDoEstado = (e: string) =>
  e === 'offline' ? 'var(--crit)' : e === 'degradado' ? 'var(--warn)'
    : e === 'online' ? 'var(--ok)' : 'var(--fg3)';

function contar(hosts: Host[]) {
  const c = {
    ok: 0, degradado: 0, offline: 0, never: 0, manutencao: 0, disabled: 0,
    total: hosts.length, desatualizados: 0, versaoAlvo: null as string | null,
    lojasComOffline: [] as string[],
  };

  const versoes = hosts.map((h) => h.agent_version).filter(Boolean) as string[];
  // O alvo é a MAIOR versão que alguma máquina já reporta — não um número
  // fixo no código, que envelheceria a cada release do agente.
  c.versaoAlvo = versoes.sort(compararVersao).at(-1) ?? null;

  const lojas = new Set<string>();
  for (const h of hosts) {
    const e = api.estadoDe(h);
    if (e === 'online') c.ok++;
    else if (e === 'degradado') c.degradado++;
    else if (e === 'offline') { c.offline++; lojas.add(h.site_code); }
    else if (e === 'never') c.never++;
    else if (e === 'manutencao') c.manutencao++;
    else c.disabled++;

    if (c.versaoAlvo && h.agent_version && h.agent_version !== c.versaoAlvo) c.desatualizados++;
  }
  c.lojasComOffline = [...lojas];
  return c;
}

/** Compara ps-1.10.0 e ps-1.2.0 por NÚMERO. Como texto, 1.10 viria antes de 1.2. */
function compararVersao(a: string, b: string) {
  const n = (s: string) => (s.match(/\d+/g) ?? []).map(Number);
  const x = n(a); const y = n(b);
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const d = (x[i] ?? 0) - (y[i] ?? 0);
    if (d !== 0) return d;
  }
  return 0;
}

function porPerfil(hosts: Host[]) {
  const m = new Map<string, { n: number; soma: number; comCpu: number }>();
  for (const h of hosts) {
    const k = h.role_name ?? h.role_code;
    const v = m.get(k) ?? { n: 0, soma: 0, comCpu: 0 };
    v.n++;
    if (h.cpu_pct !== null) { v.soma += h.cpu_pct; v.comCpu++; }
    m.set(k, v);
  }
  return [...m].map(([perfil, v]) => ({
    perfil, n: v.n, cpu: v.comCpu ? v.soma / v.comCpu : null,
  })).sort((a, b) => (b.cpu ?? -1) - (a.cpu ?? -1));
}

function LinhaBarra({ rotulo, n, total, cor }: { rotulo: string; n: number; total: number; cor: string }) {
  const pct = total ? (100 * n) / total : 0;
  return (
    <div style={{ marginBottom: 9 }}>
      <div style={{ display: 'flex', fontSize: 11, marginBottom: 4 }}>
        <span style={{ color: 'var(--fg2)' }}>{rotulo}</span>
        <span className="mono" style={{ marginLeft: 'auto', color: n ? cor : 'var(--fg3)' }}>{n}</span>
      </div>
      <div style={{ height: 4, borderRadius: 4, background: 'var(--pnl2)', overflow: 'hidden' }}>
        <div style={{ height: '100%', width: `${pct}%`, background: cor, borderRadius: 4 }} />
      </div>
    </div>
  );
}
