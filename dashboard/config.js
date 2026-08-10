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
  // restUrl fica VAZIO de propósito. Quem define a URL é o dev-config.json, que
  // o dev-up.ps1 gera com a porta que realmente foi escolhida.
  //
  // A versão anterior tinha 'http://127.0.0.1:3000' como padrão, e isso era um
  // defeito perigoso: se o dev-config.json não carregasse, o dashboard tentava
  // fazer login em QUALQUER COISA que estivesse na 3000. Nesta máquina a 3000 é
  // a API do WAHA de outro projeto, que responde 401 — e o sintoma era um login
  // que "não funciona" sem nenhuma pista do motivo.
  //
  // Vazio faz o dashboard PARAR e dizer o que está errado, em vez de conversar
  // com o serviço errado.
  restUrl: '',
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
  pollSeconds: 10,

  // Realtime do Supabase. Ignorado fora do modo supabase.
  realtime: true,
};
