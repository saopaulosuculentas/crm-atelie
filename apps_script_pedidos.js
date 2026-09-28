// CRM Ateliê: manda os pedidos da planilha "Pedidos Sucs" para o CRM (abas de Junho/26 em diante).
// Onde colar: na planilha Pedidos Sucs, menu Extensões > Apps Script > apague o que tiver > cole tudo > salvar.
// Antes de executar, cadastre as duas chaves (uma vez so): no Apps Script, engrenagem "Configurações do projeto" >
// "Propriedades do script" > Adicionar: ANON = chave "anon public" do Supabase (Project Settings > API Keys) e
// SEGREDO = codigo que saiu no fim do SQL. Salvar. Depois volte ao Editor, escolha "setup" e clique em Executar:
//   1. o Google pede autorizacao (e a sua propria conta: Avancado > Acessar);
//   2. ele cria os gatilhos e faz o primeiro envio; o resumo aparece no "Registro de execucao" embaixo do codigo.
// (Nao usamos caixinha na planilha: rodando pelo editor, o Google nao deixa o script abrir caixinha.)
// Daqui para frente: toda edicao manda de novo (no maximo a cada 2 minutos) e, por garantia, confere a cada 5 minutos.
// A planilha nao e alterada: o script so le.
//
// Como le cada linha: coluna A = status (ENTREGUE, FEITO, EM PRODUCAO); B = "Nome - valor - ..." (valor = 70% a receber;
// "Ecommerce" = pedido do site; "PAGO" = pago); C = pedido; D = nome na tag; E = arte feita?; F = tag produzida;
// G = enviou video?; H = pagou; I = obs. Linha "SEMANA DIA 01/09/26 ATE 06/09/26" abre a semana de entrega.

var SUPA = 'https://bjxqxhvxlxiiexcwghfo.supabase.co';
var PRIMEIRO_MES = 2026 * 12 + 6;   // junho/2026
var MESES = {janeiro: 1, fevereiro: 2, marco: 3, abril: 4, maio: 5, junho: 6, julho: 7, agosto: 8,
             setembro: 9, outubro: 10, novembro: 11, dezembro: 12};

function setup() {
  var props = PropertiesService.getScriptProperties();
  if (!props.getProperty('ANON') || !props.getProperty('SEGREDO')) {
    throw new Error('Falta cadastrar ANON e SEGREDO em Configurações do projeto > Propriedades do script.');
  }
  ScriptApp.getProjectTriggers().forEach(function (t) { ScriptApp.deleteTrigger(t); });
  ScriptApp.newTrigger('aoEditar').forSpreadsheet(SpreadsheetApp.getActive()).onEdit().create();
  ScriptApp.newTrigger('aCada5min').timeBased().everyMinutes(5).create();
  var resultado = sincronizar();
  console.log('Pedidos para o CRM: ' + resultado);
  return resultado;
}

function aoEditar(e) {
  var props = PropertiesService.getScriptProperties();
  props.setProperty('SUJO', '1');
  if (Date.now() - Number(props.getProperty('ULTIMO') || 0) > 120000) sincronizar();
}

function aCada5min() {
  var props = PropertiesService.getScriptProperties();
  if (props.getProperty('SUJO') === '1' || Date.now() - Number(props.getProperty('ULTIMO') || 0) > 3600000) sincronizar();
}

function sincronizar() {
  var lock = LockService.getScriptLock();
  if (!lock.tryLock(25000)) return 'outro envio em andamento';
  var props = PropertiesService.getScriptProperties();
  try {
    props.setProperty('SUJO', '0');
    var linhas = lerPlanilha(SpreadsheetApp.getActive().getSheets().map(function (aba) {
      return {nome: aba.getName(), valores: aba.getDataRange().getDisplayValues()};
    }));
    var anon = props.getProperty('ANON');
    if (!anon || !props.getProperty('SEGREDO')) return 'rode o setup() primeiro';
    var resp = UrlFetchApp.fetch(SUPA + '/rest/v1/rpc/sync_pedidos_planilha', {
      method: 'post', contentType: 'application/json',
      headers: {apikey: anon, Authorization: 'Bearer ' + anon},
      payload: JSON.stringify({segredo: props.getProperty('SEGREDO'), linhas: linhas}),
      muteHttpExceptions: true
    });
    props.setProperty('ULTIMO', String(Date.now()));
    if (resp.getResponseCode() >= 300) {
      var erro = 'ERRO ' + resp.getResponseCode() + ': ' + resp.getContentText().slice(0, 200);
      props.setProperty('RESULTADO', erro);
      return erro;
    }
    var r = JSON.parse(resp.getContentText());
    var msg = r.linhas + ' linhas lidas: ' + r.novos + ' pedidos de WhatsApp novos, ' + r.atualizados + ' atualizados, ' +
      r.digitados + ' que ja estavam no CRM, ' + r.site + ' do site, ' + r.site_sem_par + ' do site nao achados, ' + r.removidos + ' removidos.';
    props.setProperty('RESULTADO', msg);
    return msg;
  } finally {
    lock.releaseLock();
  }
}

