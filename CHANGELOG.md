# Changelog

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
