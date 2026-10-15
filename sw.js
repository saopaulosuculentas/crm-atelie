/* Service worker do CRM Ateliê (15/10/2026).

   Existe para o CRM poder ser instalado como aplicativo no celular (PWA).
   NAO guarda pagina nenhuma em cache, de proposito: o CRM precisa abrir sempre
   a versao nova, e o GitHub Pages ja deu dor de cabeca com cache antigo.
   Por isso nao ha listener de "fetch": tudo vai direto para a rede, como num
   site normal.

   Push: os listeners abaixo ficam prontos para o futuro, mas AINDA NAO HA
   ENVIO. Hoje o aviso para a equipe sai pelo Telegram (fluxo do n8n). Quando
   o push do app entrar, o servidor manda um JSON {title, body, url} e o
   clique na notificacao abre o CRM nessa url (ex.: "./#producao"). */

self.addEventListener("install", function () {
  self.skipWaiting();
});

self.addEventListener("activate", function (event) {
  event.waitUntil(self.clients.claim());
});

self.addEventListener("push", function (event) {
  var dados = {};
  try {
    dados = event.data ? event.data.json() : {};
  } catch (e) {
    dados = { body: event.data ? event.data.text() : "" };
  }
  var titulo = dados.title || "CRM Ateliê";
  event.waitUntil(
    self.registration.showNotification(titulo, {
      body: dados.body || "",
      icon: "icon-192.png",
      badge: "icon-192.png",
      data: { url: dados.url || "./" }
    })
  );
});

self.addEventListener("notificationclick", function (event) {
  event.notification.close();
  var destino = new URL((event.notification.data && event.notification.data.url) || "./", self.registration.scope).href;
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(function (lista) {
      for (var i = 0; i < lista.length; i++) {
        var c = lista[i];
        if (c.url.indexOf(self.registration.scope) === 0 && "focus" in c) {
          return c.focus().then(function (janela) {
            if (janela && "navigate" in janela) return janela.navigate(destino).catch(function () {});
          });
        }
      }
      return self.clients.openWindow(destino);
    })
  );
});
