-- CRM Ateliê: agenda de produção (aba "Produção", 15/10/2026).
-- Rodar UMA vez no Supabase > SQL Editor > New query > colar tudo > Run.
-- Pode rodar de novo sem problema: so cria a coluna que ainda nao existe e nao apaga nada.
-- Antes deste SQL o CRM ja funciona: a aba Produção mostra os pedidos e avisa que falta rodar isto.
--
-- Regra de prazo (Luan, 15/10/2026): postagem em 2 dias uteis depois da arte aprovada e do pagamento;
-- Correios ate 5 dias uteis; total ate 7 dias uteis. "Postar ate" e calculado no CRM, nao fica gravado.
--
--  prod_etapa       = etapa da producao: Aguardando arte, Arte aprovada, Produzindo, Pronto, Postado.
--                     Vazio = pedido ainda sem etapa (o CRM mostra como "Aguardando arte").
--  arte_aprovada_em = dia em que a cliente aprovou a arte. O CRM grava hoje ao tocar em "Arte aprovada"
--                     e da para corrigir no cartao. E daqui que sai o "postar ate" (+ 2 dias uteis).
--  postado_em       = dia em que o pedido foi postado nos Correios. Ao marcar "Postado" o CRM grava hoje
--                     e muda o estagio para "Entregue"; pedido com esta data sai da aba Produção.

alter table public.pedidos
  add column if not exists prod_etapa text,
  add column if not exists arte_aprovada_em date,
  add column if not exists postado_em date;

-- Conferencia: tem que aparecer as 3 colunas, com os tipos text, date e date.
select column_name, data_type
  from information_schema.columns
 where table_schema = 'public' and table_name = 'pedidos'
   and column_name in ('prod_etapa', 'arte_aprovada_em', 'postado_em')
 order by column_name;
