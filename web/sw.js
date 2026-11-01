// Remote Keeper service worker: shows restart alerts. The alert arrives sealed by the computer
// (the relay can't read it); this opens it with the secret saved by the page (see crypto.js,
// which this mirrors: a classic worker can't import modules everywhere).

const SALT = new TextEncoder().encode("remote-keeper v1");

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

function decode(text) {
  const s = atob(text.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((text.length + 3) % 4));
  return Uint8Array.from(s, (c) => c.charCodeAt(0));
}

async function derive(secret, info) {
  const ikm = await crypto.subtle.importKey("raw", secret, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(
    await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt: SALT, info: new TextEncoder().encode(info) }, ikm, 256),
  );
}

function computers() {
  return new Promise((resolve) => {
    const request = indexedDB.open("remote-keeper", 1);
    request.onupgradeneeded = () => request.result.createObjectStore("computers", { keyPath: "channel" });
    request.onerror = () => resolve([]);
    request.onsuccess = () => {
      const all = request.result.transaction("computers").objectStore("computers").getAll();
      all.onsuccess = () => resolve(all.result);
      all.onerror = () => resolve([]);
    };
  });
}

async function openAlert(payload) {
  for (const computer of await computers()) {
    if (!computer.channel.startsWith(payload.c)) continue;
    try {
      const key = await crypto.subtle.importKey("raw", await derive(decode(computer.secret), "to-phone"), "AES-GCM", false, ["decrypt"]);
      const bytes = decode(payload.m);
      const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: bytes.slice(0, 12) }, key, bytes.slice(12));
      return { ...JSON.parse(new TextDecoder().decode(plain)), computer: computer.name };
    } catch {}
  }
  return null;
}

self.addEventListener("push", (event) => {
  event.waitUntil(
    (async () => {
      let alert = null;
      let payload = {};
      try {
        payload = event.data.json();
        alert = await openAlert(payload);
      } catch {}
      // Every push must show a notification, so an unreadable one still says something useful.
      const title = alert?.title || "Claude restarted";
      const body = alert?.body || "Remote Control may be off for your sessions. Tap to reconnect.";
      await self.registration.showNotification(title, {
        body,
        tag: `restart-${payload.c || ""}`,
        icon: "/icons/icon-192.png",
        data: { url: `/?computer=${encodeURIComponent(payload.c || "")}` },
      });
      // App icon badge: chosen sessions offline, added up over all your computers.
      try {
        if (typeof alert?.offline === "number") {
          const total = await saveOffline(payload.c, alert.offline);
          if (total > 0) await self.navigator.setAppBadge?.(total);
        }
      } catch {}
    })(),
  );
});

function saveOffline(prefix, count) {
  return new Promise((resolve) => {
    const request = indexedDB.open("remote-keeper", 1);
    request.onupgradeneeded = () => request.result.createObjectStore("computers", { keyPath: "channel" });
    request.onerror = () => resolve(count);
    request.onsuccess = () => {
      const tx = request.result.transaction("computers", "readwrite");
      const store = tx.objectStore("computers");
      const all = store.getAll();
      all.onsuccess = () => {
        let total = 0;
        for (const c of all.result) {
          if (c.channel.startsWith(prefix)) {
            c.offline = count;
            store.put(c);
          }
          total += c.offline || 0;
        }
        tx.oncomplete = () => resolve(total);
      };
      all.onerror = () => resolve(count);
    };
  });
}

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil(
    (async () => {
      const url = event.notification.data?.url || "/";
      const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
      for (const client of windows) {
        if ("navigate" in client) {
          await client.focus();
          return client.navigate(url);
        }
      }
      return self.clients.openWindow(url);
    })(),
  );
});

// Network only: the app always needs the relay anyway.
self.addEventListener("fetch", () => {});
