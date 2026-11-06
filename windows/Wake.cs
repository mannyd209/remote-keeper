// Turning a session's Remote Control back on (mirrors wake() in mac/Sessions.swift):
//  0. a session Claude is running: press its own Remote Control switch (nothing typed);
//  1. otherwise Claude's own /remote-control command (handled by the app, no Claude usage);
//  2. otherwise one fixed message ("Reply only: ok"), since a session reconnects by itself once it
//     runs a turn.
// Nothing else is ever typed, only into Claude, never while it's replying, never into a box with
// your unsent text, and never while someone is using the PC.

namespace RemoteKeeper;

enum WakeError { Locked, NoSession, ClaudeNotRunning, NoMessageBox, NoReply, Busy, WrongSession, Draft, UserActive, NotInFront }

static class WakeErrors
{
    public static string Describe(this WakeError e) => e switch
    {
        WakeError.Locked => "your PC is locked, so nothing was typed. Unlock it and try again.",
        WakeError.NoSession => "that session is gone (archived, or its folder moved).",
        WakeError.ClaudeNotRunning => "the Claude app didn't open.",
        WakeError.NoMessageBox => "Claude's message box didn't get focus, so nothing was typed.",
        WakeError.NoReply => "Remote Control didn't come back on. Check the session in the Claude app.",
        WakeError.Busy => "it's still working on a reply, so nothing was typed. Tap Reconnect again once it's done.",
        WakeError.WrongSession => "Claude didn't switch to that session, so nothing was typed. Tap Reconnect to try again.",
        WakeError.Draft => "there's unsent text in that session's message box, so nothing was typed. Send or clear it, then tap Reconnect.",
        WakeError.UserActive => "someone is using the PC right now, so nothing was typed. Tap Reconnect again in a moment.",
        WakeError.NotInFront => "Claude's window didn't stay in front, so nothing was typed. Tap Reconnect to try again.",
        _ => "something went wrong.",
    };

    /// Claude wasn't ready yet; trying again a little later usually works.
    public static bool WorthRetrying(this WakeError e) => e is WakeError.NoMessageBox or WakeError.WrongSession or WakeError.NotInFront;
}

/// What a reconnect did. `PendingSince` is set when the wake message went out and Claude is
/// reconnecting the session on its own; the caller confirms that from Claude's log later.
sealed record WakeDone(string Text, DateTime? PendingSince = null);

sealed record WakeResult(WakeDone? Done, WakeError? Error)
{
    public static WakeResult Ok(string text, DateTime? pending = null) => new(new WakeDone(text, pending), null);
    public static WakeResult Fail(WakeError e) => new(null, e);
    public bool Success => Done != null;
}

static class Waker
{
    public const string WakeText = "Remote Keeper: this message reconnects Remote Control for this session. Reply only: ok";
    public const string RemoteControlCommand = "/remote-control";

    static bool Started(string id) => RemoteControlStatus.StartedSessions().Contains(id);

    static bool IsOn(Session s) => RemoteControlStatus.Now().IsOn(Claude.Session(s.Id) ?? s);

