-- ============================================================
-- SAFEBOAT · Links de pagamento do Mercado Pago gerados SOB DEMANDA
-- Rode UMA VEZ no Supabase: Dashboard → SQL Editor → Run (idempotente)
--
-- A proposta chama prop_pagamento_link(n, t, tipo, valor) e recebe o link do
-- Mercado Pago com o VALOR EXATO daquela proposta (com desconto multi-barco,
-- instalação, opcionais…), sem depender das tabelas MP_IMPL/MP_ANUAL/MP_PLANOS:
--   tipo 'unico'  → checkout (ativação + instalação) · à vista ou até 12x,
--                   juros da operadora por conta do cliente
--   tipo 'anual'  → checkout do fechamento anual (ativação + instalação + anuidade) · até 12x
--   tipo 'mensal' → plano de assinatura recorrente (cartão), valor mensal exato
--
-- PRÉ-REQUISITO (feito pelo Marcelo, uma vez, no próprio SQL Editor):
-- o access token de produção do Mercado Pago precisa estar no Vault do Supabase
-- com o nome 'mercadopago_access_token'. Só esta função (security definer) o lê;
-- ele nunca vai para o front-end nem para o repositório.
--
-- Cada link criado fica registrado em public.pagamentos_links (auditoria e
-- cache: o mesmo valor/tipo da mesma proposta não gera link duplicado).
-- ============================================================

create extension if not exists http with schema extensions;

create table if not exists public.pagamentos_links (
  id bigserial primary key,
  numero int not null,
  tipo text not null,
  valor numeric(12,2) not null,
  mp_id text,
  url text not null,
  created_at timestamptz not null default now()
);
alter table public.pagamentos_links enable row level security;
create index if not exists pagamentos_links_idx on public.pagamentos_links (numero, tipo, valor);

create or replace function public.prop_pagamento_link(n int, t text, p_tipo text, p_valor numeric)
returns json
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_tok text;
  v_prop record;
  v_row record;
  v_body jsonb;
  v_url text;
  v_resp extensions.http_response;
  v_json jsonb;
  v_titulo text;
  v_ref text;
  v_cnt int;
  v_val numeric(12,2) := round(p_valor, 2);
begin
  if p_tipo not in ('unico', 'anual', 'mensal') then return json_build_object('erro', 'tipo'); end if;
  if v_val is null or v_val < 1 or v_val > 500000 then return json_build_object('erro', 'valor'); end if;

  select numero, token, cliente, status into v_prop from propostas where numero = n and token = t;
  if not found then return json_build_object('erro', 'proposta'); end if;

  -- cache: mesmo valor/tipo desta proposta → mesmo link
  select * into v_row from pagamentos_links
    where numero = n and tipo = p_tipo and valor = v_val order by id desc limit 1;
  if found then return json_build_object('url', v_row.url, 'id', v_row.mp_id, 'cache', true); end if;

  select count(*) into v_cnt from pagamentos_links where numero = n;
  if v_cnt >= 40 then return json_build_object('erro', 'limite'); end if;

  select decrypted_secret into v_tok from vault.decrypted_secrets where name = 'mercadopago_access_token' limit 1;
  if v_tok is null then return json_build_object('erro', 'sem_token'); end if;

  v_ref := 'prop-' || n || '-' || p_tipo || '-' || v_val;
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  if p_tipo = 'mensal' then
    v_titulo := 'SAFEBOAT · assinatura mensal · proposta nº ' || lpad(n::text, 4, '0');
    v_body := jsonb_build_object(
      'reason', v_titulo,
      'external_reference', v_ref,
      'auto_recurring', jsonb_build_object('frequency', 1, 'frequency_type', 'months', 'transaction_amount', v_val, 'currency_id', 'BRL'),
      'back_url', 'https://safeboat.tech/proposta/',
      'payment_methods_allowed', jsonb_build_object('payment_types', jsonb_build_array(jsonb_build_object('id', 'credit_card')))
    );
    v_url := 'https://api.mercadopago.com/preapproval_plan';
  else
    v_titulo := (case when p_tipo = 'anual'
      then 'SAFEBOAT · contratação anual (ativação + instalação + anuidade) · proposta nº '
      else 'SAFEBOAT · ativação + instalação · proposta nº ' end) || lpad(n::text, 4, '0');
    v_body := jsonb_build_object(
      'items', jsonb_build_array(jsonb_build_object('title', v_titulo, 'quantity', 1, 'currency_id', 'BRL', 'unit_price', v_val)),
      'back_urls', jsonb_build_object('success', 'https://safeboat.tech/proposta/'),
      'statement_descriptor', 'SAFEBOAT',
      'external_reference', v_ref,
      'payment_methods', jsonb_build_object(
        'excluded_payment_types', jsonb_build_array(jsonb_build_object('id', 'ticket'), jsonb_build_object('id', 'atm'), jsonb_build_object('id', 'bank_transfer')),
        'installments', 12)   -- até 12x; juros do parcelamento por conta do comprador (padrão MP)
    );
    v_url := 'https://api.mercadopago.com/checkout/preferences';
  end if;

  select * into v_resp from extensions.http((
    'POST'::extensions.http_method,
    v_url,
    array[extensions.http_header('Authorization', 'Bearer ' || v_tok), extensions.http_header('Content-Type', 'application/json')],
    'application/json',
    v_body::text
  )::extensions.http_request);

  if v_resp.status not in (200, 201) then
    return json_build_object('erro', 'mp', 'status', v_resp.status, 'detalhe', left(v_resp.content, 300));
  end if;
  v_json := v_resp.content::jsonb;
  if v_json->>'init_point' is null then return json_build_object('erro', 'mp_sem_link'); end if;

  insert into pagamentos_links (numero, tipo, valor, mp_id, url)
    values (n, p_tipo, v_val, v_json->>'id', v_json->>'init_point');
  return json_build_object('url', v_json->>'init_point', 'id', v_json->>'id');
end $$;

grant execute on function public.prop_pagamento_link(int, text, text, numeric) to anon, authenticated;
