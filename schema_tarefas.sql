-- Quadro de tarefas do CRM (aba "Tarefas").
-- Rode uma vez no SQL Editor do Supabase.

create table if not exists public.tarefas (
  id            bigint primary key,
  titulo        text not null,
  descricao     text        default '',
  responsavel   text        default '',
  prazo         date,
  urgencia      text        default 'media',   -- baixa | media | alta | urgente
  etapa         text        default 'A fazer', -- A fazer | Fazendo | Aguardando | Feito
  pos           double precision default 1000, -- posicao FRACIONARIA: mover 1 cartao grava 1 linha
  criado_por    text        default '',
  criado_em     timestamptz default now(),
  concluido_em  timestamptz,
  pedido_id     bigint                          -- gancho pra ligar a tarefa a um pedido depois
);

-- ordenar por etapa/posicao e filtrar por responsavel sao as duas leituras quentes
create index if not exists tarefas_etapa_pos_idx on public.tarefas (etapa, pos);
create index if not exists tarefas_resp_idx      on public.tarefas (responsavel);

alter table public.tarefas enable row level security;

-- Mesma regra das outras tabelas do CRM: quem esta logado usa, quem nao esta nao ve nada.
drop policy if exists "tarefas_auth_all" on public.tarefas;
create policy "tarefas_auth_all" on public.tarefas
  for all
  to authenticated
  using (true)
  with check (true);
