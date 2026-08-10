// =============================================================================
// admin-usuarios — criar conta e trocar senha
// =============================================================================
// Existe porque criar conta exige a `service_role`, e a regra 1 do projeto diz
// que ela nunca aparece no agente, no dashboard, no repositório ou em qualquer
// artefato distribuído. Então o painel PEDE, e o segredo fica aqui.
//
// Diferente da `ingest`, esta função roda com `verify_jwt` LIGADO (o padrão): o
// gateway já recusa quem não tem JWT do Supabase. Isso não basta — um `viewer`
// também tem JWT válido. A checagem de que o chamador é admin é feita chamando o
// banco COM O TOKEN DELE: se `usuarios_do_painel()` responder, ele é admin.
//
// Essa é a parte que importa: a regra de quem pode conceder acesso continua no
// banco, num lugar só. Reimplementar "é admin?" aqui criaria uma segunda regra
// para divergir da primeira, e a daqui roda com a service_role — divergir para o
// lado permissivo custaria o sistema.
//
// O QUE ESTA FUNÇÃO NÃO FAZ: apagar conta. Revogar acesso (`user_roles`) já tira
// a pessoa do painel no pedido seguinte, e é reversível. Apagar a conta no auth é
// irreversível e não acrescenta segurança nenhuma sobre a revogação.
// =============================================================================

const URL_SUPABASE = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

// A chave pública, usada só como `apikey` do gateway quando a chamada leva o JWT
// de quem pediu. Ela não concede nada por si: o papel vem do Authorization.
const ANON = Deno.env.get('SUPABASE_ANON_KEY') ?? '';

// Origens que podem chamar. Lista fechada, e não `*`: com `*` qualquer página
// que a pessoa abrisse enquanto logada poderia criar admin no navegador dela.
// `ORIGENS_EXTRA` existe para o domínio próprio quando ele entrar.
const ORIGENS = [
  'https://monitoramento-cajupar.vercel.app',
  'http://127.0.0.1:8081',
  'http://localhost:8081',
  ...(Deno.env.get('ORIGENS_EXTRA') ?? '').split(',').map((o) => o.trim()).filter(Boolean),
];

function cabecalhosCors(origem: string | null): Record<string, string> {
  const permitida = origem && ORIGENS.includes(origem) ? origem : '';
  return {
    'Content-Type': 'application/json; charset=utf-8',
    // Sem origem casada, nenhum cabeçalho de liberação: o navegador barra a
    // leitura da resposta. Devolver o pedido feito seria pior que barrar.
    ...(permitida
      ? {
        'Access-Control-Allow-Origin': permitida,
        'Access-Control-Allow-Headers': 'authorization, content-type, apikey',
        'Access-Control-Allow-Methods': 'POST, OPTIONS',
        'Access-Control-Max-Age': '600',
        Vary: 'Origin',
      }
      : {}),
  };
}

function resposta(corpo: unknown, status: number, origem: string | null): Response {
  return new Response(JSON.stringify(corpo), { status, headers: cabecalhosCors(origem) });
}

/**
 * Senha temporária.
 *
 * `crypto.getRandomValues`, nunca `Math.random()`: senha inicial de conta que
 * administra a frota não pode sair de um gerador previsível.
 *
 * O alfabeto exclui `0O1lI` — a senha vai ser lida em voz alta ou copiada de um
 * chat, e "l" contra "1" custa uma ligação.
 */
function senhaTemporaria(): string {
  const alfabeto = 'ABCDEFGHJKMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
  const bytes = new Uint8Array(20);
  crypto.getRandomValues(bytes);
  let s = '';
  for (const b of bytes) s += alfabeto[b % alfabeto.length];
  // Um símbolo garante a política de complexidade sem depender do sorteio.
  return `${s.slice(0, 10)}-${s.slice(10)}`;
}

/**
 * Chama o PostgREST.
 *
 * `apikey` ANDA JUNTO COM O TOKEN, e nunca é a service_role numa chamada feita
 * com o token de outra pessoa. Eu tinha escrito `apikey: SERVICE_ROLE` nas duas
 * chamadas, e isso é o defeito mais perigoso possível aqui: se o gateway
 * resolvesse o papel pelo `apikey` em vez do `Authorization`, a conferência de
 * "é admin?" passaria para QUALQUER usuário logado — e o que vem depois dela
 * cria conta de administrador.
 *
 * Com o par certo, a checagem depende só do JWT de quem pediu.
 */
