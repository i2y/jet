// Minimal service worker: lets the page show desktop notifications even from a BACKGROUND tab
// (browsers block `new Notification()` from a hidden tab; ServiceWorkerRegistration.showNotification
// is allowed). Clicking a notification focuses the existing Jet Console window/tab.
self.addEventListener("install", () => self.skipWaiting())
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()))

self.addEventListener("notificationclick", (e) => {
  e.notification.close()
  e.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((cs) => {
      for (const c of cs) {
        if ("focus" in c) return c.focus()
      }
      if (self.clients.openWindow) return self.clients.openWindow("/")
    })
  )
})
