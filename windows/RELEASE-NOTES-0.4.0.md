**Remote Keeper for Windows is here.** The same app as on the Mac, for the Claude app on Windows 10 and 11: it keeps your Claude Code sessions in reach from your phone.

- **Download:** `Remote-Keeper-Windows-x64.exe` for most PCs, or `Remote-Keeper-Windows-arm64.exe` for Arm PCs (Snapdragon). Open it: it installs itself for your user only (no administrator rights), opens at login, lives in the tray, and shows a QR code. Scan it with the Remote Keeper iPhone app (tap ＋) or your phone's camera for the web app.
- **First run:** the app isn't code-signed yet, so Windows SmartScreen may say "Windows protected your PC". Choose **More info**, then **Run anyway**.
- **Everything the Mac app does:** alerts when a session's Remote Control goes off, Claude restarts or quits; Reconnect with one tap (it presses the session's own Remote Control switch in about a second, or runs /remote-control, or sends one short message to a session Claude hasn't started); Restart Claude and Install Now for Claude updates (quits Claude properly, so the update installs, and reconnects your sessions); your Claude usage with exact reset times; new sessions; an offline alert if the PC stops checking in (none while it's asleep).
- **Safe by default:** it never types while a session is replying, while you're using the PC, into the wrong session, or over text you haven't sent, and only ever into Claude.
- **Updates:** it checks this page and offers updates in its tray menu and on your phone, and only installs a download that matches the SHA-256 GitHub lists for it.
- **Remove it:** Settings → Apps → Remote Keeper → Uninstall.

Source: [`windows/`](https://github.com/mannyd209/remote-keeper/tree/main/windows).
