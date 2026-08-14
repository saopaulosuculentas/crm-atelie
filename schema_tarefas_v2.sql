-- Tarefas v2: anexos (foto/video/arquivo/link) e comentarios.
-- Rode UMA vez no SQL Editor do Supabase. Pode rodar de novo sem estragar nada.

-- 1) Anexos ficam na propria tarefa. Sao poucos por tarefa e sempre lidos
--    junto com ela, entao tabela separada so criaria um JOIN sem ganho.
alter table public.tarefas add column if not exists anexos jsonb default '[]'::jsonb;

-- 2) Comentarios sao muitos e crescem sozinhos -> tabela propria.
create table if not exists public.tarefa_comentarios (
  id         bigint primary key,
  tarefa_id  bigint not null references public.tarefas(id) on delete cascade,
  autor      text        default '',
  texto      text not null,
  criado_em  timestamptz default now()
);

create index if not exists tarefa_com_tarefa_idx on public.tarefa_comentarios (tarefa_id, id);

alter table public.tarefa_comentarios enable row level security;

drop policy if exists "p_all_tarefa_comentarios" on public.tarefa_comentarios;
create policy "p_all_tarefa_comentarios" on public.tarefa_comentarios
  for all to authenticated using (true) with check (true);

-- 3) Onde as fotos e videos ficam guardados.
--    Publico na LEITURA: a URL e um link direto que abre no navegador de
--    qualquer um dos tres sem precisar de token. Escrever e apagar so logado.
insert into storage.buckets (id, name, public)
values ('tarefas', 'tarefas', true)
on conflict (id) do update set public = true;

drop policy if exists "tarefas_anexo_ler"    on storage.objects;
drop policy if exists "tarefas_anexo_enviar" on storage.objects;
drop policy if exists "tarefas_anexo_apagar" on storage.objects;

create policy "tarefas_anexo_ler" on storage.objects
  for select to public using (bucket_id = 'tarefas');

create policy "tarefas_anexo_enviar" on storage.objects
  for insert to authenticated with check (bucket_id = 'tarefas');

create policy "tarefas_anexo_apagar" on storage.objects
  for delete to authenticated using (bucket_id = 'tarefas');
