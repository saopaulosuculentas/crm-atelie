-- CRM Ateliê: custos da planilha "Sucs Finanças NEW" (aba Despesas) dentro do CRM.
-- Rodar UMA vez no Supabase > SQL Editor > New query > colar tudo > Run.
-- No fim aparece uma linha com o CODIGO SECRETO: copie, ele vai no script da planilha.
-- Pode rodar de novo sem estragar nada (nao apaga dado e nao troca o codigo).

-- 1) Espelho da aba Despesas: cada linha da planilha vira uma linha aqui.
create table if not exists public.custos (
  id text primary key,                 -- "Despesas|<linha da planilha>"
  linha int not null,
  data date,
  mes text,                            -- como esta escrito na planilha ("agosto")
  competencia text,                    -- "2026-08" (da data; sem data, do nome do mes)
  categoria text,
  descricao text,
  valor numeric(12,2) not null default 0,
  forma_pagamento text,
  comentarios text,
  origem text not null default 'planilha',
  sincronizado_em timestamptz not null default now()
);
create index if not exists custos_competencia_idx on public.custos (competencia);

-- Historico de cada envio (o CRM mostra "sincronizado ha X min").
create table if not exists public.custos_sync (
  id bigserial primary key,
  em timestamptz not null default now(),
  linhas int not null,
  total numeric(12,2) not null
);

-- Codigo secreto do envio. RLS ligado e sem policy: ninguem le pela API, so a funcao abaixo.
create table if not exists public.segredos (
  nome text primary key,
  valor text not null
);
insert into public.segredos (nome, valor)
values ('sync_custos', replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''))
on conflict (nome) do nothing;

alter table public.custos enable row level security;
alter table public.custos_sync enable row level security;
alter table public.segredos enable row level security;
revoke all on public.segredos from anon, authenticated;

-- Quem esta logado no CRM le; ninguem escreve direto (so a funcao).
drop policy if exists p_sel_custos on public.custos;
create policy p_sel_custos on public.custos for select to authenticated using (true);
drop policy if exists p_sel_custos_sync on public.custos_sync;
create policy p_sel_custos_sync on public.custos_sync for select to authenticated using (true);

-- 2) A funcao que o script da planilha chama. Cada envio manda a aba inteira e troca o espelho todo:
--    linha corrigida ou apagada na planilha tambem muda no CRM.
create or replace function public.sync_custos(segredo text, linhas jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
  tot numeric;
begin
  if segredo is null or segredo <> (select valor from segredos where nome = 'sync_custos') then
    raise exception 'codigo secreto invalido' using errcode = '28000';
  end if;
  if linhas is null or jsonb_typeof(linhas) <> 'array' then
    raise exception 'linhas precisa ser uma lista';
  end if;
  if jsonb_array_length(linhas) > 20000 then
    raise exception 'lista grande demais';
  end if;
  -- trava: aba vazia por engano (renomeada, filtro, erro) nao apaga o que ja esta no CRM
  if jsonb_array_length(linhas) = 0 and exists (select 1 from custos where origem = 'planilha') then
    raise exception 'nenhuma linha recebida; o CRM manteve o espelho anterior';
  end if;

  delete from custos where origem = 'planilha';
  insert into custos (id, linha, data, mes, competencia, categoria, descricao, valor,
                      forma_pagamento, comentarios, origem, sincronizado_em)
  select 'Despesas|' || (l->>'linha'),
         (l->>'linha')::int,
         nullif(l->>'data', '')::date,
         nullif(l->>'mes', ''),
         nullif(l->>'competencia', ''),
         nullif(l->>'categoria', ''),
         nullif(l->>'descricao', ''),
         coalesce(nullif(l->>'valor', '')::numeric, 0),
         nullif(l->>'forma_pagamento', ''),
         nullif(l->>'comentarios', ''),
         'planilha',
         now()
  from jsonb_array_elements(linhas) l;
  get diagnostics n = row_count;

  select coalesce(sum(valor), 0) into tot from custos where origem = 'planilha';
  insert into custos_sync (linhas, total) values (n, tot);
  delete from custos_sync where em < now() - interval '60 days';
  return jsonb_build_object('ok', true, 'linhas', n, 'total', tot);
end;
$$;

revoke all on function public.sync_custos(text, jsonb) from public;
grant execute on function public.sync_custos(text, jsonb) to anon, authenticated;

-- 3) O codigo secreto (copie o valor e cole quando o script da planilha pedir):
select valor as codigo_secreto_para_o_script from public.segredos where nome = 'sync_custos';