// ---------- leitura (sem nada do Google: da para testar fora) ----------
function lerPlanilha(abas) {
  var linhas = [];
  abas.forEach(function (aba) {
    var m = /^\s*([A-Za-zÀ-ÿ]+)\s*\/\s*(\d{2})\s*$/.exec(aba.nome);
    if (!m) return;
    var mes = MESES[normal(m[1])], ano = 2000 + Number(m[2]);
    if (!mes || ano * 12 + mes < PRIMEIRO_MES) return;
    var semana = '', ini = ano + '-' + dois(mes) + '-01', fim = ini, vistos = {};
    aba.valores.forEach(function (v, r) {
      var b = texto(v[1]);
      if (!b) return;
      var s = /SEMANA\s+DIA\s+(\d{1,2})\s*\/\s*(\d{1,2})\s*\/\s*(\d{2,4})\s+AT[ÉE]\s+(\d{1,2})\s*\/\s*(\d{1,2})\s*\/\s*(\d{2,4})/i.exec(b);
      if (s) { semana = b; ini = data(s[1], s[2], s[3]); fim = data(s[4], s[5], s[6]); return; }
      if (/^SEMANA\b/i.test(b)) { semana = b; return; }
      var partes = b.split(/\s+-\s*|\s*-\s+/).map(function (p) { return p.trim(); }).filter(function (p) { return p; });
      var nome = partes[0] || '';
      if (!/[A-Za-zÀ-ÿ]{2,}/.test(nome)) return;
      var resto = partes.slice(1), numero = null, pago = false, ecommerce = /e-?commerce/i.test(b), logistica = [];
      resto.forEach(function (p) {
        var n = /^(?:R\$\s*)?(\d{1,3}(?:\.\d{3})+|\d+),(\d{2})$/.exec(p);
        if (n && numero === null) { numero = Number(n[1].replace(/\./g, '') + '.' + n[2]); return; }
        if (/^PAGO$/i.test(p)) { pago = true; return; }
        if (/^e-?commerce$/i.test(p)) return;
        logistica.push(p);
      });
      var pedido = texto(v[2]);
      var q = /(\d+)/.exec(pedido);
      var chaveNome = normal(nome);
      vistos[chaveNome] = (vistos[chaveNome] || 0) + 1;
      var obsI = texto(v[8]), nomeTag = texto(v[3]);
      linhas.push({
        chave: aba.nome + '|' + chaveNome + '|' + vistos[chaveNome],
        aba: aba.nome, linha: r + 1, semana: semana, semana_ini: ini, semana_fim: fim,
        status: texto(v[0]).toUpperCase(), nome: nome, ecommerce: ecommerce, pago: pago, numero: numero,
        logistica: logistica.join(' · '), pedido: pedido, qtd: q ? Number(q[1]) : null, produto: produto(pedido),
        nome_tag: nomeTag, arte: texto(v[4]), tag: texto(v[5]), video: texto(v[6]), pagou: texto(v[7]), obs: obsI
      });
    });
  });
  return linhas;
}

// o produto do CRM mais parecido com o que esta escrito no pedido (so para o custo de produto do Painel)
function produto(p) {
  var t = normal(p);
  var suc = /suculenta/.test(t);
  if (/terrario|kit/.test(t)) return 'Kit/Terrário';
  if (/cachep/.test(t)) return 'Cachepô de Juta';
  if (suc && /rotulo/.test(t)) return 'Suculenta + Rótulo Personalizado';
  if (suc && /\btag/.test(t)) return 'Suculenta + Tag (simples)';
  if (suc) return 'Suculenta + Rótulo Pronto';
  return 'Personalizado (outro)';
}

function texto(x) { return x === null || x === undefined ? '' : String(x).trim(); }
function dois(n) { return (Number(n) < 10 ? '0' : '') + Number(n); }
function data(d, m, a) { a = Number(a); if (a < 100) a += 2000; return a + '-' + dois(m) + '-' + dois(d); }
function normal(x) {
  return String(x === null || x === undefined ? '' : x).toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '')
    .replace(/[^a-z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim();
}
