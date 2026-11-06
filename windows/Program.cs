// Remote Keeper for Claude Code (Windows).
//
// When the Claude desktop app restarts or updates, every Claude Code session drops Remote Control.
// Remote Keeper lets you reconnect them from your phone: it lives in the tray, links to your phone
// with a QR code, and wakes the sessions you pick (Wake.cs). Messages go through an end-to-end
// encrypted relay (Relay.cs), the same one the Mac app uses.
//
// Settings: %LOCALAPPDATA%\Remote Keeper\config.json. Log: %LOCALAPPDATA%\Remote Keeper\Remote Keeper.log
//
// The app normally runs from the tray. For testing it also takes:
//   list | status | wake <id> [<id>…] [--dry-run] | usage | version | --uninstall

namespace RemoteKeeper;

static class Program
{
    public static bool Console;

    [STAThread]
    static int Main(string[] args)
    {
        var command = args.FirstOrDefault() ?? "";
        if (command is "list" or "status" or "wake" or "usage" or "version" or "restart-claude")
        {
            Console = Native.AttachConsole(-1) || true;
            try { return RunCommand(command, args.Skip(1).ToArray()); }
            catch (Exception e) { System.Console.Error.WriteLine(e); return 1; }
        }
        if (command == "--uninstall") { Installer.Uninstall(); return 0; }

        Log.Write($"Remote Keeper {App.Version} ({App.Arch}) started{(args.Length > 0 ? " " + string.Join(' ', args) : "")}");
        if (Environment.GetEnvironmentVariable("REMOTE_KEEPER_NO_INSTALL") != "1" && Installer.InstallIfNeeded()) return 0;

        using var single = new Mutex(true, @"Local\RemoteKeeper.Tray", out var first);
        if (!first)
        {
            // Opened again (Start menu, or a second double-click): show the running copy's setup window.
            if (command != "--background") Tray.ShowRunningCopy();
            return 0;
        }
        Installer.CleanUp();
        if (command == "--updated" && Installer.RunningInstalled) Installer.Register();
        new Tray().Run(showSetup: command == "--setup");
        return 0;
    }

    static int RunCommand(string command, string[] rest)
    {
        void Say(string s) => System.Console.WriteLine(s);
        switch (command)
        {
            case "version":
                Say(App.Version);
                return 0;
            case "status":
                Say($"Claude data: {Claude.DataDir}");
                Say($"Claude log:  {Claude.LogPath}");
                Say($"Claude: {(Claude.LaunchDate() is DateTime d ? $"running since {d}" : "not running")}, version {Claude.Version() ?? "?"}, Claude Code {Claude.CodeVersion() ?? "?"}");
                Say($"Connect new sessions to Remote Control: {Claude.ConnectsNewSessions()?.ToString() ?? "not set"}");
                Say($"Shown session: {Claude.ShownSessionId() ?? "none"}");
                Say($"Update ready: {Claude.UpdateReady() ?? "none"}; installed at last start: {(Claude.InstalledUpdate() is { } u ? $"{u.from} → {u.to}" : "no")}");
                Say($"Screen locked: {Automation.ScreenLocked()}; idle {Automation.SecondsSinceInput():0}s; Claude in front: {Automation.ClaudeInFront()}");
                Say($"Relay: {(Relay.Configured ? Relay.Host : "not set up")}");
                return 0;
            case "list":
            {
                var status = RemoteControlStatus.Now();
                Say($"Claude started: {status.Launch?.ToString() ?? "not running"}");
                foreach (var s in Claude.LiveSessions().Take(40))
                    Say($"{(status.IsOn(s) ? "on " : "off")} {(s.Pinned ? "*" : " ")} {s.Title}\t{s.Id}");
                return 0;
            }
            case "restart-claude":
            {
                // Testing: what the phone's Restart Claude does, without the reconnect.
                var started = DateTime.Now;
                Keeper.QuitClaude();
                Say($"Claude quit after {(DateTime.Now - started).TotalSeconds:0.0}s");
                Thread.Sleep(3000);
                Claude.Launch();
                Say(Wait.Poll(120, () => Claude.Running, 1) ? $"Claude open again after {(DateTime.Now - started).TotalSeconds:0.0}s" : "Claude didn't open again");
                return 0;
            }
            case "usage":
                if (rest.Contains("--tray")) Say(Usage.KeepClaudeChecking(force: true) ? "Opened and closed Claude's tray menu" : "Couldn't open Claude's tray menu");
                if (rest.Contains("--refresh")) Say(Usage.Refresh(force: true) ? "Read Claude's usage popup" : "Couldn't read Claude's usage popup");
                Say(Usage.Plan()?.ToJsonString() ?? "No usage reading");
                return 0;
            case "wake":
            {
                var dry = rest.Contains("--dry-run");
                var ids = rest.Where(a => !a.StartsWith("--")).ToList();
                var live = Claude.LiveSessions();
                var matched = ids.Select(t => live.FirstOrDefault(s => s.Id == t) ?? live.FirstOrDefault(s => s.Title.Equals(t, StringComparison.OrdinalIgnoreCase))
                    ?? live.FirstOrDefault(s => t.Length > 0 && s.Title.Contains(t, StringComparison.OrdinalIgnoreCase))).ToList();
                if (matched.Count == 0 || matched.Any(m => m == null)) { Say("No session matches. Run: RemoteKeeper list"); return 1; }
                var started = DateTime.Now;
                if (matched.Count > 1 && !dry)
                {
                    Waker.WakeMany(matched.Select(m => m!.Id).ToList(), (id, r) =>
                        Say($"{(DateTime.Now - started).TotalSeconds,5:0.0}s {(r.Success ? "OK " + r.Done!.Text : "!! " + (Claude.Session(id)?.Title ?? id) + ": " + r.Error!.Value.Describe())}"));
                    Say($"Done in {(DateTime.Now - started).TotalSeconds:0.0}s");
                    return 0;
                }
                var result = Waker.Wake(matched[0]!.Id, dryRun: dry);
                Say(result.Success ? $"OK {result.Done!.Text}" : $"!! {result.Error!.Value.Describe()}");
                Say($"({(DateTime.Now - started).TotalSeconds:0.0}s)");
                return result.Success ? 0 : 1;
            }
        }
        return 1;
    }
}