async function rpc(nome: string, corpo: unknown, token: string, apikey: string): Promise<Response> {
  return await fetch(`${URL_SUPABASE}/rest/v1/rpc/${nome}`, {
    method: 'POST',
    headers: {
      apikey,
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(corpo ?? {}),
  });
}

/** Admin API do auth, sempre com a service_role. */
async function auth(caminho: string, metodo: string, corpo?: unknown): Promise<Response> {
  return await fetch(`${URL_SUPABASE}/auth/v1/admin/${caminho}`, {
    method: metodo,
    headers: {
      apikey: SERVICE_ROLE,
      Authorization: `Bearer ${SERVICE_ROLE}`,
      'Content-Type': 'application/json',
    },
    ...(corpo === undefined ? {} : { body: JSON.stringify(corpo) }),
  });
}

Deno.serve(async (req: Request): Promise<Response> => {
  const origem = req.headers.get('origin');

  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: cabecalhosCors(origem) });
  }

  if (req.method !== 'POST') {
    return resposta({ erro: 'use POST' }, 405, origem);
  }

  if (!URL_SUPABASE || !SERVICE_ROLE || !ANON) {
    // Falha de configuração do servidor, não do pedido. Sem isto, uma variável
    // ausente viraria "credenciais inválidas" e alguém passaria a tarde
    // conferindo senha.
    return resposta({
      erro: 'funcao sem SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY ou SUPABASE_ANON_KEY',
    }, 500, origem);
  }

  const auth0 = req.headers.get('authorization') ?? '';
  const token = auth0.toLowerCase().startsWith('bearer ') ? auth0.slice(7).trim() : '';
  if (!token) return resposta({ erro: 'sem token' }, 401, origem);

  // ---------------------------------------------------------------- autorização
  // O BANCO decide. Ver o cabeçalho do arquivo.
  const conferencia = await rpc('usuarios_do_painel', {}, token, ANON);
  if (!conferencia.ok) {
    const detalhe = await conferencia.text();
    return resposta(
      { erro: 'apenas administradores podem gerenciar usuarios', detalhe: detalhe.slice(0, 300) },
      403,
      origem,
    );
  }
  const painel = await conferencia.json();
  const quemPediu: string | null = painel?.eu ?? null;

  let corpo: Record<string, unknown>;
  try {
    corpo = await req.json();
  } catch {
    return resposta({ erro: 'corpo nao e JSON' }, 400, origem);
  }

  const acao = String(corpo.acao ?? '');

  // ------------------------------------------------------------------- criar
  if (acao === 'criar') {
    const email = String(corpo.email ?? '').trim().toLowerCase();
    const nome = String(corpo.nome ?? '').trim();
    const role = String(corpo.role ?? 'viewer');
    const siteIds = Array.isArray(corpo.site_ids) ? corpo.site_ids.map(String) : null;

    if (!/^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$/.test(email)) {
      return resposta({ erro: `e-mail invalido: ${email}` }, 400, origem);
    }
    if (!['admin', 'operator', 'viewer'].includes(role)) {
      return resposta({ erro: `papel invalido: ${role}` }, 400, origem);
    }

    const senha = senhaTemporaria();

    // `email_confirm: true` de propósito: sem SMTP configurado no projeto, uma
    // conta que espera confirmação por e-mail nunca consegue entrar, e o admin
    // ficaria olhando um usuário criado que não loga.
    const criada = await auth('users', 'POST', {
      email,
      password: senha,
      email_confirm: true,
      user_metadata: { nome },
    });

    if (!criada.ok) {
      const detalhe = await criada.text();
      // 422 do auth para e-mail existente é o caso comum, e merece mensagem
      // própria em vez do JSON cru do GoTrue.
      const jaExiste = criada.status === 422 || detalhe.includes('already been registered');
      return resposta(
        {
          erro: jaExiste
            ? `ja existe conta com o e-mail ${email}`
            : 'o auth recusou criar a conta',
          detalhe: detalhe.slice(0, 300),
        },
        jaExiste ? 409 : 502,
        origem,
      );
    }

    const conta = await criada.json();
    const userId = conta?.id;
    if (!userId) {
      return resposta({ erro: 'o auth criou a conta sem devolver id' }, 502, origem);
    }

    // Papel e escopo. Se isto falhar, a conta existe e não tem acesso — estado
    // seguro, mas confuso. Por isso o erro DIZ que a conta ficou criada e como
    // consertar, em vez de só "falhou".
    const registro = await rpc('registrar_usuario_do_painel', {
      p_user_id: userId,
      p_email: email,
      p_nome: nome,
      p_role: role,
      p_site_ids: siteIds,
      p_por: quemPediu,
    }, SERVICE_ROLE, SERVICE_ROLE);

    if (!registro.ok) {
      const detalhe = await registro.text();
      return resposta(
        {
          erro: 'a conta foi criada, mas o papel nao foi gravado',
          conserto: 'conceda o acesso pela lista de usuarios do painel',
          user_id: userId,
          detalhe: detalhe.slice(0, 300),
        },
        502,
        origem,
      );
    }

    // A senha volta UMA vez. Não é gravada em lugar nenhum nosso: se for
    // perdida, o caminho é redefinir, não recuperar.
    return resposta({
      ok: true,
      user_id: userId,
      email,
      role,
      senha_temporaria: senha,
      aviso: 'Anote agora: esta senha nao aparece de novo. Repasse por canal privado.',
    }, 200, origem);
  }

  // ------------------------------------------------------------------- senha
  if (acao === 'senha') {
    const userId = String(corpo.user_id ?? '');
    if (!/^[0-9a-f-]{36}$/i.test(userId)) {
      return resposta({ erro: 'user_id invalido' }, 400, origem);
    }

    const senha = senhaTemporaria();
    const r = await auth(`users/${userId}`, 'PUT', { password: senha });

    if (!r.ok) {
      const detalhe = await r.text();
      return resposta(
        { erro: 'o auth recusou trocar a senha', detalhe: detalhe.slice(0, 300) },
        502,
        origem,
      );
    }

    return resposta({
      ok: true,
      user_id: userId,
      senha_temporaria: senha,
      aviso: 'Anote agora: esta senha nao aparece de novo.',
    }, 200, origem);
  }

  return resposta({ erro: `acao desconhecida: ${acao}` }, 400, origem);
});
