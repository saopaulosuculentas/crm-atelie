-- CRM Ateliê: custos automáticos no Painel (15/10/2026). ESTRUTURA, sem dados.
-- O arquivo com os dados (histórico do gasto de anúncio) fica fora do repositório:
-- Downloads/crm_custos_automaticos_rodar_no_supabase.sql. Rodar de novo não duplica nada e não apaga nada.
--
-- 1) gasto_anuncios: gasto real por dia, plataforma e campanha. Quem escreve é o n8n (A14) com a chave de
--    serviço: o Meta todo dia de manhã (relê os 3 últimos dias) e o Google pelo Script do Google Ads.
--    Quem está logado no CRM só lê. O Painel lê a visão gasto_anuncios_dia (soma por dia e plataforma).
-- 2) pedido_site_itens(): lê os itens do JSON cru da Yampi e devolve produto do CRM, unidades de planta e
--    valor unitário (total / unidades, para quantidade x valor unitário = total pago).
-- 3) yampi_estagio() e yampi_pag(): status da Yampi -> estágio e pagamento do CRM (em transporte e separando
--    contam como pagos; antes caíam como "Pendente").
-- 4) pedido_para_crm(): o gatilho que cria o pedido do site, agora com produto, qtd e valorUnit pelos itens.
--    Nunca toca em pedido com id abaixo de 700000000.

-- ---------------------------------------------------------------------------------------------------
-- 1) Gasto de anúncio
create table if not exists public.gasto_anuncios (
  data          date        not null,
  plataforma    text        not null check (plataforma in ('meta', 'google')),
  campanha_id   text        not null,
  campanha      text        not null default '',
  gasto         numeric(12,2) not null default 0 check (gasto >= 0),
  moeda         text        not null default 'BRL',
  origem        text        not null default 'manual',
  atualizado_em timestamptz not null default now(),
  primary key (data, plataforma, campanha_id)
);

alter table public.gasto_anuncios enable row level security;
drop policy if exists p_sel_gasto_anuncios on public.gasto_anuncios;
create policy p_sel_gasto_anuncios on public.gasto_anuncios for select to authenticated using (true);
-- sem policy de escrita: só a chave de serviço (service_role, que ignora o RLS) grava
revoke all on public.gasto_anuncios from anon;
revoke insert, update, delete, truncate on public.gasto_anuncios from authenticated;
grant select on public.gasto_anuncios to authenticated;
grant all on public.gasto_anuncios to service_role;

create or replace view public.gasto_anuncios_dia with (security_invoker = true) as
  select data,
         plataforma,
         sum(gasto)::numeric(12,2) as gasto,
         count(*)::int             as campanhas,
         max(atualizado_em)        as atualizado_em
  from public.gasto_anuncios
  group by data, plataforma;
revoke all on public.gasto_anuncios_dia from anon;
grant select on public.gasto_anuncios_dia to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------------
-- 2) Itens do pedido do site -> produto, unidades e valor unitário do CRM
--    Mapa (JEV 15/10): rótulo e tag -> "Suculenta + Rótulo + Tag"; só rótulo (inclui os temas) ->
--    "Suculenta + Rótulo Personalizado"; cachepô de juta -> "Cachepô de Juta"; suculentas puras / naturais
--    -> "Kit/Terrário"; "5 lembrancinhas extras" somam 5 unidades ao produto principal; laço de cetim é
--    adicional sem planta; "sem suculenta" e o que não reconhecer ficam sem produto (custo zero no Painel).
create or replace function public.pedido_site_itens(o jsonb)
returns table (produto text, qtd numeric, valor_unit numeric, mapeado boolean)
language plpgsql
immutable
set search_path = public
as $fn$
declare
  i        jsonb;
  vars     jsonb;
  t        text;
  q        numeric;
  un       numeric;
  p        text;
  extras   numeric := 0;
  total    numeric;
  somas    jsonb := '{}'::jsonb;
  melhor   text;
  soma_un  numeric := 0;
