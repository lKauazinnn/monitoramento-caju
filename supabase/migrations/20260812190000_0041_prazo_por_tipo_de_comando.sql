-- =============================================================================
-- 0041 — Prazo na fila depende do tipo do comando
-- =============================================================================
-- Os 30 minutos de `command_ttl_minutes` brigavam com o limite de 10 comandos por
-- loja a cada 10 minutos: numa loja de 13 máquinas, as últimas nem eram
-- enfileiradas antes das primeiras expirarem. Numa atualização de frota, 28
-- comandos morreram sem serem executados — e loja que fecha à noite nunca recebia
-- nada.
--
-- A correção óbvia seria subir o valor global. ELA ESTÁ ERRADA, e é bom dizer por
-- quê: `command_ttl_minutes` vale para TODO comando. Um `restart_machine`
-- enfileirado às 18h com prazo de 24h dispararia amanhã de manhã, quando a
-- máquina voltasse — reinício surpresa num PDV em horário de loja. Trocar
-- inconveniência por armadilha não é conserto.
--
-- Então o prazo passa a depender do tipo:
--
--   update_agent   -> 24h. Trocar versão de agente não tem hora certa, é
--                     idempotente, e não interrompe ninguém.
--   destrutivo     -> 30 min, como sempre. Reinício e suspensão precisam
--                     acontecer perto de quem pediu, ou não acontecer.
--   resto          -> 30 min.
--
-- FEITO POR TRIGGER, e a escolha merece explicação: o natural seria alterar
-- `enfileirar_comando`, que é onde o prazo é calculado. Mas ela tem 120 linhas de
-- guardrails (rajada, duplicata, cooldown de reinício, validação) e recriá-la
-- inteira para mudar UMA expressão significa copiar tudo — cada cópia é uma
-- chance de perder um guardrail no caminho, e eu já perdi coisa hoje copiando.
--
-- O custo é que a regra passa a viver em dois lugares. Este comentário é a
-- ligação entre eles, e o teste 14 é o que impede que divirjam em silêncio.
-- =============================================================================

insert into public.app_settings (key, value, description)
values ('command_ttl_update_agent_minutes', '1440',
        'Minutos que um update_agent espera na fila. Separado do TTL geral porque '
        'trocar versao de agente nao tem hora e nao interrompe ninguem -- ao contrario '
        'de reinicio, que precisa acontecer perto de quem pediu.')
on conflict (key) do nothing;

create or replace function public.prazo_do_comando()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_ttl integer;
begin
  -- Só o caminho longo. O curto já é o padrão que `enfileirar_comando` aplicou, e
  -- reafirmá-lo aqui criaria duas fontes para o mesmo número.
  if new.kind = 'update_agent' and not public.comando_e_destrutivo(new.kind) then
    v_ttl := public.app_setting_int('command_ttl_update_agent_minutes');
    if v_ttl is not null and v_ttl > 0 then
      -- A partir de `not_before`, não de now(): comando agendado para as 4h da
      -- manhã tem que ter as 24h contadas dali, senão ele expira antes da hora
      -- marcada.
      new.expires_at := coalesce(new.not_before, now()) + make_interval(mins => v_ttl);
    end if;
  end if;

  return new;
end
$fn$;

comment on function public.prazo_do_comando() is
  'Estende o prazo de update_agent para 24h. Ver o cabecalho da migracao 0041: a '
  'regra vive aqui e nao em enfileirar_comando para nao copiar 120 linhas de '
  'guardrail so para mudar uma expressao.';

drop trigger if exists trg_prazo_do_comando on public.agent_commands;
create trigger trg_prazo_do_comando
  before insert on public.agent_commands
  for each row execute function public.prazo_do_comando();

-- Os que expiraram sem executar voltam para a fila com o prazo novo. Sem isto a
-- frota só fecharia no próximo clique — e o usuário clicou achando que já estava
-- feito.
-- Voltar para `pending` exige limpar TODAS as marcas de conclusão, não só o
-- resultado: `sent_at`, `acked_at` e `finished_at` também. A primeira versão
-- deste UPDATE deixou `finished_at` preenchido e a constraint `ac_fim_ck`
-- recusou a linha — corretamente. Um comando "pendente" com hora de término é
-- um estado que não existe, e é bom que o banco não deixe passar.
update public.agent_commands
   set status = 'pending',
       expires_at = now() + make_interval(
         mins => public.app_setting_int('command_ttl_update_agent_minutes')),
       sent_at     = null,
       acked_at    = null,
       finished_at = null,
       result_ok   = null,
       result_text = null,
       result_payload = null
 where kind = 'update_agent'
   and status = 'expired'
   and created_at > now() - interval '6 hours';
