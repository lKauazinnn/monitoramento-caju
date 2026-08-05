// =============================================================================
// Configuração do dashboard
// =============================================================================
// Para apontar ao Supabase, troque as três primeiras linhas de MONITOR_CONFIG.
// Nada aqui é segredo: a anon key é pública por desenho e o que protege os dados
// é o RLS (regra 3). A service_role_key NUNCA entra neste arquivo — ela só
// existe como variável de ambiente do lado servidor (regra 1).
// =============================================================================

window.MONITOR_CONFIG = {
  // ---------------------------------------------------------------------------
  // MODO LOCAL (padrão): PostgREST do docker-compose
  // ---------------------------------------------------------------------------
  // A URL é sobrescrita em tempo de execução por dev-config.json, que o
  // dev-up.ps1 gera com a porta efetivamente escolhida.
  restUrl: 'http://127.0.0.1:3000',
  anonKey: '',        // PostgREST local não exige apikey
  authMode: 'local',  // login real: e-mail + senha verificados com bcrypt no banco

  // ---------------------------------------------------------------------------
  // MODO SUPABASE: descomente e preencha
  // ---------------------------------------------------------------------------
  // restUrl: 'https://SEUPROJETO.supabase.co/rest/v1',
  // authUrl: 'https://SEUPROJETO.supabase.co/auth/v1',
  // anonKey: 'eyJ...sua anon key...',
  // authMode: 'supabase',

  // Intervalo do polling. É o fallback quando Realtime não está disponível —
  // e no modo local ele é o único caminho, porque PostgREST não tem Realtime.
  pollSeconds: 20,

  // Realtime do Supabase. Ignorado fora do modo supabase.
  realtime: true,
};
