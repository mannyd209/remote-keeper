# Changelog

## 0.3.10

- Reconnect All right after a Claude restart no longer leaves one behind: a session that fails only because Claude wasn't ready yet (no message box, or Claude didn't switch to it) is tried once more after the others, before your phone hears it failed.
- More patience after a restart: waits until Claude has been open a minute, and gives a session Claude just loaded longer to show its message box.
- If a session's message box holds only Remote Keeper's own leftover text (its /remote-control command or wake message), it clears it and carries on. Anything else in the box still means nothing is typed.

## 0.3.9

- Never types into the wrong place. Right before typing anything, Remote Keeper now checks that Claude is actually showing the session it's reconnecting, that the session's message box is empty, and that nobody is using the Mac. If any of those isn't true, nothing is typed and your phone says why. (Before, if Claude stayed on another session, the reconnect could be typed into that session, mixed into whatever you were writing.)
- Fixes long waits after a Claude restart: opening a session counted as "in the middle of a reply," so Reconnect could wait 2 minutes per session for nothing. Only a sent message counts now.
- Waits for Claude to finish starting up before reconnecting, so the first reconnect after a restart no longer fails with "message box didn't get focus."

## 0.3.8

- Never types into a session that's replying: if you tap Reconnect while a session is in the middle of a turn, Remote Keeper waits up to 2 minutes for the turn to finish before running /remote-control (finishing a turn often reconnects it by itself). If it's still busy after that, nothing is typed and your phone says to try again once it's done. Thanks to u/akhi1uuu on Reddit for spotting this.

## 0.3.7

- New sessions show up on your phone: when you start a Claude Code session on your Mac, the iPhone app and the web app show it under "New on your Mac" with one tap to add it. Not Now hides it.
- Renamed sessions update on your phone within seconds.
- Optional alert for new sessions in the iPhone app (1.1: Settings → Notifications → New Sessions). Off by default.
- Memory checked: a 4,000-check soak test (about 11 hours) stayed flat at about 20 MB.

## 0.3.6

- Fixes a memory leak: the restart watcher never freed what it read, so it could grow until macOS closed it for low memory. It now stays around 20 MB and only re-reads session files that changed.
- Stays running: it runs as a login item that macOS restarts within seconds if it's ever closed by the system or crashes. Quit from the menu still closes it.
- Offline alert: if Remote Keeper on your Mac goes quiet for 5 minutes without sleeping or being quit, your phone gets "Remote Keeper is offline on your Mac".
- If it ever goes over 400 MB it restarts itself, and the log notes when a previous run stopped unexpectedly.

## 0.3.5

- No limit on how many sessions a computer keeps connected (the web app still lets you choose 10 per computer; the upcoming iPhone app, any number). Reconnect All handles up to 50 at a time.

## 0.3.4

- Update notifications: when a new Remote Keeper is out, your Mac sends your phone one notification for that version, and the web app shows a banner at the top. Tap it to update that Mac. It shows Updating… until the Mac is back on the new version.
- Checks for updates every 4 hours.

## 0.3.3

- Reconnecting works when Claude isn't in front: Remote Keeper brings Claude forward through macOS and focuses the session's message box itself (it used to stop with "message box didn't get focus").
- Reconnects sessions Claude isn't currently running: /remote-control only works on a running session, so Remote Keeper first starts it with one short message, then turns Remote Control on.
- Logs to ~/Library/Logs/Remote Keeper.log.

## 0.3.2

- Update from your phone: the web app shows each Mac's version, and an Update button when a new release is out. The Mac installs it only if it's signed by MannyD Labs and notarized.
- Web app: rename a computer and label it Work, Personal or Hobby (kept on your phone); full computer names; an About section with support, GitHub and Buy me a coffee links.

## 0.3.1

- Knows each session's real Remote Control state (Claude's per-session switch and its log), instead of guessing from the last restart. A session you switch off by hand now shows as off.
- Alerts when any of your chosen sessions goes off, for any reason: Claude restarted or quit, or a session's Remote Control was switched off. The alert updates the app badge.
- Reconnects with Claude's own /remote-control command, which uses no Claude usage and also works for sessions that were switched off. Falls back to the short message if needed.

## 0.3.0 (first public release)

- Remote Keeper for Mac: menu bar app with a QR setup window, an Allow Typing step, and a settings popup with buttons that open the exact place in System Settings (Accessibility, Login Items) or Claude's settings.
- Phone web app: your chosen sessions (up to 10 per computer), Reconnect and Reconnect All, restart alerts, an app badge with the number of offline sessions, several computers, and an Add to Home Screen arrow that adapts to your browser.
- End-to-end encrypted relay; official builds only.
- Updates from GitHub Releases, installed only when signed by MannyD Labs and notarized by Apple.