    /// Reconnects one session. With `verifyLater`, a session that only needs Claude to resume it is
    /// left reconnecting by itself (about a second) while the caller moves on to the next one.
    public static WakeResult Wake(string id, bool dryRun = false, bool verifyLater = false)
    {
        var target = Claude.Session(id);
        if (target == null || target.Archived || !Directory.Exists(target.Cwd)) return WakeResult.Fail(WakeError.NoSession);
        if (IsOn(target)) return WakeResult.Ok($"{target.Title}: Remote Control is already on.");
        if (dryRun) return WakeResult.Ok($"Would reconnect {target.Title} ({id})");
        if (Automation.ScreenLocked()) return WakeResult.Fail(WakeError.Locked);

        // Never type into a session that's replying: wait for its turn to end. Finishing a turn
        // often reconnects it by itself.
        if (!Claude.WaitForTurnToFinish(id)) return WakeResult.Fail(WakeError.Busy);
        if (IsOn(target)) return WakeResult.Ok($"{target.Title}: Remote Control is back on.");

        // Give someone using the PC a moment to pause, so the switch to Claude isn't a surprise.
        Automation.WaitUntilIdle(8, 30);

        if (!Claude.Running)
        {
            Claude.Launch();
            if (!Wait.Poll(30, () => Claude.Running, 1)) return WakeResult.Fail(WakeError.ClaudeNotRunning);
            Thread.Sleep(12_000);   // let it load its sessions
        }
        var launch = Claude.LaunchDate();
        if (launch == null) return WakeResult.Fail(WakeError.ClaudeNotRunning);
        var clock = System.Diagnostics.Stopwatch.StartNew();
        void Step(string what) => Log.Write($"Wake {id}: {what} (+{clock.Elapsed.TotalSeconds:0.0}s)");
        // Right after Claude starts, its window isn't ready for a while: wait until it shows its
        // message box (its page has loaded), up to a minute after it started.
        var sinceLaunch = (DateTime.Now - launch.Value).TotalSeconds;
        if (sinceLaunch < 60)
        {
            var ready = Wait.Poll(60 - sinceLaunch, () =>
            {
                var w = Claude.MainWindow();
                if (w == IntPtr.Zero || !Native.IsWindowVisible(w)) return false;
                Automation.EnableAccessibility(w);
                return Automation.MessageBox(w) != null;
            }, 1);
            Step(ready ? "Claude's window is ready" : "Claude's window still loading; going ahead");
            Thread.Sleep(1500);   // its session list loads just after the page
        }

        // Open the session and make sure Claude actually switched to it.
        var switched = false;
        for (var attempt = 0; attempt < 3 && !switched; attempt++)
        {
            Claude.Open($"claude://claude.ai/epitaxy/{id}");
            switched = Wait.Poll(8, () => Claude.ShownSessionId() == id);
            if (!switched) Log.Write($"Wake {id}: Claude didn't switch to it (attempt {attempt + 1})");
        }
        if (!switched) return WakeResult.Fail(WakeError.WrongSession);
        Step("Claude shows the session");

        var hWnd = Claude.MainWindow();
        Automation.BringForward(hWnd);
        var tree = Automation.WaitForTree(hWnd, sinceLaunch < 180 ? 15 : 8);
        Step(tree ? "its window is readable" : "its window isn't readable yet");

        // 0. A session Claude is running: its own Remote Control switch. Nothing typed.
        if (Started(id) && PressSwitch(id, hWnd, 3) == true) return WakeResult.Ok($"{target.Title}: Remote Control is back on.");

        // A session Claude only just loaded can take a while to show its message box.
        var focused = FocusMessageBox(hWnd, sinceLaunch < 180 ? 15 : 5);
        Step(focused ? "message box focused" : "message box didn't take focus");
        if (!focused)
        {
            Log.Write($"Wake {id}: no message box focus (Claude in front: {Automation.ClaudeInFront()})");
            return WakeResult.Fail(WakeError.NoMessageBox);
        }
        // Check again right before typing: a turn may have started meanwhile, and /remote-control
        // switches Remote Control off if it's already on.
        if (Claude.TurnInProgress(id))
        {
            if (!Claude.WaitForTurnToFinish(id)) return WakeResult.Fail(WakeError.Busy);
            if (!FocusMessageBox(hWnd, 5)) return WakeResult.Fail(WakeError.NoMessageBox);
        }
        if (IsOn(target)) return WakeResult.Ok($"{target.Title}: Remote Control is already on.");

        // 1. A session Claude is running: its own /remote-control command.
        if (Started(id))
        {
            if (ReadyToType(id, hWnd) is WakeError problem) return WakeResult.Fail(problem);
            switch (RunCommand(id, DateTime.Now))
            {
                case Outcome.On: return WakeResult.Ok($"{target.Title}: Remote Control is back on.");
                case Outcome.SwitchedOff:
                    Log.Write($"/remote-control switched {id} off; switching it back on");
                    if (ReadyToType(id, hWnd) is WakeError again) return WakeResult.Fail(again);
                    return RunCommand(id, DateTime.Now) == Outcome.On ? WakeResult.Ok($"{target.Title}: Remote Control is on.") : WakeResult.Fail(WakeError.NoReply);
                case Outcome.NotInFront: return WakeResult.Fail(WakeError.NotInFront);
                default:
                    if (!FocusMessageBox(hWnd, 5)) return WakeResult.Fail(WakeError.NoMessageBox);
                    break;
            }
        }

        // 2. One short message starts the session, and Claude turns Remote Control back on by itself
        //    as it resumes, about a second later. A session whose own switch is off doesn't
        //    reconnect by itself: once it's resumed, /remote-control (or its switch) works.
        if (ReadyToType(id, hWnd) is WakeError p2) return WakeResult.Fail(p2);
        Step("ready to type");
        var switchedOff = (Claude.Session(id) ?? target).UserEnabled == false;
        var sent = DateTime.Now;
        if (!Automation.Type(WakeText)) return WakeResult.Fail(WakeError.NotInFront);
        Thread.Sleep(300);
        if (!Automation.Press(Native.VK_RETURN)) return WakeResult.Fail(WakeError.NotInFront);
        Log.Write($"Sent the wake message to {id} to start it");
        if (verifyLater && !switchedOff) return WakeResult.Ok($"{target.Title}: reconnecting", sent);
        var resumed = false;
        var on = Wait.Poll(20, () =>
        {
            var lines = Claude.LogLines(sent, id);
            resumed = resumed || lines.Any(l => l.Contains($"Mapping internal session {id}") || l.Contains($"Resuming session {id}"));
            return lines.Any(l => l.Contains($"Enabling remote control for session {id}")) || (switchedOff && resumed);
        });
        if (on && !switchedOff) return WakeResult.Ok($"{target.Title}: Remote Control is back on.");
        if (!resumed) return WakeResult.Fail(WakeError.NoReply);
        // It started but didn't reconnect by itself (its switch is off): now the switch works.
        if (!Claude.WaitForTurnToFinish(id)) return WakeResult.Fail(WakeError.Busy);
        if (PressSwitch(id, hWnd, 3) == true) return WakeResult.Ok($"{target.Title}: Remote Control is back on.");
        if (!FocusMessageBox(hWnd, 5)) return WakeResult.Fail(WakeError.NoMessageBox);
        if (ReadyToType(id, hWnd) is WakeError p3) return WakeResult.Fail(p3);
        return RunCommand(id, DateTime.Now) == Outcome.On ? WakeResult.Ok($"{target.Title}: Remote Control is back on.") : WakeResult.Fail(WakeError.NoReply);
    }

