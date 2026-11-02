<p align="center">
  <img src="web/icons/icon-192.png" alt="Remote Keeper" width="96">
</p>

<h1 align="center">Remote Keeper for Claude Code</h1>

<p align="center">
  <b>Keep your Claude Code sessions reachable from your phone.</b><br>
  When the Claude desktop app restarts or updates, Remote Control switches off for every session.<br>
  Remote Keeper turns it back on from your phone, with one tap.
</p>

<p align="center">
  <a href="https://github.com/mannyd209/remote-keeper/releases/latest/download/Remote-Keeper.dmg"><img src="https://img.shields.io/badge/Download%20for%20Mac-000000?style=for-the-badge&logo=apple&logoColor=white" alt="Download for Mac" height="44"></a>
  &nbsp;
  <a href="https://apps.apple.com/us/app/remote-keeper/id6829386828"><img src="docs/app-store-badge.svg" alt="Download on the App Store" height="44"></a>
  &nbsp;
  <img src="https://img.shields.io/badge/Windows-coming%20soon-555555?style=for-the-badge&logo=windows&logoColor=white" alt="Windows: coming soon" height="44">
  &nbsp;
  <a href="https://ko-fi.com/mannydlabs"><img src="https://img.shields.io/badge/Buy%20me%20a%20coffee-%E2%98%95-FFDD00?style=for-the-badge&labelColor=1a1a1a" alt="Buy me a coffee" height="44"></a>
</p>

<p align="center">
  <a href="#how-it-works">How it works</a> ·
  <a href="#iphone-app">iPhone app</a> ·
  <a href="#install">Install</a> ·
  <a href="#privacy-and-security">Privacy and security</a> ·
  <a href="#faq">FAQ</a> ·
  <a href="https://mannydlabs.com/remote-keeper">Website</a> ·
  <a href="https://github.com/mannyd209/remote-keeper/issues/new/choose">Report a bug / request a feature</a>
</p>

<p align="center">
  <img src="docs/screenshots/01-reconnect.jpg" alt="Remote Control off? One tap. Back on." width="250">
  <img src="docs/screenshots/02-alerts.jpg" alt="Restart alerts with a badge" width="250">
  <img src="docs/screenshots/03-choose.jpg" alt="Pick up to 10 sessions" width="250">
</p>
<p align="center">
  <img src="docs/screenshots/04-computers.jpg" alt="All your Macs, one app" width="250">
  <img src="docs/screenshots/05-home-screen.jpg" alt="Add to your Home Screen" width="250">
  <img src="docs/screenshots/06-private.jpg" alt="End-to-end encrypted" width="250">
</p>

---

## Why I built it

Hi, I'm Manny from **MannyD Labs**. I run a lot of Claude Code sessions on my Mac and check on them from my phone with Remote Control. But every time the Claude app updated or restarted, Remote Control went off for every session, and I couldn't reach any of them until I was back at my desk. Remote Keeper fixes that.

## How it works

When you tap **Reconnect** on your phone, Remote Keeper opens that session in the Claude app on your Mac (starting the app if needed) and types Claude's own **/remote-control** command, which turns Remote Control back on without using any of your Claude usage. A few seconds later the session is back on your phone. (If that ever doesn't take, it falls back to one short, fixed message, *"Remote Keeper: this message reconnects Remote Control for this session. Reply only: ok"*, since a session reconnects by itself once it runs a turn.)

