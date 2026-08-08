// =============================================================================
// Configuracao do dashboard - PRODUCAO (Supabase)
// =============================================================================
// Gerado por scripts/publicar-supabase.ps1.
//
// PARA USAR: copie sobre o config.js.
//     Copy-Item dashboard\config.producao.js dashboard\config.js -Force
//
// Para voltar a stack local: git checkout dashboard/config.js
//
// Nada aqui e segredo. A anon key e publica por desenho e o que protege os dados
// e o RLS (regra 3). A service_role_key NUNCA entra neste arquivo, e o segredo da
// ingestao tambem nao: ele vem do banco, so para admin (regra 1).
// =============================================================================

window.MONITOR_CONFIG = {
  restUrl: 'https://zrdglshzhlflnakflnki.supabase.co/rest/v1',
  authUrl: 'https://zrdglshzhlflnakflnki.supabase.co/auth/v1',
  anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpyZGdsc2h6aGxmbG5ha2ZsbmtpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODYwNDAxMDcsImV4cCI6MjEwMTYxNjEwN30.9PD5zWPK9KFbMQpsQAg8zVHL0Enat8uOK2SLtBe7yXo',
  authMode: 'supabase',

  pollSeconds: 20,
  realtime: true,
};