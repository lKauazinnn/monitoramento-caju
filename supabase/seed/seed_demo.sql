-- =============================================================================
-- Seed de exemplo — 2 marcas, 3 lojas, 5 máquinas
-- =============================================================================
-- Idempotente: UUIDs fixos + on conflict do nothing.
-- NÃO emite tokens. Token só nasce em provision_machine(), que devolve o texto
-- claro uma única vez — colocá-lo num arquivo de seed violaria a regra 1.
--
-- Os códigos de loja aqui são PLACEHOLDER. Substitua pelos códigos do ERP antes
-- de instalar qualquer agente: o código vai para o config.json e mudá-lo depois
-- significa reconfigurar máquina por máquina.
-- =============================================================================

insert into public.brands (id, code, name, notify_emails) values
  ('11111111-1111-4111-8111-111111111111', 'CJP',   'Cajupar',        '{}'),
  ('22222222-2222-4222-8222-222222222222', 'BRASA', 'Brasa Grill',    '{}')
on conflict do nothing;

insert into public.sites (id, brand_id, code, name, city, state, vpn_subnet, gateway_ip) values
  ('aaaaaaaa-0001-4001-8001-000000000001',
   '11111111-1111-4111-8111-111111111111',
   'BSB-001', 'Cajupar Asa Sul',        'Brasília',  'DF', '10.10.1.0/24',  '10.10.1.1'),
  ('aaaaaaaa-0002-4002-8002-000000000002',
   '11111111-1111-4111-8111-111111111111',
   'BSB-002', 'Cajupar Águas Claras',   'Brasília',  'DF', '10.10.2.0/24',  '10.10.2.1'),
  ('aaaaaaaa-0003-4003-8003-000000000003',
   '22222222-2222-4222-8222-222222222222',
   'SP-001',  'Brasa Grill Pinheiros',  'São Paulo', 'SP', null,            null)
on conflict do nothing;

insert into public.machines (id, site_id, role_code, label, notes) values
  ('bbbbbbbb-0001-4001-8001-000000000001',
   'aaaaaaaa-0001-4001-8001-000000000001', 'server', 'Servidor de loja', 'convenção: .100 na subnet da loja'),
  ('bbbbbbbb-0002-4002-8002-000000000002',
   'aaaaaaaa-0001-4001-8001-000000000001', 'pdv',    'PDV 01', ''),
  ('bbbbbbbb-0003-4003-8003-000000000003',
   'aaaaaaaa-0001-4001-8001-000000000001', 'pdv',    'PDV 02', ''),
  ('bbbbbbbb-0004-4004-8004-000000000004',
   'aaaaaaaa-0002-4002-8002-000000000002', 'pdv',    'PDV 01', ''),
  ('bbbbbbbb-0005-4005-8005-000000000005',
   'aaaaaaaa-0003-4003-8003-000000000003', 'admin',  'Estação gerência', '')
on conflict do nothing;

-- Exemplo de regra com escopo mais estreito que a global: o servidor da loja
-- aguenta CPU alta por mais tempo antes de virar alerta.
insert into public.alert_rules
  (name, kind, scope, machine_id, threshold, comparator, consecutive_cycles, cooldown_minutes, severity, channels)
select 'CPU do servidor BSB-001', 'cpu_sustained', 'machine',
       'bbbbbbbb-0001-4001-8001-000000000001', 95, '>=', 20, 120, 'warning', array['telegram']
where not exists (
  select 1 from public.alert_rules ar
  where ar.scope = 'machine'
    and ar.kind = 'cpu_sustained'
    and ar.machine_id = 'bbbbbbbb-0001-4001-8001-000000000001'
);

select
  (select count(*) from public.brands)  as marcas,
  (select count(*) from public.sites)   as lojas,
  (select count(*) from public.machines) as maquinas,
  (select count(*) from public.alert_rules) as regras;