- **Choose the sessions** to keep connected (up to 10 per computer in the web app). Remote Keeper only watches and reconnects those.
- **Alerts:** when any of your chosen sessions loses Remote Control (Claude restarted or quit, or its switch was turned off), your phone gets a notification, and the app icon shows how many are offline.
- **Offline alert:** if Remote Keeper on your Mac stops checking in for 5 minutes (and it isn't because the Mac went to sleep or you quit it), your phone hears about that too, so you know your sessions aren't being watched.
- **Always running:** if macOS ever closes Remote Keeper (say, when memory runs low) or it crashes, it starts again within seconds. Quitting it from the menu still closes it.
- **Several computers:** link as many Macs as you like and switch between them in the app.
- **Nothing to install on your phone:** it's a web app you add to your Home Screen. It opens like an app and works on iPhone and Android.

## iPhone app

The native iPhone app is [free on the App Store](https://apps.apple.com/us/app/remote-keeper/id6829386828): no session limit, a **Reconnect** button right in the notification, Home Screen and Lock Screen widgets, Siri and Shortcuts, Face ID lock, new sessions that show up on their own, and your computers synced with iCloud. It works with the same Mac app.

<p align="center">
  <img src="docs/screenshots/iphone/01-reconnect.jpg" alt="iPhone app: offline sessions with one Reconnect button" width="200">
  <img src="docs/screenshots/iphone/02-new.jpg" alt="iPhone app: new sessions show up, with one tap to add them" width="200">
  <img src="docs/screenshots/iphone/03-alert.jpg" alt="iPhone app: Reconnect right from the alert" width="200">
  <img src="docs/screenshots/iphone/04-connected.jpg" alt="iPhone app: every session back online" width="200">
</p>
<p align="center">
  <img src="docs/screenshots/iphone/05-choose.jpg" alt="iPhone app: choose any sessions on every Mac" width="200">
  <img src="docs/screenshots/iphone/06-widgets.jpg" alt="iPhone app: widgets and Siri" width="200">
  <img src="docs/screenshots/iphone/07-private.jpg" alt="iPhone app: no account, locked with Face ID" width="200">
</p>
## Install

1. **[Download Remote Keeper for Mac](https://github.com/mannyd209/remote-keeper/releases/latest/download/Remote-Keeper.dmg)**, open the DMG and drag **Remote Keeper** to **Applications**. Open it; it lives in your menu bar.
2. **Scan the QR code** it shows with your phone's camera.
3. **Add the page to your Home Screen.** A bouncing arrow points at the right button for your browser.
4. **Allow typing:** Remote Keeper shows a button that opens the exact spot in System Settings (Privacy & Security → Accessibility). It needs this to type its one message into the Claude app.
5. **Choose your sessions** in the app on your phone, and turn on **Restart alerts**.

To add another Mac, install Remote Keeper on it, then tap **＋** in the app on your phone and scan that Mac's code.

<p align="center">
  <img src="docs/screenshots/07-mac-setup.jpg" alt="Scan once on your Mac" width="420">
  <img src="docs/screenshots/08-mac-settings.jpg" alt="Guided setup opens the right settings" width="420">
</p>

**Requirements:** macOS 13 or later and the Claude desktop app, with **Settings → Claude Code → Connect new sessions to Remote Control** turned on (Remote Keeper checks this and opens the right page if it's off). Your Mac has to be awake and unlocked to reconnect a session.

**Updates:** Remote Keeper checks this page's releases and offers **Update** in its menu. It only installs an update that's signed by MannyD Labs and notarized by Apple.

## Privacy and security

- **It only ever types Claude's /remote-control command** (or, as a fallback, one fixed message). Nothing you type on your phone is sent to your computer, so Remote Keeper can't be used to run commands on it.
- **It only reconnects when you tap.** It never reconnects anything on its own.
- **It only reads** the Claude app's session list (titles, pinned, last activity) and its log, and never changes them.
- **End-to-end encrypted.** Your phone and your Mac talk through a small relay, but the QR code holds a secret in the part of the link that browsers never send to a server. Both ends derive their keys from it (HKDF-SHA256, AES-256-GCM), so the relay only passes along ciphertext: it can't read your session names or fake a tap. You can check this in [`web/crypto.js`](web/crypto.js) and [`mac/Relay.swift`](mac/Relay.swift).
- **No account and no tracking.** The relay keeps no session data, only push subscriptions for alerts and, while your Mac is connected, one sealed offline alert from it (encrypted like everything else).

Reconnecting with /remote-control uses no Claude usage. Only the fallback message is a short turn on that session's model.

## FAQ

**Is there an iPhone app?** Yes, it's [free on the App Store](https://apps.apple.com/us/app/remote-keeper/id6829386828) ([screenshots](#iphone-app)). The web app stays, for Android and for anyone who'd rather not install anything.

**What if my Mac goes offline?** If Remote Keeper on your Mac stops checking in for 5 minutes (not because the Mac went to sleep or you quit it), your phone gets an alert. And if macOS ever closes Remote Keeper, it restarts itself within seconds.

**Windows?** Coming soon.

**Why does the Mac need to be unlocked?** Remote Keeper types into the Claude app the same way you would, and macOS doesn't allow typing into a locked screen.

**Can I build it myself?** Yes, the Mac app and the web app are here under the MIT license. (The iPhone app is closed source.) Builds from source don't include our relay or its key (official releases are the only builds that can use it), so to run your own you need your own relay that speaks the same protocol: see [`docs/PROTOCOL.md`](docs/PROTOCOL.md), then set `REMOTE_KEEPER_HOST` and `REMOTE_KEEPER_APP_KEY`. Build with `mac/build.sh`.

## More from MannyD Labs

<a href="https://apps.apple.com/us/app/codemi-kimi-code-remote/id6828491801"><img src="https://raw.githubusercontent.com/mannyd209/codemi/main/docs/banner.jpg" alt="CodeMi" width="100%"></a>

**Use Kimi Code too?** [CodeMi](https://apps.apple.com/us/app/codemi-kimi-code-remote/id6828491801) is a free iPhone and iPad remote for Kimi Code, from the same lab, [on the App Store](https://apps.apple.com/us/app/codemi-kimi-code-remote/id6828491801) ([GitHub](https://github.com/mannyd209/codemi)). Like Remote Keeper, it can turn Remote Control back on when an update switches it off.

## Support

Found a bug or have an idea? [Open an issue](https://github.com/mannyd209/remote-keeper/issues/new/choose). Questions: info@mannydlabs.com. If Remote Keeper saves you a trip back to your desk, you can [buy me a coffee](https://ko-fi.com/mannydlabs). ☕

---

<sub>Remote Keeper is an independent project by MannyD Labs. It is not affiliated with, endorsed by, or sponsored by Anthropic. Claude and Claude Code are trademarks of Anthropic. It relies on parts of the Claude app that aren't public APIs, so an app update can break it.</sub>
