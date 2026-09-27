// CRM Ateliê: envia a aba "Despesas" desta planilha para o CRM.
// Onde colar: na planilha "Sucs Finanças NEW", menu Extensões > Apps Script > apague o que tiver > cole tudo > salvar.
// Depois, escolha a funcao "setup" no topo e clique em Executar (uma vez so):
//   1. o Google pede autorizacao (e a sua propria conta: Avancado > Acessar);
//   2. volte para a aba da planilha: aparecem duas caixinhas, uma pede a chave anon do Supabase e a outra o
//      codigo secreto que saiu no fim do SQL;
//   3. ele faz o primeiro envio e mostra "Pronto: ok, N lancamentos".
// A partir dai envia sozinho quando alguem edita a aba Despesas e, por garantia, a cada 15 minutos.
// A hora do ultimo envio fica na nota da celula A1 da aba Despesas.

var SUPA = 'https://bjxqxhvxlxiiexcwghfo.supabase.co';
var ABA = 'Despesas';
var MESES = {janeiro: 1, fevereiro: 2, marco: 3, abril: 4, maio: 5, junho: 6, julho: 7, agosto: 8,
             setembro: 9, outubro: 10, novembro: 11, dezembro: 12};

function setup() {
  var ui = SpreadsheetApp.getUi();
  var props = PropertiesService.getScriptProperties();
  var k = ui.prompt('CRM: chave anon',
    'Cole a chave "anon public" do Supabase (Project Settings > API Keys).', ui.ButtonSet.OK_CANCEL);
  if (k.getSelectedButton() !== ui.Button.OK || !k.getResponseText().trim()) return;
  var s = ui.prompt('CRM: codigo secreto',
    'Cole o codigo que apareceu no fim do SQL (coluna codigo_secreto_para_o_script).', ui.ButtonSet.OK_CANCEL);
  if (s.getSelectedButton() !== ui.Button.OK || !s.getResponseText().trim()) return;
  props.setProperty('ANON', k.getResponseText().trim());
  props.setProperty('SEGREDO', s.getResponseText().trim());

  ScriptApp.getProjectTriggers().forEach(function (t) { ScriptApp.deleteTrigger(t); });
  ScriptApp.newTrigger('aoEditar').forSpreadsheet(SpreadsheetApp.getActive()).onEdit().create();
  ScriptApp.newTrigger('sincronizar').timeBased().everyMinutes(15).create();
  ui.alert('Pronto: ' + sincronizar());
}

function aoEditar(e) {
  if (e && e.range && e.range.getSheet().getName() !== ABA) return;
  sincronizar();
}

function sincronizar() {
  var lock = LockService.getScriptLock();
  if (!lock.tryLock(25000)) return 'outro envio em andamento';
  try {
    var planilha = SpreadsheetApp.getActive();
    var aba = planilha.getSheetByName(ABA);
    if (!aba) return marcar(null, 'ERRO: a aba "' + ABA + '" nao existe mais (foi renomeada?)');
    var valores = aba.getDataRange().getValues();

    // cabecalho: a primeira linha (entre as 10 primeiras) que tem "Data" e "Valor"
    var cab = -1, h = [];
    for (var i = 0; i < Math.min(valores.length, 10); i++) {
      var linha = valores[i].map(normal);
      if (linha.indexOf('data') >= 0 && linha.indexOf('valor') >= 0) { cab = i; h = linha; break; }
    }
    if (cab < 0) return marcar(aba, 'ERRO: nao achei o cabecalho com Data e Valor');
    var c = {
      data: h.indexOf('data'), mes: h.indexOf('mes'), categoria: h.indexOf('categoria'),
      descricao: h.indexOf('descricao'), valor: h.indexOf('valor'),
      forma: h.indexOf('forma pagamento') >= 0 ? h.indexOf('forma pagamento') : h.indexOf('forma de pagamento'),
      comentarios: h.indexOf('comentarios')
    };

    var fuso = planilha.getSpreadsheetTimeZone();
    var hoje = new Date();
    var linhas = [];
    for (var r = cab + 1; r < valores.length; r++) {
      var v = valores[r];
      var valor = numero(v[c.valor]);
      var descricao = texto(v, c.descricao);
      if (valor === null && !descricao) continue;   // linha vazia ou so com formula
      var d = v[c.data] instanceof Date ? v[c.data] : null;
      var data = d ? Utilities.formatDate(d, fuso, 'yyyy-MM-dd') : '';
      var mes = texto(v, c.mes);
      linhas.push({
        linha: r + 1,
        data: data,
        mes: mes,
        competencia: data ? data.slice(0, 7) : competencia(mes, hoje),
        categoria: texto(v, c.categoria),
        descricao: descricao,
        valor: valor === null ? 0 : Math.round(valor * 100) / 100,
        forma_pagamento: texto(v, c.forma),
        comentarios: texto(v, c.comentarios)
      });
    }

    var props = PropertiesService.getScriptProperties();
    var anon = props.getProperty('ANON');
    if (!anon || !props.getProperty('SEGREDO')) return marcar(aba, 'ERRO: rode o setup() primeiro');
    var resp = UrlFetchApp.fetch(SUPA + '/rest/v1/rpc/sync_custos', {
      method: 'post',
      contentType: 'application/json',
      headers: {apikey: anon, Authorization: 'Bearer ' + anon},
      payload: JSON.stringify({segredo: props.getProperty('SEGREDO'), linhas: linhas}),
      muteHttpExceptions: true
    });
    if (resp.getResponseCode() >= 300) {
      return marcar(aba, 'ERRO ' + resp.getResponseCode() + ': ' + resp.getContentText().slice(0, 160));
    }
    var j = JSON.parse(resp.getContentText());
    return marcar(aba, 'ok, ' + j.linhas + ' lancamentos, total R$ ' + Number(j.total).toFixed(2).replace('.', ','));
  } finally {
    lock.releaseLock();
  }
}

function marcar(aba, msg) {
  var quando = Utilities.formatDate(new Date(), 'America/Sao_Paulo', 'dd/MM HH:mm');
  if (aba) aba.getRange('A1').setNote('Envio para o CRM: ' + quando + '\n' + msg);
  return msg;
}

function normal(x) {
  return String(x === null || x === undefined ? '' : x).trim().toLowerCase()
    .normalize('NFD').replace(/[̀-ͯ]/g, '');
}

function texto(v, i) {
  return i >= 0 && v[i] !== null && v[i] !== undefined ? String(v[i]).trim() : '';
}

function numero(x) {
  if (typeof x === 'number') return isNaN(x) ? null : x;
  var s = String(x === null || x === undefined ? '' : x).replace(/[^0-9,.\-]/g, '');
  if (!s || s === '-') return null;
  s = s.replace(/\./g, '').replace(',', '.');   // "1.475,00" -> "1475.00"
  var n = parseFloat(s);
  return isNaN(n) ? null : n;
}

function competencia(mes, hoje) {
  var m = MESES[normal(mes)];
  if (!m) return '';
  var ano = hoje.getFullYear();
  if (m > hoje.getMonth() + 1) ano -= 1;          // "dezembro" lancado em janeiro e do ano anterior
  return ano + '-' + (m < 10 ? '0' : '') + m;
}
