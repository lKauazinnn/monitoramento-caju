// =============================================================================
// A casca — barra lateral, cabeçalho, e o estado que as 7 telas compartilham
// =============================================================================

import * as React from 'react';
import {
  Sentinela, Marca, Vista, CartaoLateral, Selo, Brinde,
} from '@cajupar/sentinela-ds';
import * as api from './api';
import type { Host, Loja } from './api';
import { Erro } from './comum';
import { Ico } from './icones';
import { Paleta } from './paleta';
import { Gaveta } from './gaveta';
import { TelaNOC } from './telas/noc';
import { TelaFrota } from './telas/frota';
import { TelaIncidente } from './telas/incidente';
import { TelaInventario } from './telas/inventario';
import { TelaAlertas } from './telas/alertas';
import { TelaAuditoria } from './telas/auditoria';
import { TelaPlantao } from './telas/plantao';

export type { Vistas } from './vistas';
import type { Vistas } from './vistas';

export interface Aviso { id: number; texto: string; tom: 'ok' | 'warn' | 'crit' | 'info'; }

const CHAVE_TEMA = 'monitor.tema';

/**
 * O relógio da telemetria.
 *
 * O protótipo usa 3200ms com jitter senoidal para simular dado vivo. Aqui não há
 * o que simular: o intervalo REBUSCA o servidor. A cadência vem da configuração
 * (`pollSeconds`, 20s por padrão) porque uma loja com link ruim não aguenta a
 * mesma frequência de um escritório — e o handoff pede que ela seja
 * configurável e pausável.
 */
function useTelemetria() {
  const [hosts, setHosts] = React.useState<Host[]>([]);
  const [lojas, setLojas] = React.useState<Loja[]>([]);
  const [erro, setErro] = React.useState<string | null>(null);
  const [carregando, setCarregando] = React.useState(true);
  const [pausado, setPausado] = React.useState(false);
  const [atualizadoEm, setAtualizadoEm] = React.useState<Date | null>(null);

  const buscar = React.useCallback(async () => {
    try {
      const [h, l] = await Promise.all([api.hosts(), api.lojas()]);
      setHosts(h); setLojas(l); setErro(null); setAtualizadoEm(new Date());
    } catch (e) {
      setErro((e as Error).message);
    } finally {
      setCarregando(false);
    }
  }, []);

  React.useEffect(() => {
    buscar();
    if (pausado) return;
    const seg = window.MONITOR_CONFIG?.pollSeconds ?? 20;
    const t = setInterval(buscar, seg * 1000);
    return () => clearInterval(t);
  }, [buscar, pausado]);

  return { hosts, lojas, erro, carregando, buscar, pausado, setPausado, atualizadoEm };
}

