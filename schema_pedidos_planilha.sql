-- CRM Ateliê: pedidos da planilha "Pedidos Sucs" dentro do CRM (27/09/2026).
-- Rodar UMA vez no Supabase > SQL Editor > New query > colar tudo > Run.
-- No fim aparece o CODIGO SECRETO: copie; ele vai no script da planilha (setup).
-- Pode rodar de novo: nao apaga nada e nao troca o codigo.
--
-- O que a planilha manda (script dela, a cada edicao): uma linha por pedido, das abas de Junho/26 em diante.
--  * Pedido de WhatsApp (sem "Ecommerce"): vira pedido no CRM (ids 500000001 a 599999999), com valor = numero da
--    planilha / 0,7 (o numero e os 70% a receber); sem numero, tabela de preco do CRM. Se o mesmo cliente ja tinha sido
--    digitado no CRM perto da mesma semana, nao duplica: so leva status e producao para o digitado.
--  * Pedido do site ("Ecommerce"): acha o pedido do site pelo nome e leva o status (ENTREGUE etc.) e a producao.
--  * Linha que some da planilha: o pedido criado por ela sai do CRM; os outros so se desligam.
--  * Nao lanca nada no Caixa: recebimento de WhatsApp continua lancado a mao (decisao de 27/09).

-- 1) Producao da planilha em cada pedido (semana, status, arte, tag, video, nome na tag, obs, entrega)
alter table public.pedidos add column if not exists producao jsonb;

-- 2) Ligacao linha da planilha -> pedido do CRM, numeracao dos pedidos criados pela planilha, historico e codigo
create table if not exists public.pedidos_planilha (
  chave text primary key,              -- "Setembro/26|nome normalizado|1"
  pedido_id bigint not null,
  tipo text not null,                  -- whatsapp (criado pela planilha), digitado (ja estava no CRM), site
  atualizado_em timestamptz not null default now()
);
create sequence if not exists public.pedidos_planilha_seq start with 500000001 maxvalue 599999999;
create table if not exists public.pedidos_sync (id bigserial primary key, em timestamptz not null default now(), resumo jsonb);
create table if not exists public.segredos (nome text primary key, valor text not null);
insert into public.segredos (nome, valor)
values ('sync_pedidos', replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''))
on conflict (nome) do nothing;

alter table public.pedidos_planilha enable row level security;
alter table public.pedidos_sync enable row level security;
alter table public.segredos enable row level security;
revoke all on public.segredos from anon, authenticated;
drop policy if exists p_sel_pedidos_planilha on public.pedidos_planilha;
create policy p_sel_pedidos_planilha on public.pedidos_planilha for select to authenticated using (true);
drop policy if exists p_sel_pedidos_sync on public.pedidos_sync;
create policy p_sel_pedidos_sync on public.pedidos_sync for select to authenticated using (true);

-- 3) Ajudantes: nome sem acento/sinal, ultimo nome, data em texto que pode vir torta
create or replace function public.norm_nome(t text) returns text language sql immutable as $$
  select trim(regexp_replace(regexp_replace(lower(translate(coalesce(t, ''),
    'ÁÀÂÃÄáàâãäÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÕÖóòôõöÚÙÛÜúùûüÇçÑñ',
    'AAAAAaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCcNn')), '[^a-z0-9 ]', ' ', 'g'), '\s+', ' ', 'g'))
$$;
create or replace function public.ultimo_nome(t text) returns text language sql immutable as $$
  select regexp_replace(norm_nome(t), '^.* ', '')
$$;
create or replace function public.data_segura(t text) returns date language plpgsql immutable as $$
begin
  if t is null or t !~ '^\d{4}-\d{2}-\d{2}' then return null; end if;
  return substr(t, 1, 10)::date;
exception when others then
  return null;
end;
$$;

