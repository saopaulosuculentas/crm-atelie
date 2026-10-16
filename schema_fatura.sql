-- Fatura do cartão no Caixa (16/10/2026)
-- Cada linha da fatura que entra no Caixa leva uma chave (conta|data|descrição|valor|parcela, mais #2, #3 quando a
-- mesma compra aparece repetida no arquivo). Com o índice único, a mesma linha não entra duas vezes nem quando duas
-- pessoas sobem a mesma fatura ao mesmo tempo: o CRM grava com on_conflict=fatura_chave e resolution=ignore-duplicates.
-- Sem este SQL o CRM funciona igual e confere a repetição pelas linhas que já estão no Caixa.
-- Pode rodar mais de uma vez: não apaga nada e não duplica.

alter table public.caixa add column if not exists fatura_chave text;

-- NULL não conflita com NULL num índice único: os lançamentos que não vêm da fatura continuam livres.
create unique index if not exists caixa_fatura_chave_uk on public.caixa (fatura_chave);

-- conferência: deve mostrar a coluna nova e 0 chaves repetidas
select
  (select count(*) from information_schema.columns
    where table_schema = 'public' and table_name = 'caixa' and column_name = 'fatura_chave') as coluna_criada,
  (select count(*) from (select fatura_chave from public.caixa where fatura_chave is not null
    group by fatura_chave having count(*) > 1) x) as chaves_repetidas;
