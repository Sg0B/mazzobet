// Service worker di MazzoBet: solo ricezione delle notifiche push. Nessuna cache, nessuna gestione delle chiamate API.
self.addEventListener('install', () => self.skipWaiting())
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()))

self.addEventListener('push', (event) => {
  let d = {}
  try { d = event.data ? event.data.json() : {} } catch { /* payload non valido: mostra comunque qualcosa */ }
  event.waitUntil(
    self.registration.showNotification(d.title || 'MazzoBet', {
      body: d.body || '',
      tag: d.tag || 'mazzobet',   // stesso tag = sostituisce la notifica precedente
      renotify: true,
      icon: '/icon-192.png',
      badge: '/favicon-48.png',
      data: { url: d.url || '/' },
    }),
  )
})

self.addEventListener('notificationclick', (event) => {
  event.notification.close()
  const url = (event.notification.data && event.notification.data.url) || '/'
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((list) => {
      const open = list.find((c) => 'focus' in c)
      if (open) {
        open.postMessage({ type: 'mazzobet-open', url })
        return open.focus()
      }
      return self.clients.openWindow(url)
    }),
  )
})
