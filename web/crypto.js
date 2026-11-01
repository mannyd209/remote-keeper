// End-to-end encryption shared by the page and the service worker. Must match the computer app
// (mac/Relay.swift): HKDF-SHA256 with salt "remote-keeper v1", AES-256-GCM, sealed messages are
// base64url(nonce(12) || ciphertext || tag(16)).

const SALT = new TextEncoder().encode("remote-keeper v1");
const MAX_AGE_MS = 5 * 60 * 1000;

export const b64u = {
  encode(bytes) {
    let s = "";
    for (const b of new Uint8Array(bytes)) s += String.fromCharCode(b);
    return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  },
  decode(text) {
    const s = atob(text.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((text.length + 3) % 4));
    return Uint8Array.from(s, (c) => c.charCodeAt(0));
  },
};

async function derive(secret, info) {
  const ikm = await crypto.subtle.importKey("raw", secret, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(
    await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt: SALT, info: new TextEncoder().encode(info) }, ikm, 256),
  );
}

export async function channelFor(secret) {
  return [...(await derive(secret, "channel"))].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function deriveKeys(secret) {
  const key = async (info, usage) => crypto.subtle.importKey("raw", await derive(secret, info), "AES-GCM", false, [usage]);
  return { toMac: await key("to-mac", "encrypt"), toPhone: await key("to-phone", "decrypt") };
}

export async function seal(key, message) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const body = new TextEncoder().encode(JSON.stringify({ ...message, ts: Date.now(), n: b64u.encode(crypto.getRandomValues(new Uint8Array(9))) }));
  const sealed = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, body));
  const out = new Uint8Array(12 + sealed.length);
  out.set(iv);
  out.set(sealed, 12);
  return b64u.encode(out);
}

/** Returns the message, or null if it wasn't sealed with this key or is stale. */
export async function open(key, text) {
  try {
    const bytes = b64u.decode(text);
    const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: bytes.slice(0, 12) }, key, bytes.slice(12));
    const message = JSON.parse(new TextDecoder().decode(plain));
    if (typeof message.ts !== "number" || Math.abs(Date.now() - message.ts) > MAX_AGE_MS) return null;
    return message;
  } catch {
    return null;
  }
}

// The service worker can't read localStorage, so it gets the secrets from IndexedDB to open
// restart alerts.
function db() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open("remote-keeper", 1);
    request.onupgradeneeded = () => request.result.createObjectStore("computers", { keyPath: "channel" });
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

export async function saveSecretsForWorker(list) {
  const database = await db();
  await new Promise((resolve, reject) => {
    const tx = database.transaction("computers", "readwrite");
    const store = tx.objectStore("computers");
    store.clear();
    for (const c of list) store.put({ channel: c.channel, secret: c.secret, name: c.name || "", offline: c.offline || 0 });
    tx.oncomplete = resolve;
    tx.onerror = () => reject(tx.error);
  });
}

export async function loadSecretsForWorker() {
  const database = await db();
  return new Promise((resolve, reject) => {
    const request = database.transaction("computers").objectStore("computers").getAll();
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}
