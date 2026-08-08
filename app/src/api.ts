// =============================================================================
// A camada de dados — e a fronteira entre o que se mede e o que se inventa
// =============================================================================
// REGRA QUE MANDA NESTE ARQUIVO: nenhuma funcao aqui devolve numero que ninguem
// mediu. Quando um dado nao existe, ela devolve `null` e a tela mostra
// travessao — nunca um valor plausivel.
//
// O motivo e concreto: um painel de operacao que mostra "CPU 42%" para uma
// maquina que nao reporta CPU treina a pessoa a nao confiar em NENHUM numero da
// tela, inclusive nos que estao certos. Um travessao e feio e honesto; um numero
// inventado e bonito e corrosivo.
//
// Por isso `AUSENTE` existe e e exportado: telas cujo dado nao e coletado ainda
// (inventario, war-room) declaram isso explicitamente, e o componente `SemDado`
// desenha a faixa. Elas NAO recebem dado de exemplo.
// =============================================================================

declare global {
  interface Window {
    MONITOR_CONFIG?: {
      restUrl: string;
      authUrl: string;
      anonKey: string;
      authMode: string;
      pollSeconds?: number;
    };
  }
}

const cfg = () => {
  const c = window.MONITOR_CONFIG;
  if (!c) throw new Error('config.js não carregou — o painel não sabe com qual servidor falar');
  return c;
};

const CHAVE_SESSAO = 'monitor.token';

/**
 * A sessão, no formato que o painel antigo já usa.
 *
 * `sessionStorage` e não `localStorage`, e um OBJETO `{token, usuario}` e não a
 * string crua — esse é o formato que `login.html` grava e que o painel atual lê.
 * Os dois painéis compartilham a sessão de propósito: durante a transição, quem
 * entrar num deve continuar dentro no outro, sem digitar a senha de novo.
 *
 * (Escrevi `localStorage.getItem` aqui na primeira versão e o painel novo abria
 * sempre deslogado, sem erro nenhum — a chamada devolvia `null` e a tela ia
 * calada para o login.)
 */
export interface Sessao { token: string; usuario: string; }

export function sessao(): Sessao | null {
  try {
    const bruto = sessionStorage.getItem(CHAVE_SESSAO);
    if (!bruto) return null;
    const s = JSON.parse(bruto) as Sessao;
    return s?.token ? s : null;
  } catch { return null; }
}

export const tokenDaSessao = (): string | null => sessao()?.token ?? null;

export function encerrarSessao() {
  try { sessionStorage.removeItem(CHAVE_SESSAO); } catch { /* modo privado */ }
  location.href = './login.html';
}

/**
 * Uma chamada ao PostgREST.
 *
 * 401 leva para o login em vez de mostrar tela vazia: sessao expirada e o caso
 * mais comum de "o painel parou de funcionar", e uma grade vazia nao diz isso.
 */
async function chamar<T>(caminho: string, opcoes: RequestInit = {}): Promise<T> {
  const c = cfg();
  const tok = tokenDaSessao();

  const r = await fetch(`${c.restUrl}${caminho}`, {
    ...opcoes,
    headers: {
      apikey: c.anonKey,
      authorization: `Bearer ${tok ?? c.anonKey}`,
      'content-type': 'application/json',
      ...(opcoes.headers ?? {}),
    },
  });

  if (r.status === 401 || r.status === 403) {
    encerrarSessao();
    throw new Error('sessão expirada');
  }

  if (!r.ok) {
    const texto = await r.text();
    let msg = texto;
    try { msg = JSON.parse(texto).message ?? texto; } catch { /* corpo não-JSON */ }
    throw new Error(msg || `HTTP ${r.status}`);
  }

  return r.status === 204 ? (null as T) : r.json();
}

export const rpc = <T>(nome: string, args: Record<string, unknown> = {}) =>
  chamar<T>(`/rpc/${nome}`, { method: 'POST', body: JSON.stringify(args) });

export const ler = <T>(recurso: string) => chamar<T>(`/${recurso}`);

// -----------------------------------------------------------------------------
// Tipos — o contrato com o banco
// -----------------------------------------------------------------------------

export type EstadoMaquina =
  | 'online' | 'degradado' | 'offline' | 'never' | 'manutencao' | 'disabled';

export interface Host {
  machine_id: string;
  label: string;
  hostname: string | null;
  role_code: string;
  role_name: string | null;
  site_id: string;
  site_code: string;
  site_name: string;
  site_timezone: string | null;
  brand_code: string;
  brand_name: string;
  status: 'online' | 'offline' | 'never_seen';
  is_active: boolean;
  in_maintenance: boolean;
  last_seen_at: string | null;
  last_boot_at: string | null;
  seconds_since_seen: number | null;
  agent_version: string | null;
  os_caption: string | null;
  cpu_model: string | null;
  cpu_cores: number | null;
  mem_total_mb: number | null;
  ip_lan: string | null;
  mac_address: string | null;
  mac_is_wifi: boolean | null;
  clock_drift_seconds: number | null;

