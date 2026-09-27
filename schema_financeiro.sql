-- CRM Atelie: financeiro dentro do CRM (27/09/2026).
-- O Caixa vira o livro-caixa da empresa: conta de pagamento, ligacao com o pedido e origem do lancamento.
-- (O historico da planilha entrou por um SQL local, fora do repositorio, porque tem valores da empresa.)
alter table public.caixa add column if not exists conta text;
alter table public.caixa add column if not exists pedido_id bigint;
alter table public.caixa add column if not exists origem text not null default 'manual';
create index if not exists caixa_pedido_idx on public.caixa (pedido_id);