export function App() {
  const [vista, setVista] = React.useState<Vistas>('noc');
  const [tema, setTema] = React.useState<'escuro' | 'claro'>(() => {
    try { return (localStorage.getItem(CHAVE_TEMA) as 'escuro' | 'claro') ?? 'escuro'; }
    catch { return 'escuro'; }
  });
  const [paleta, setPaleta] = React.useState(false);
  const [gaveta, setGaveta] = React.useState<string | null>(null);
  const [avisos, setAvisos] = React.useState<Aviso[]>([]);
  const [marca, setMarca] = React.useState('todas');
  const [relogio, setRelogio] = React.useState(() => new Date());

  const tel = useTelemetria();

  // ---------------------------------------------------------------- avisos
  const avisar = React.useCallback((texto: string, tom: Aviso['tom'] = 'ok') => {
    const id = Date.now() + Math.floor(performance.now() % 1000);
    setAvisos((a) => [...a, { id, texto, tom }]);
    // 4200ms, como o handoff especifica. Nenhuma ação é silenciosa.
    setTimeout(() => setAvisos((a) => a.filter((x) => x.id !== id)), 4200);
  }, []);

  // ------------------------------------------------------------------ tema
  React.useEffect(() => {
    document.documentElement.dataset.tema = tema === 'claro' ? 'light' : 'dark';
    try { localStorage.setItem(CHAVE_TEMA, tema); } catch { /* modo privado */ }
  }, [tema]);

  // --------------------------------------------------------------- relógio
  React.useEffect(() => {
    const t = setInterval(() => setRelogio(new Date()), 1000);
    return () => clearInterval(t);
  }, []);

  // ------------------------------------------------------------------- ⌘K
  React.useEffect(() => {
    const aoTeclar = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
        e.preventDefault();
        setPaleta((p) => !p);
      }
      // Esc fecha o que estiver por cima, de fora para dentro.
      if (e.key === 'Escape') {
        if (paleta) setPaleta(false);
        else if (gaveta) setGaveta(null);
      }
    };
    window.addEventListener('keydown', aoTeclar);
    return () => window.removeEventListener('keydown', aoTeclar);
  }, [paleta, gaveta]);

  // ---------------------------------------------------------------- escopo
  const hostsDoEscopo = React.useMemo(
    () => (marca === 'todas' ? tel.hosts : tel.hosts.filter((h) => h.brand_code === marca)),
    [tel.hosts, marca],
  );

  const contagem = React.useMemo(() => {
    const c = { ok: 0, degradado: 0, offline: 0, never: 0, manutencao: 0, total: 0 };
    for (const h of hostsDoEscopo) {
      const e = api.estadoDe(h);
      c.total++;
      if (e === 'online') c.ok++;
      else if (e === 'degradado') c.degradado++;
      else if (e === 'offline') c.offline++;
      else if (e === 'never') c.never++;
      else if (e === 'manutencao') c.manutencao++;
    }
    return c;
  }, [hostsDoEscopo]);

  const marcas = React.useMemo(() => {
    const m = new Map<string, string>();
    for (const h of tel.hosts) m.set(h.brand_code, h.brand_name);
    return [...m].map(([code, name]) => ({ code, name }));
  }, [tel.hosts]);

  const hostAberto = tel.hosts.find((h) => h.machine_id === gaveta) ?? null;

  const abrirHost = React.useCallback((id: string) => setGaveta(id), []);

  const irPara = React.useCallback((v: Vistas) => { setVista(v); setPaleta(false); }, []);

  // -------------------------------------------------------------- render
  const props = {
    hosts: hostsDoEscopo, todosHosts: tel.hosts, lojas: tel.lojas,
    abrirHost, avisar, irPara, carregando: tel.carregando,
  };

  return (
    <Sentinela tema={tema}>
      <div style={{ display: 'grid', gridTemplateColumns: '224px minmax(0, 1fr)', minHeight: '100vh' }}>

        {/* ---------------------------------------------------- lateral --- */}
        <aside
          style={{
            position: 'sticky', top: 0, height: '100vh',
            display: 'flex', flexDirection: 'column', gap: 14,
            padding: '16px 12px', background: 'var(--chrome)',
            backdropFilter: 'blur(20px)', borderRight: '1px solid var(--bd2)',
            overflowY: 'auto',
          }}
        >
          <Marca escopo={`${tel.lojas.length} loja(s) · ${contagem.total} máquina(s)`} />

          <nav style={{ display: 'grid', gap: 2 }}>
            <span className="secao-lateral mono">Operação</span>
            <Vista rotulo="Visão geral" icone={<Ico n="grade" />} contagem={contagem.total}
                   ativa={vista === 'noc'} onClick={() => setVista('noc')} />
            <Vista rotulo="Frota" icone={<Ico n="servidor" />} contagem={contagem.total}
                   ativa={vista === 'frota'} onClick={() => setVista('frota')} />
            <Vista rotulo="Incidente" icone={<Ico n="aviso" />} contagem={contagem.offline}
                   tom={contagem.offline ? 'ruim' : 'neutro'}
                   ativa={vista === 'incidente'} onClick={() => setVista('incidente')} />
          </nav>

          <nav style={{ display: 'grid', gap: 2 }}>
            <span className="secao-lateral mono">Gestão</span>
            <Vista rotulo="Inventário" icone={<Ico n="caixa" />}
                   ativa={vista === 'inventario'} onClick={() => setVista('inventario')} />
            <Vista rotulo="Regras & ruído" icone={<Ico n="sino" />}
                   ativa={vista === 'alertas'} onClick={() => setVista('alertas')} />
            <Vista rotulo="Auditoria" icone={<Ico n="escudo" />}
                   ativa={vista === 'auditoria'} onClick={() => setVista('auditoria')} />
            <Vista rotulo="Plantão" icone={<Ico n="telefone" />}
                   ativa={vista === 'plantao'} onClick={() => setVista('plantao')} />
          </nav>

          <CartaoLateral
            titulo="Telemetria"
            valor={tel.atualizadoEm ? tel.atualizadoEm.toLocaleTimeString('pt-BR') : '—'}
            nota={tel.pausado ? 'atualização pausada'
              : `a cada ${window.MONITOR_CONFIG?.pollSeconds ?? 20}s`}
            tom={tel.erro ? 'ruim' : tel.pausado ? 'alerta' : 'ok'}
          />

          <div style={{ marginTop: 'auto', display: 'grid', gap: 6 }}>
            <BotaoLateral
              icone={tema === 'escuro' ? 'sol' : 'lua'}
              rotulo={tema === 'escuro' ? 'Tema claro' : 'Tema escuro'}
              onClick={() => setTema(tema === 'escuro' ? 'claro' : 'escuro')}
            />
            <BotaoLateral
              icone="refresh"
              rotulo={tel.pausado ? 'Retomar atualização' : 'Pausar atualização'}
              onClick={() => { tel.setPausado(!tel.pausado); avisar(tel.pausado ? 'Atualização retomada.' : 'Atualização pausada.', 'info'); }}
            />
            <BotaoLateral icone="chave" rotulo="Sair" onClick={api.encerrarSessao} />
          </div>
        </aside>

        {/* ------------------------------------------------------ principal --- */}
        <main style={{ minWidth: 0, display: 'flex', flexDirection: 'column' }}>
          <header
            style={{
              position: 'sticky', top: 0, zIndex: 5,
              display: 'flex', alignItems: 'center', gap: 14,
              padding: '11px 22px', background: 'var(--chrome)',
              backdropFilter: 'blur(20px)', borderBottom: '1px solid var(--bd2)',
            }}
          >
            <div style={{ minWidth: 0 }}>
              <span className="mono" style={{
                fontSize: 8.5, letterSpacing: '.12em', textTransform: 'uppercase', color: 'var(--fg3)',
              }}>
                Cajupar · tempo real
              </span>
              <h1 style={{ margin: 0, fontSize: 18, fontWeight: 700, letterSpacing: '-.02em' }}>
                {TITULO[vista]}
              </h1>
            </div>

            <button
              type="button"
              onClick={() => setPaleta(true)}
              style={{
                display: 'flex', alignItems: 'center', gap: 8, marginLeft: 18,
                padding: '7px 12px', minWidth: 260,
                borderRadius: 'var(--r-m)', border: '1px solid var(--bd)',
                background: 'var(--pnl2)', color: 'var(--fg3)',
                fontFamily: 'var(--fonte)', fontSize: 12, cursor: 'pointer',
              }}
            >
              <Ico n="busca" />
              <span style={{ flex: 1, textAlign: 'left' }}>máquina, loja, IP, comando</span>
              <span className="mono" style={{
                fontSize: 9, padding: '2px 5px', borderRadius: 4,
                border: '1px solid var(--bd)', color: 'var(--fg3)',
              }}>⌘K</span>
            </button>

            <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 8 }}>
              <Selo tom="ok" valor={contagem.ok} zero={contagem.ok === 0}>ok</Selo>
              <Selo tom="alerta" valor={contagem.degradado} zero={contagem.degradado === 0}>degradados</Selo>
              <Selo tom="ruim" valor={contagem.offline} zero={contagem.offline === 0}>offline</Selo>
              <span className="mono" style={{ fontSize: 11, color: 'var(--fg3)', marginLeft: 6 }}>
                {relogio.toLocaleTimeString('pt-BR')}
              </span>
            </div>
          </header>

          <div style={{ padding: '18px 22px 40px', display: 'grid', gap: 16, minWidth: 0 }}>
            {tel.erro && <Erro msg={tel.erro} onTentar={tel.buscar} />}

            {vista === 'noc' && (
              <TelaNOC {...props} marca={marca} setMarca={setMarca} marcas={marcas} />
            )}
            {vista === 'frota' && <TelaFrota {...props} />}
            {vista === 'incidente' && <TelaIncidente {...props} />}
            {vista === 'inventario' && <TelaInventario {...props} />}
            {vista === 'alertas' && <TelaAlertas {...props} />}
            {vista === 'auditoria' && <TelaAuditoria {...props} />}
            {vista === 'plantao' && <TelaPlantao {...props} />}
          </div>
        </main>
      </div>

      {paleta && (
        <Paleta
          hosts={tel.hosts}
          onFechar={() => setPaleta(false)}
          onIr={irPara}
          onHost={(id) => { setGaveta(id); setPaleta(false); }}
          onTema={() => { setTema(tema === 'escuro' ? 'claro' : 'escuro'); setPaleta(false); }}
        />
      )}

      {hostAberto && (
        <Gaveta host={hostAberto} onFechar={() => setGaveta(null)} avisar={avisar} />
      )}

      {/* Empilhados no canto inferior direito, como o handoff especifica. */}
      <div style={{
        position: 'fixed', right: 18, bottom: 18, zIndex: 60,
        display: 'grid', gap: 9, justifyItems: 'end',
      }}>
        {avisos.map((a) => (
          <Brinde key={a.id} mensagem={a.texto} erro={a.tom === 'crit'} />
        ))}
      </div>
    </Sentinela>
  );
}

const TITULO: Record<Vistas, string> = {
  noc: 'Centro de operações',
  frota: 'Frota',
  incidente: 'Incidente',
  inventario: 'Inventário',
  alertas: 'Regras & ruído',
  auditoria: 'Auditoria',
  plantao: 'Plantão',
};

function BotaoLateral({ icone, rotulo, onClick }: { icone: string; rotulo: string; onClick: () => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      style={{
        display: 'flex', alignItems: 'center', gap: 10, width: '100%',
        padding: '7px 9px', borderRadius: 9, border: '1px solid transparent',
        background: 'none', color: 'var(--fg2)',
        fontFamily: 'var(--fonte)', fontSize: 12.5, cursor: 'pointer', textAlign: 'left',
        transition: 'background .12s, color .12s',
      }}
      onMouseEnter={(e) => { e.currentTarget.style.background = 'var(--hov)'; }}
      onMouseLeave={(e) => { e.currentTarget.style.background = 'none'; }}
    >
      <Ico n={icone} />
      <span>{rotulo}</span>
    </button>
  );
}
