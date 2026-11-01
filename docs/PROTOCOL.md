# Remote Keeper relay protocol

The official relay (keeper.mannydlabs.com) isn't part of this repository, and only official releases can use it. If you build Remote Keeper yourself, run your own relay that follows this protocol, then start the Mac app with `REMOTE_KEEPER_HOST=<your host>` and `REMOTE_KEEPER_APP_KEY=<your key>`, and serve `web/` from the same host.

## Keys

A computer has a random 32-byte secret. Its QR code is `https://<host>/#k=<secret, base64url>`. The fragment never reaches a server. Both ends derive these with HKDF-SHA256 (salt `remote-keeper v1`, 32 bytes each):

| info | use |
|---|---|
| `channel` | hex: the channel id the relay routes by |
| `to-mac` | AES-256-GCM key, phone → computer |
| `to-phone` | AES-256-GCM key, computer → phone |

A sealed message is `base64url(nonce(12) ‖ ciphertext ‖ tag(16))` of a JSON object that includes `ts` (ms) and `n` (a random nonce). Receivers drop messages older than 5 minutes, and the computer drops repeated nonces.

## Relay

`GET /v1/ws?c=<channel>&role=mac|phone` upgrades to a WebSocket.

- `role=mac` sends `X-Keeper-Auth: <ms>.<base64url HMAC-SHA256(app key, "mac.<channel>.<ms>")>`. One computer per channel: a new connection replaces the old one.
- `role=phone` comes from the web app (the official relay checks the Origin).
- Frames are JSON. `{"m": "<sealed>"}` from a phone goes to the computer; from the computer it goes to every phone. Phones also get `{"relay":"mac","online":true|false}`. `{"t":"ping"}` is answered with `{"t":"pong"}`.
- Restart alerts (Web Push, VAPID): a phone sends `{"push":"subscribe","sub":<PushSubscription JSON>}` or `{"push":"unsubscribe","endpoint":"…"}`; the computer sends `{"push":"<sealed>"}`, which the relay delivers as `{"c": <first 16 of channel>, "m": "<sealed>"}`. `GET /v1/vapid` returns `{"key": "<VAPID public key>"}`.

## Messages (inside the sealed envelope)

Phone → computer: `{t:"hello"}`, `{t:"choices"}`, `{t:"set", ids:[…]}` (up to 10), `{t:"wake", ids:[…]}`, `{t:"settings"}` (shows the settings popup).

Computer → phone: `{t:"state", mac:{name,version}, claude:{running,since}, locked, ax, claudeSetting, max, sessions:[{id,title,pinned,last,on,waking}]}`, `{t:"choices", sessions:[…]}`, `{t:"result", id, ok, text}`, and (pushed) `{t:"alert", title, body, offline}`.
