-- ============================================================
-- SAFEBOAT · Repositório de contratos aceitos (assinatura eletrônica)
-- Rode este script UMA VEZ no Supabase: Dashboard → SQL Editor → Run
--
-- O que ele faz:
--  1. Adiciona colunas de evidência do aceite na tabela propostas
--     (IP, navegador, hash SHA-256 e snapshot integral do contrato)
--  2. Recria a função prop_aceitar para capturar essas evidências
--  3. Cria a função contrato_get para exibir o contrato assinado
-- ============================================================

-- 1) Colunas de evidência (idempotente — não afeta dados existentes)
alter table public.propostas
  add column if not exists aceite_ip text,
  add column if not exists aceite_ua text,
  add column if not exists aceite_hash text,
  add column if not exists contrato_html text;

-- 2) Recria prop_aceitar com captura de evidências.
--    Remove versões antigas para evitar ambiguidade de sobrecarga.
do $$
declare r record;
begin
  for r in
    select oid::regprocedure as sig
    from pg_proc
    where proname = 'prop_aceitar' and pronamespace = 'public'::regnamespace
  loop
    execute 'drop function ' || r.sig;
  end loop;
end $$;

create function public.prop_aceitar(
  n int, t text, p_nome text, p_doc text, p_plano text, p_pag text,
  p_hash text default null, p_contrato text default null
) returns boolean
language plpgsql security definer set search_path = public as $$
declare
  hdr json;
  v_ip text;
  v_ua text;
  ok int;
begin
  -- IP e user-agent vêm dos cabeçalhos da requisição (PostgREST)
  begin
    hdr := current_setting('request.headers', true)::json;
    v_ip := coalesce(hdr->>'x-forwarded-for', hdr->>'x-real-ip');
    v_ua := hdr->>'user-agent';
  exception when others then
    v_ip := null; v_ua := null;
  end;

  update propostas set
    status       = 'aceita',
    aceite_nome  = p_nome,
    aceite_doc   = p_doc,
    aceite_at    = now(),
    plano        = p_plano,
    pagamento    = p_pag,
    aceite_ip    = v_ip,
    aceite_ua    = v_ua,
    aceite_hash  = p_hash,
    contrato_html = p_contrato
  where numero = n and token = t and status <> 'aceita';

  get diagnostics ok = row_count;
  return ok > 0;
end $$;

grant execute on function public.prop_aceitar(int, text, text, text, text, text, text, text) to anon;

-- 3) Consulta segura do contrato assinado (exige nº + código do link).
--    Retorna JSON para não depender dos tipos exatos das colunas.
create or replace function public.contrato_get(n int, t text)
returns setof json
language sql security definer stable set search_path = public as $$
  select row_to_json(x) from (
    select numero, cliente, segmento, plano, pagamento, valor,
           aceite_nome, aceite_doc, aceite_at, aceite_ip, aceite_ua,
           aceite_hash, contrato_html
    from propostas
    where numero = n and token = t and status = 'aceita'
  ) x;
$$;

grant execute on function public.contrato_get(int, text) to anon;
