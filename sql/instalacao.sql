-- ============================================================
-- SAFEBOAT · Escolha da instalação na proposta (rede de instaladores)
-- Rode UMA VEZ no Supabase: Dashboard → SQL Editor → Run (idempotente)
--
-- O cliente escolhe na proposta quem instala o SAFEBOAT no barco:
--   #INST=SB       → instaladores SAFEBOAT (taxa de instalação cobrada no fechamento)
--   #INST=PROPRIO  → kit completo enviado ao instalador do cliente (sem taxa)
-- A escolha fica no próprio campo kit (mesmo padrão de #CAM=, #VIB=…), então
-- prop_get, o CRM e o contrato já a enxergam sem coluna nova.
--
-- prop_instalacao(n, t, p_inst): troca o marcador #INST da proposta —
-- só antes do aceite e só em propostas que já trazem o marcador (geradas
-- pelo CRM/site com a pergunta de instalação).
-- ============================================================

create or replace function public.prop_instalacao(n int, t text, p_inst text)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_inst text := upper(coalesce(trim(p_inst), ''));
  ok int;
begin
  if v_inst not in ('SB', 'PROPRIO') then
    return false;
  end if;

  update propostas set
    kit = regexp_replace(kit, '#INST=[A-Za-z]+', '#INST=' || v_inst)
  where numero = n and token = t
    and status <> 'aceita'
    and kit ~ '#INST=[A-Za-z]+';

  get diagnostics ok = row_count;
  return ok > 0;
end $$;

grant execute on function public.prop_instalacao(int, text, text) to anon;