-- 4) A funcao que o script da planilha chama
create or replace function public.sync_pedidos_planilha(segredo text, linhas jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  l jsonb;
  v_chave text; v_id bigint; v_tipo text; v_nome text; v_norm text; v_ini date; v_fim date;
  v_total numeric; v_qtd numeric; v_prod text; v_preco numeric; v_estagio text; v_pag text; v_prodjs jsonb; v_status text;
  n_novo int := 0; n_atual int := 0; n_dig int := 0; n_site int := 0; n_sem_par int := 0; n_rem int := 0;
  chaves text[] := '{}';
  v_resumo jsonb;
begin
  if segredo is null or segredo <> (select valor from segredos where nome = 'sync_pedidos') then
    raise exception 'codigo secreto invalido' using errcode = '28000';
  end if;
  if linhas is null or jsonb_typeof(linhas) <> 'array' then
    raise exception 'linhas precisa ser uma lista';
  end if;
  if jsonb_array_length(linhas) = 0 and exists (select 1 from pedidos_planilha) then
    raise exception 'nenhuma linha recebida; o CRM manteve os pedidos';
  end if;

  for l in select * from jsonb_array_elements(linhas) loop
    v_chave := l->>'chave';
    if v_chave is null or v_chave = '' then continue; end if;
    chaves := array_append(chaves, v_chave);
    v_nome := trim(coalesce(l->>'nome', ''));
    v_norm := norm_nome(v_nome);
    v_ini := data_segura(l->>'semana_ini');
    v_fim := coalesce(data_segura(l->>'semana_fim'), v_ini);
    v_status := upper(coalesce(l->>'status', ''));
    v_estagio := case when v_status = 'ENTREGUE' then 'Entregue'
                      when v_status in ('FEITO', 'EM PRODUÇÃO', 'EM PRODUCAO') then 'Em produção'
                      else 'Fechado (ganho)' end;
    v_prodjs := jsonb_build_object('aba', l->>'aba', 'linha', l->>'linha', 'semana', l->>'semana', 'status', l->>'status',
                  'arte', l->>'arte', 'tag', l->>'tag', 'video', l->>'video', 'pagou', l->>'pagou',
                  'nome_tag', l->>'nome_tag', 'obs', l->>'obs', 'logistica', l->>'logistica', 'sincronizado_em', now());
    v_id := null; v_tipo := null;
    select pedido_id, tipo into v_id, v_tipo from pedidos_planilha where chave = v_chave;

    -- ---- pedido do site: acha pelo nome uma vez e leva status e producao ----
    if coalesce((l->>'ecommerce')::boolean, false) then
      if v_id is null then
        select p.id into v_id from pedidos p
         where p.id >= 700000000
           and (norm_nome(p.cliente) = v_norm
                or (split_part(norm_nome(p.cliente), ' ', 1) = split_part(v_norm, ' ', 1) and ultimo_nome(p.cliente) = ultimo_nome(v_nome)))
           and data_segura(p.data) between v_ini - 45 and v_fim + 7
           and not exists (select 1 from pedidos_planilha pp where pp.pedido_id = p.id)
         order by abs(data_segura(p.data) - v_ini)
         limit 1;
        if v_id is null then n_sem_par := n_sem_par + 1; continue; end if;
        insert into pedidos_planilha (chave, pedido_id, tipo) values (v_chave, v_id, 'site');
      end if;
      update pedidos set producao = v_prodjs,
             estagio = case when v_status in ('ENTREGUE', 'FEITO', 'EM PRODUÇÃO', 'EM PRODUCAO') and estagio <> 'Perdido' then v_estagio else estagio end
       where id = v_id;
      update pedidos_planilha set atualizado_em = now() where chave = v_chave;
      n_site := n_site + 1;
      continue;
    end if;

    -- ---- pedido de WhatsApp ----
    v_qtd := nullif(l->>'qtd', '')::numeric;
    v_prod := coalesce(nullif(l->>'produto', ''), 'Personalizado (outro)');
    if nullif(l->>'numero', '') is not null then
      v_total := round((l->>'numero')::numeric / 0.7, 2);
    else
      select nullif(dados->'precos'->>v_prod, '')::numeric into v_preco from config where id = 1;
      v_total := round(coalesce(v_preco, 0) * coalesce(v_qtd, 0), 2);
    end if;
    v_pag := case when coalesce((l->>'pago')::boolean, false) or v_status = 'ENTREGUE' then 'Pago' else 'Sinal pago' end;

    if v_id is null then
      -- ja foi digitado no CRM? (pedido manual do mesmo cliente perto da semana)
      select p.id into v_id from pedidos p
       where p.id < 500000000
         and norm_nome(p.cliente) = v_norm
         and data_segura(p.data) between v_ini - 60 and v_fim
         and not exists (select 1 from pedidos_planilha pp where pp.pedido_id = p.id)
       order by abs(data_segura(p.data) - v_ini)
       limit 1;
      if v_id is not null then
        insert into pedidos_planilha (chave, pedido_id, tipo) values (v_chave, v_id, 'digitado');
        v_tipo := 'digitado';
      else
        v_id := nextval('pedidos_planilha_seq');
        insert into pedidos_planilha (chave, pedido_id, tipo) values (v_chave, v_id, 'whatsapp');
        insert into pedidos (id, data, cliente, whats, cidade, canal, "tipoCli", "tipoEv", "dataEv", produto, descr, qtd,
                             "valorUnit", estagio, "statusPag", "formaPag", entrega, "custoEntrega", followup, obs, producao)
        values (v_id, to_char(v_ini, 'YYYY-MM-DD'), v_nome, '', '', 'WhatsApp direto', 'Evento', '', to_char(v_ini, 'YYYY-MM-DD'),
                v_prod, coalesce(l->>'pedido', ''), coalesce(v_qtd, 0),
                case when coalesce(v_qtd, 0) > 0 then round(v_total / v_qtd, 4) else v_total end,
                v_estagio, v_pag, '', '', 0, '', coalesce(l->>'nome_tag', ''), v_prodjs);
        n_novo := n_novo + 1;
        continue;
      end if;
    end if;

    if v_tipo = 'whatsapp' then
      -- criado pela planilha: a planilha manda em tudo
      update pedidos set data = to_char(v_ini, 'YYYY-MM-DD'), cliente = v_nome, "dataEv" = to_char(v_ini, 'YYYY-MM-DD'),
             produto = v_prod, descr = coalesce(l->>'pedido', ''), qtd = coalesce(v_qtd, 0),
             "valorUnit" = case when coalesce(v_qtd, 0) > 0 then round(v_total / v_qtd, 4) else v_total end,
             estagio = v_estagio, "statusPag" = v_pag, obs = coalesce(l->>'nome_tag', ''), producao = v_prodjs
       where id = v_id;
      n_atual := n_atual + 1;
    else
      -- digitado no CRM: so leva a producao e o status de entrega
      update pedidos set producao = v_prodjs,
             estagio = case when v_status in ('ENTREGUE', 'FEITO', 'EM PRODUÇÃO', 'EM PRODUCAO') and estagio <> 'Perdido' then v_estagio else estagio end
       where id = v_id;
      n_dig := n_dig + 1;
    end if;
    update pedidos_planilha set atualizado_em = now() where chave = v_chave;
  end loop;

  -- linha que sumiu da planilha: pedido criado por ela sai; digitado e site so se desligam
  with sumiu as (
    delete from pedidos_planilha where not (chave = any(chaves)) returning pedido_id, tipo
  ), apagados as (
    delete from pedidos p using sumiu s where s.tipo = 'whatsapp' and p.id = s.pedido_id returning p.id
  )
  select count(*) into n_rem from apagados;

  v_resumo := jsonb_build_object('linhas', jsonb_array_length(linhas), 'novos', n_novo, 'atualizados', n_atual,
                                 'digitados', n_dig, 'site', n_site, 'site_sem_par', n_sem_par, 'removidos', n_rem);
  insert into pedidos_sync (resumo) values (v_resumo);
  delete from pedidos_sync where em < now() - interval '30 days';
  return v_resumo;
end;
$$;

revoke all on function public.sync_pedidos_planilha(text, jsonb) from public;
grant execute on function public.sync_pedidos_planilha(text, jsonb) to anon, authenticated;

-- 5) O codigo secreto (copie o valor e cole quando o script da planilha pedir):
select valor as codigo_secreto_para_o_script from public.segredos where nome = 'sync_pedidos';