  // Medidas da ultima amostra. TODAS podem ser null — uma maquina offline nao
  // reporta nada, e uma recem-cadastrada nunca reportou.
  cpu_pct: number | null;
  mem_pct: number | null;
  cpu_temp_c: number | null;
  gw_latency_ms: number | null;
  gw_loss_pct: number | null;
  uptime_seconds: number | null;
  disk_min_free_pct: number | null;
  disk_min_free_gb: number | null;
  disk_worst_drive: string | null;
  services_down: number | null;
  services_down_names: string[] | null;
  collect_flags: string[] | null;
}

/**
 * O estado que a INTERFACE usa, que nao e o mesmo que o banco guarda.
 *
 * `degradado` e derivado: a maquina responde, mas tem servico parado, disco no
 * limite ou coletor falhando. Sem ele, ela ficaria verde ao lado de uma
 * saudavel — e o problema so apareceria quando alguem da loja reclamasse.
 *
 * O handoff pede que isto seja calculado NO SERVIDOR para alerta e painel nunca
 * discordarem. Enquanto a view do banco nao expoe a coluna, esta funcao e a
 * unica fonte — e ela usa exatamente os mesmos limiares do avaliador de
 * alertas. Quando a coluna existir, esta funcao vira uma leitura.
 */
export function estadoDe(h: Host): EstadoMaquina {
  if (!h.is_active) return 'disabled';
  if (h.in_maintenance) return 'manutencao';
  if (h.status === 'never_seen') return 'never';
  if (h.status === 'offline') return 'offline';

  if ((h.services_down ?? 0) > 0) return 'degradado';
  if (h.disk_min_free_pct !== null && h.disk_min_free_pct <= 10) return 'degradado';
  if ((h.collect_flags ?? []).some((f) => f.startsWith('erro_') || f === 'smart_failing')) {
    return 'degradado';
  }
  return 'online';
}

/** O que esta errado nesta maquina, em texto. Vazio quando nada esta. */
export function problemasDe(h: Host): string[] {
  const p: string[] = [];
  if (!h.is_active) p.push('desativada');
  if (h.in_maintenance) p.push('em manutenção');
  if (h.status === 'offline') p.push('sem contato');
  if (h.status === 'never_seen') p.push('nunca reportou');
  if ((h.services_down ?? 0) > 0) {
    p.push(`${h.services_down} serviço(s) parado(s)`
      + (h.services_down_names?.length ? `: ${h.services_down_names.join(', ')}` : ''));
  }
  if (h.disk_min_free_pct !== null && h.disk_min_free_pct <= 10) {
    p.push(`disco ${h.disk_worst_drive ?? '?'} com ${h.disk_min_free_pct.toFixed(0)}% livre`);
  }
  for (const f of h.collect_flags ?? []) {
    if (f.startsWith('erro_')) p.push(`coletor ${f.slice(5)} falhando`);
    if (f === 'smart_failing') p.push('SMART prevendo falha de disco');
  }
  return p;
}

export const hosts = () =>
  ler<Host[]>('machines_status?order=label.asc');

/**
 * A loja, como o banco a expoe.
 *
 * Os nomes seguem a view, nao o que seria bonito em TypeScript: um tipo que
 * renomeia campo obriga uma traducao no meio, e e nessa traducao que um campo
 * some sem ninguem notar. `vpn_subnet` e `gateway_ip` ja existem — o handoff
 * pede a subnet no cartao da loja, e ela nao precisou ser inventada.
 */
export interface Loja {
  site_id: string;
  site_code: string;
  site_name: string;
  city: string | null;
  state: string | null;
  vpn_subnet: string | null;
  gateway_ip: string | null;
  is_active: boolean;
  brand_code: string;
  brand_name: string;
  machines_total: number;
  machines_online: number;
  machines_offline: number;
  machines_never_seen: number;
  machines_disabled: number;
  machines_in_maintenance: number;
  last_contact_at: string | null;
  cpu_avg_online: number | null;
  disk_min_free_pct: number | null;
}

export const lojas = () => ler<Loja[]>('sites_status?order=site_code.asc');

/** Situacao da loja inteira, para a cor do cartao. */
export function situacaoDa(l: Loja): 'estavel' | 'atencao' | 'incidente' | 'parada' {
  const vivas = l.machines_total - l.machines_disabled;
  if (vivas > 0 && l.machines_online === 0) return 'parada';
  if (l.machines_offline > 0) return 'incidente';
  if ((l.disk_min_free_pct !== null && l.disk_min_free_pct <= 10)
      || (l.cpu_avg_online !== null && l.cpu_avg_online >= 85)) return 'atencao';
  return 'estavel';
}

export interface Evento {
  event_id: number;
  machine_id: string | null;
  machine_label: string | null;
  site_code: string | null;
  kind: string;
  severity: 'info' | 'warning' | 'critical';
  message: string;
  opened_at: string;
  resolved_at: string | null;
  acknowledged_at: string | null;
}

export const eventos = (limite = 200) =>
  ler<Evento[]>(`events?order=opened_at.desc&limit=${limite}`);

