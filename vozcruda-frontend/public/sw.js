// Smallotz service worker. It exists so browsers offer "Install app".
// It never caches anything: every request goes straight to the network, so prices,
// batches and payments are always live and a new deploy shows up immediately.
self.addEventListener('install', () => self.skipWaiting())
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()))
self.addEventListener('fetch', e => { if (e.request.method === 'GET') e.respondWith(fetch(e.request)) })