    /// Reconnects sessions in order without waiting on each one (see wakeMany in mac/Sessions.swift).
    public static void WakeMany(IList<string> ids, Action<string, WakeResult> report)
    {
        var pending = new List<(string id, DateTime since)>();
        var again = new List<string>();
        void Settle(bool final)
        {
            pending.RemoveAll(item =>
            {
                if (Claude.LogLines(item.since, item.id).Any(l => l.Contains($"Enabling remote control for session {item.id}")))
                {
                    Log.Write($"Claude reconnected {item.id} by itself after the wake message");
                    report(item.id, WakeResult.Ok($"{Claude.Session(item.id)?.Title ?? "That session"}: Remote Control is back on."));
                    return true;
                }
                if (final || (DateTime.Now - item.since).TotalSeconds > 15) { again.Add(item.id); return true; }
                return false;
            });
        }
        foreach (var id in ids)
        {
            var result = Wake(id, verifyLater: true);
            if (result.Done?.PendingSince is DateTime since) pending.Add((id, since));
            else if (result.Error is WakeError e && e.WorthRetrying()) { Log.Write($"Wake {id}: will try again after the others"); again.Add(id); }
            else report(id, result);
            Settle(false);
        }
        Wait.Poll(15, () => { Settle(false); return pending.Count == 0; });
        Settle(true);
        foreach (var id in again) report(id, Wake(id));
    }

    // MARK: Steps

    /// Presses the session's Remote Control switch, when it's off and the session is shown. True when
    /// Claude says it's turning it on; null when there's no switch or Claude didn't take it.
    static bool? PressSwitch(string id, IntPtr hWnd, double seconds)
    {
        Interop.UIAutomationClient.IUIAutomationElement? toggle = null;
        if (!Wait.Poll(seconds, () => (toggle = Automation.RemoteControlSwitch(hWnd)) != null, 0.3) || toggle == null)
        {
            Log.Write($"Wake {id}: no Remote Control switch in Claude's window; typing instead");
            return null;
        }
        // On already but Claude doesn't say so yet: pressing it would switch it off.
        if (Automation.SwitchIsOn(toggle) != false || Claude.ShownSessionId() != id) return null;
        var since = DateTime.Now;
        if (!Automation.PressSwitch(toggle)) return null;
        var refused = false;
        var enabling = Wait.Poll(5, () =>
        {
            var lines = Claude.LogLines(since, id);
            refused = lines.Any(l => l.Contains($"Cannot toggle remote control for {id}"));
            return refused || lines.Any(l => l.Contains($"Enabling remote control for session {id}"));
        }, 0.1) && !refused;
        Log.Write($"Wake {id}: pressed its Remote Control switch ({(enabling ? "Claude is turning it on" : refused ? "Claude refused: not running yet" : "no answer")})");
        return enabling ? true : null;
    }