begin
  total := coalesce(nullif(regexp_replace(coalesce(o->>'value_total', ''), '[^0-9.]', '', 'g'), '')::numeric, 0);

  for i in select x from jsonb_array_elements(
             case when jsonb_typeof(o#>'{items,data}') = 'array' then o#>'{items,data}'
                  when jsonb_typeof(o->'items') = 'array' then o->'items'
                  else '[]'::jsonb end) x
  loop
    t := translate(lower(coalesce(i#>>'{sku,data,title}', i->>'sku_name', i->>'name', i->>'product_name', '')),
                   'áàâãäéèêëíìîïóòôõöúùûüç', 'aaaaaeeeeiiiiooooouuuuc');
    q := coalesce(nullif(regexp_replace(coalesce(i->>'quantity', ''), '[^0-9.]', '', 'g'), '')::numeric, 1);
    vars := i#>'{sku,data,variations}';
    if jsonb_typeof(vars) = 'object' then vars := vars->'data'; end if;
    if jsonb_typeof(vars) is distinct from 'array' then vars := '[]'::jsonb; end if;

    -- unidades: 1o número da variação ("30 unidades", "Unidades: 30"); senão, do nome do produto
    select substring(v->>'value' from '([0-9]+)')::numeric into un
      from jsonb_array_elements(vars) v
     where coalesce(v->>'value', '') ~ '[0-9]'
     limit 1;
    if un is null then
      un := coalesce(substring(t from '([0-9]+)\s*unidades')::numeric, substring(t from '([0-9]+)\s*$')::numeric);
    end if;

    if t ~ 'extra' and t ~ 'reserva' then
      extras := extras + coalesce(substring(t from '^\s*([0-9]+)')::numeric, 5) * q;
      continue;
    elsif t ~ '^\s*(laco|fita)' then
      continue;                                   -- adicional sem planta
    elsif t ~ 'sem suculenta' then
      p := null;
    elsif t ~ 'cachep|juta' then
      p := 'Cachepô de Juta';
    elsif t ~ 'puras|naturais|sem rotulo' then
      p := 'Kit/Terrário';
    elsif t ~ 'rotulo' and t ~ 'tag' then
      p := 'Suculenta + Rótulo + Tag';
    elsif t ~ 'rotulo' then
      p := 'Suculenta + Rótulo Personalizado';
    else
      p := null;
    end if;

    if p is null or un is null or un <= 0 then continue; end if;
    somas := jsonb_set(somas, array[p], to_jsonb(coalesce((somas->>p)::numeric, 0) + un * q));
  end loop;

  select k, sum(v::numeric) over () into melhor, soma_un
    from jsonb_each_text(somas) as e(k, v)
   order by v::numeric desc, k
   limit 1;

  if melhor is null then
    produto := ''; qtd := 1; valor_unit := total; mapeado := false;
  else
    produto := melhor; qtd := soma_un + extras; valor_unit := round(total / (soma_un + extras), 6); mapeado := true;
  end if;
  return next;
end;
$fn$;

-- ---------------------------------------------------------------------------------------------------
-- 3) Status da Yampi -> CRM (JEV 15/10: on_carriage e handling_products caíam como "Pendente"/"Negociação")
--    paid, authorized, handling_products: pago e em produção; on_carriage (postado nos Correios) e delivered:
--    pago e "Entregue" (no CRM, "Postado" grava "Entregue"); cancelado: Perdido; estorno: Estornado.
create or replace function public.yampi_estagio(p_alias text)
returns text language sql immutable as $fn$
  select case
    when lower(coalesce(p_alias, '')) ~ 'entregue|delivered'                                then 'Entregue'
    when lower(coalesce(p_alias, '')) ~ 'cancel|estorn|refund|recusad|refused'              then 'Perdido'
    when lower(coalesce(p_alias, '')) ~ 'on_carriage|carriage|shipped|enviad|transporte'    then 'Entregue'
    when lower(coalesce(p_alias, '')) ~ 'pago|paid|aprovad|approved|authorized|autorizad|handling|separac|faturad|invoiced'
                                                                                           then 'Em produção'
    else 'Negociação'
  end
$fn$;

create or replace function public.yampi_pag(p_alias text)
returns text language sql immutable as $fn$
  select case
    when lower(coalesce(p_alias, '')) ~ 'estorn|refund' then 'Estornado'
    when lower(coalesce(p_alias, '')) ~ 'pago|paid|aprovad|approved|authorized|autorizad|handling|separac|faturad|invoiced|on_carriage|carriage|shipped|enviad|transporte|entregue|delivered'
      then 'Pago'
    else 'Pendente'
  end
$fn$;

-- ---------------------------------------------------------------------------------------------------
-- 4) Gatilho do pedido do site (reescrito a partir da versão de 15/08/2026, JEV 15/10 95%): o mesmo de antes
--    + status corrigidos + produto, quantidade de plantas e valor unitário pelos itens. Produto, qtd e valorUnit
--    só são gravados quando o pedido ainda está sem produto (quem corrigir à mão no CRM não perde a correção).
--    FAIXA DE ID: pedido do site = 700000000 + número da Yampi. O gatilho NUNCA toca em linha abaixo disso.
create or replace function public.pedido_para_crm()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  o         jsonb;
  num       bigint;
  alias     text;
  agendada  date;
  servico   text;
  forma     text;
  it        record;
begin
  o := coalesce(new.corpo->'resource', new.corpo->'data', new.corpo->'order', new.corpo);
  num := nullif(regexp_replace(coalesce(o->>'number', o->>'id', ''), '[^0-9]', '', 'g'), '')::bigint;
  if num is null then return new; end if;

  servico := o->>'shipment_service';
  alias   := lower(coalesce(o#>>'{status,data,alias}', o#>>'{status,data,name}', ''));

  -- a data agendada tem duas fontes porque uma pode faltar
  agendada := case
    when servico ~ 'AGENDADA-\d{4}-\d{2}-\d{2}'
      then (substring(servico from 'AGENDADA-(\d{4}-\d{2}-\d{2})'))::date
    when coalesce(o->>'shipment_quote_id', '') ~ '^20\d{6}$'
      then to_date(o->>'shipment_quote_id', 'YYYYMMDD')
    else null end;

  forma := case
    when lower(coalesce(o#>>'{transactions,data,0,payment,data,name}', '')) ~ 'pix'    then 'Pix'
    when lower(coalesce(o#>>'{transactions,data,0,payment,data,name}', '')) ~ 'boleto' then 'Boleto'
    when lower(coalesce(o#>>'{transactions,data,0,payment,data,name}', '')) ~ 'cart'   then 'Cartão'
    else '' end;

  select * into it from public.pedido_site_itens(o);

  insert into public.pedidos as p (
    id, data, cliente, whats, cidade, canal, "dataEv", produto, descr,
    qtd, "valorUnit", estagio, "statusPag", "formaPag", entrega, obs
  ) values (
    700000000 + num,
    to_char(coalesce(nullif(o#>>'{created_at,date}', '')::timestamp, now()), 'YYYY-MM-DD'),
    coalesce(o#>>'{customer,data,name}', ''),
    coalesce(o#>>'{customer,data,phone,full_number}', o#>>'{customer,data,phone}', ''),
    trim(coalesce(o#>>'{shipping_address,data,city}', o#>>'{address,0,city}', '') ||
      case when coalesce(o#>>'{shipping_address,data,uf}', o#>>'{address,0,uf}', '') <> ''
           then '-' || coalesce(o#>>'{shipping_address,data,uf}', o#>>'{address,0,uf}') else '' end),
    'Site/Shopify',
    coalesce(to_char(agendada, 'YYYY-MM-DD'), ''),
    it.produto,
    'Pedido #' || num || coalesce(' · ' || servico, ''),
    it.qtd,
    it.valor_unit,
    public.yampi_estagio(alias), public.yampi_pag(alias), forma,
    case when agendada is not null then 'Transportadora' else '' end,
    'Yampi #' || num || coalesce(' · rastreio ' || nullif(o->>'track_code', ''), '')
  )
  on conflict (id) do update set
    estagio     = excluded.estagio,
    "statusPag" = excluded."statusPag",
    obs         = excluded.obs,
    "dataEv"    = case when excluded."dataEv" <> '' then excluded."dataEv" else p."dataEv" end,
    produto     = case when coalesce(p.produto, '') = '' then excluded.produto     else p.produto     end,
    qtd         = case when coalesce(p.produto, '') = '' then excluded.qtd         else p.qtd         end,
    "valorUnit" = case when coalesce(p.produto, '') = '' then excluded."valorUnit" else p."valorUnit" end
  where p.id >= 700000000;

  return new;
end;
$fn$;

drop trigger if exists pedido_webhook_para_crm on public.pedidos_webhook;
create trigger pedido_webhook_para_crm
  after insert on public.pedidos_webhook
  for each row execute function public.pedido_para_crm();