export interface Regra {
  id: string;
  name: string;
  kind: string;
  scope: string;
  threshold: number | null;
  comparator: string;
  consecutive_cycles: number;
  cooldown_minutes: number;
  severity: string;
  is_active: boolean;
}

export const regras = () => ler<Regra[]>('alert_rules?order=name.asc');

export interface ComandoDaMaquina {
  id: string;
  machine_id: string;
  kind: string;
  status: string;
  dry_run: boolean;
  origem: string;
  created_at: string;
  finished_at: string | null;
  result_ok: boolean | null;
  result_text: string | null;
  em_andamento: boolean;
}

export const comandosDa = (machineId: string) =>
  ler<ComandoDaMaquina[]>(
    `comandos_da_maquina?machine_id=eq.${machineId}&order=created_at.desc&limit=12`);

// -----------------------------------------------------------------------------
// O que NAO existe
// -----------------------------------------------------------------------------

/**
 * Marca uma capacidade que o sistema ainda nao tem.
 *
 * A tela que depende de uma destas NAO inventa dado: ela desenha o layout e uma
 * faixa dizendo o que falta e por que. Ver o componente `SemDado`.
 */
export const AUSENTE = {
  incidentes: {
    o_que: 'Incidentes correlacionados',
    porque: 'A tabela `incidents` e o motor de correlação ainda não existem — é o '
      + 'pilar 2 da fase de ação remota, que não começou. Hoje cada alerta é '
      + 'independente: 12 hosts na mesma subnet caindo geram 12 alertas, não um.',
    falta: 'Migração de topologia + `incidents` + o job de correlação no pg_cron de 5 min.',
  },
  runbooks: {
    o_que: 'Runbooks',
    porque: 'Não há tabela de runbook nem registro de passo executado.',
    falta: 'Tabela `runbooks` + gravação de cada passo na trilha de auditoria.',
  },
  inventario: {
    o_que: 'Inventário de hardware e software',
    porque: 'O agente coleta CPU, memória, disco, serviços e rede — mas não modelo '
      + 'do equipamento, ano de aquisição, nem a lista de software instalado.',
    falta: 'Coletores novos no agente (`Win32_ComputerSystem`, `Win32_Product`) e '
      + 'as tabelas para guardar o resultado.',
  },
  cadeiaDeHash: {
    o_que: 'Cadeia de hash da auditoria',
    porque: 'Os eventos são gravados, mas sem encadeamento criptográfico — nada '
      + 'impede que uma linha seja alterada sem deixar rastro.',
    falta: 'Coluna de hash em `events` + gatilho que encadeia cada linha na anterior.',
  },
} as const;

export type Ausencia = typeof AUSENTE[keyof typeof AUSENTE];

// -----------------------------------------------------------------------------
// Séries temporais
// -----------------------------------------------------------------------------

export interface PontoHistorico {
  bucket: string;
  cpu_avg: number | null;
  cpu_max: number | null;
  mem_avg: number | null;
  temp_avg: number | null;
  disk_min_free_pct: number | null;
  gw_latency_avg: number | null;
  samples: number;
}

/**
 * O histórico de UMA máquina.
 *
 *  lê a métrica crua;  e  leem a consolidação horária
 * ponderada por amostra. Quem decide isso é o servidor — a tela só pede a faixa.
 */
export const historico = (machineId: string, faixa: '24h' | '7d' | '30d' = '24h') =>
  rpc<PontoHistorico[]>('machine_history', { p_machine_id: machineId, p_range: faixa });

/**
 * A carga da FROTA: a média de cada instante entre as máquinas do escopo.
 *
 * Não existe RPC para isso, então é composto no cliente a partir do histórico de
 * cada máquina. Com dezenas de máquinas isso vira dezenas de chamadas — quando o
 * parque crescer, vira uma função no servidor. Está anotado em PENDENTE.md.
 */
export async function cargaDaFrota(ids: string[], faixa: '24h' | '7d' | '30d' = '24h') {
  if (ids.length === 0) return [] as { t: number; cpu: number | null; mem: number | null }[];

  const series = await Promise.all(
    ids.slice(0, 24).map((id) => historico(id, faixa).catch(() => [] as PontoHistorico[])),
  );

  // Agrupa por instante. Máquina que não reportou naquele minuto simplesmente
  // não entra na média — ela não puxa o número para baixo fingindo zero.
  const m = new Map<number, { cpu: number[]; mem: number[] }>();
  for (const s of series) {
    for (const p of s) {
      const t = +new Date(p.bucket);
      const v = m.get(t) ?? { cpu: [], mem: [] };
      if (p.cpu_avg !== null) v.cpu.push(p.cpu_avg);
      if (p.mem_avg !== null) v.mem.push(p.mem_avg);
      m.set(t, v);
    }
  }

  return [...m].sort((a, b) => a[0] - b[0]).map(([t, v]) => ({
    t,
    cpu: v.cpu.length ? v.cpu.reduce((a, b) => a + b, 0) / v.cpu.length : null,
    mem: v.mem.length ? v.mem.reduce((a, b) => a + b, 0) / v.mem.length : null,
  }));
}