    static bool FocusMessageBox(IntPtr hWnd, double seconds)
    {
        var tries = 0;
        return Wait.Poll(seconds, () =>
        {
            tries++;
            if (!Automation.ClaudeInFront() || tries % 8 == 0) Automation.BringForward(hWnd);
            var box = Automation.MessageBox(hWnd);
            return box != null && (Automation.HasFocus(box) || Automation.Focus(box));
        }, 0.25);
    }

    /// Text Remote Keeper itself may have left in a message box. Anything else belongs to you.
    static bool IsOwnLeftover(string text)
    {
        var t = text.Trim();
        return t == "remote-control" || t == RemoteControlCommand || t == WakeText;
    }

    /// Checked right before anything is typed: Claude shows this session, its message box is empty,
    /// and nobody is using the PC.
    static WakeError? ReadyToType(string id, IntPtr hWnd)
    {
        if (Claude.TurnInProgress(id)) { Log.Write($"Wake {id}: a turn started; nothing typed"); return WakeError.Busy; }
        if (!Automation.WaitUntilIdle(5, 30)) { Log.Write($"Wake {id}: someone is using the PC; nothing typed"); return WakeError.UserActive; }
        var shown = Claude.ShownSessionId();
        if (shown != id) { Log.Write($"Wake {id}: Claude is showing {shown ?? "no session"}, not this one; nothing typed"); return WakeError.WrongSession; }
        if (!Automation.ClaudeInFront() && !Automation.BringForward(hWnd)) return WakeError.NotInFront;
        var box = Automation.MessageBox(hWnd);
        if (box == null || !(Automation.HasFocus(box) || Automation.Focus(box))) return WakeError.NoMessageBox;
        var text = Automation.Text(box) ?? "";
        if (text.Trim().Length > 0)
        {
            if (IsOwnLeftover(text))
            {
                Automation.ClearBox();
                Thread.Sleep(300);
                Log.Write($"Wake {id}: cleared text Remote Keeper had left in its message box");
                if ((Automation.Text(box) ?? "").Trim().Length == 0) return null;
            }
            Log.Write($"Wake {id}: its message box has unsent text; nothing typed");
            return WakeError.Draft;
        }
        return null;
    }

    enum Outcome { On, SwitchedOff, NotRunning, Nothing, NotInFront }

    /// Types /remote-control into the open session and reads Claude's log for what it did.
    static Outcome RunCommand(string id, DateTime start)
    {
        if (!Automation.Type(RemoteControlCommand)) return Outcome.NotInFront;
        Thread.Sleep(300);
        // Escape closes Claude's command menu, so Return sends exactly what was typed.
        Automation.Press(Native.VK_ESCAPE);
        Thread.Sleep(150);
        if (!Automation.Press(Native.VK_RETURN)) return Outcome.NotInFront;
        var outcome = Outcome.Nothing;
        Wait.Poll(8, () =>
        {
            var lines = Claude.LogLines(start, id);
            if (lines.Any(l => l.Contains($"Enabling remote control for session {id}"))) outcome = Outcome.On;
            else if (lines.Any(l => l.Contains($"Disabling remote control for session {id}"))) outcome = Outcome.SwitchedOff;
            else if (lines.Any(l => l.Contains($"Cannot toggle remote control for {id}"))) outcome = Outcome.NotRunning;
            return outcome != Outcome.Nothing;
        });
        if (outcome == Outcome.On) Log.Write($"Turned Remote Control on for {id} with /remote-control");
        if (outcome == Outcome.NotRunning) Log.Write($"/remote-control: {id} isn't running");
        return outcome;
    }
}
