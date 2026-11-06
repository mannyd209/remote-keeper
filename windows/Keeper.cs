// What the phone can ask for, and the alerts (mirrors mac/Keeper.swift). The phone can only: get the
// status of your chosen sessions, list sessions to choose from, choose them, ask to reconnect chosen
// ones, show the settings popup, install the latest update, mark new sessions as seen, turn
// new-session alerts on or off, and restart Claude. Waking always types the same fixed text, so
// nothing a phone sends is ever typed or run on this computer.

using System.Diagnostics;
using System.Text.Json.Nodes;

namespace RemoteKeeper;

sealed class Keeper
{
    public const int MaxBatch = 50;
    public const int MaxWatched = 500;

    public readonly Store Store = new();
    public RelayConnection Relay = null!;
    readonly SerialQueue queue = new("keeper");
    readonly SerialQueue wakeQueue = new("wake");
    readonly HashSet<string> waking = new();   // only touched on `queue`
    volatile bool restartingClaude;
    volatile bool awake = true;
    public string? AvailableUpdate;   // a newer release, if any

    public Action? OnChange;           // the tray should refresh
    public Action? OnNeedsSettings;    // show the settings popup
    public Action? OnUpdateRequested;  // the phone asked to update this PC

    public bool RelayConnected => Relay?.Connected == true;
    public bool PhoneLinked => Store.Current.PhoneSeenAt != null;
    static string Computer => App.ComputerName;

    public void Start()
    {
        // The first run counts every existing session as known, so only new ones show up as new.
        var existing = Claude.AllSessions().Select(s => s.Id).ToList();
        Store.Update(c =>
        {
            var exists = existing.ToHashSet();
            c.Known = c.Known != null ? c.Known.Where(exists.Contains).ToList() : existing;
        });
        Claude.RememberVersion();
        Connect();
        WatchForRestarts();
        // Refreshed every 30 minutes: phones only trust an alert for a day.
        _ = new Timer(_ => SendWill(), null, TimeSpan.FromMinutes(30), TimeSpan.FromMinutes(30));
    }

    // MARK: Sleep and the offline alert

    public void WillSleep() { awake = false; Relay.WithdrawWill(); }
    public void DidWake() { awake = true; SendWill(); }

    /// The alert the relay sends if this PC goes quiet (see RelayConnection.SetWill).
    public void SendWill()
    {
        if (!awake || !RelayConnected || Store.Watched.Count == 0) return;
        Log.Write("Offline alert armed with the relay");
        Relay.SetWill(new JsonObject
        {
            ["t"] = "alert", ["kind"] = "offline", ["title"] = $"Remote Keeper is offline on {Computer}",
            ["body"] = "It hasn't checked in for 5 minutes, so your sessions there aren't being watched. Check that the PC is on, awake and online.",
        });
    }

    /// Before quitting: a PC you closed on purpose doesn't need an alert.
    public void WithdrawWill() => Relay?.WithdrawWill();

    void Connect()
    {
        Relay = new RelayConnection(new ChannelKeys(Store.SecretData),
            message => queue.Run(() => Handle(message)),
            up =>
            {
                Log.Write(up ? "Connected to the relay" : "Disconnected from the relay");
                if (up) SendWill();
                OnChange?.Invoke();
            });
        Relay.Start();
    }

    /// A new secret: every linked phone stops working, and the QR code changes.
    public void UnlinkAllPhones()
    {
        Relay.WithdrawWill();
        Relay.Stop();
        Store.Update(c => { c.Secret = Store.NewSecret(); c.PhoneSeenAt = null; });
        Connect();
        OnChange?.Invoke();
    }

    // MARK: Messages from a phone

    void Handle(JsonObject message)
    {
        var firstTime = Store.Current.PhoneSeenAt == null;
        Store.Update(c => c.PhoneSeenAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0);
        if (firstTime) { Log.Write("A phone linked"); OnChange?.Invoke(); }
        List<string> Ids() => message["ids"] is JsonArray a ? a.Select(x => Json.Str(x)).Where(x => x.Length > 0).ToList() : new();
        switch (Json.Str(message["t"]))
        {
            case "hello":
                SendState();
                break;
            case "update":
                // From the phone's Update button: installs the latest release (see Updater.cs).
                OnUpdateRequested?.Invoke();
                break;
            case "settings":
                // From the phone's "Show on PC" button: opens the settings popup here. Nothing else.
                OnNeedsSettings?.Invoke();
                break;
            case "choices":
            {
                var list = new JsonArray();
                foreach (var s in Claude.LiveSessions().Take(300)) list.Add(Brief(s));
                Relay.Send(new JsonObject { ["t"] = "choices", ["sessions"] = list });
                break;
            }
            case "set":
            {
                var live = Claude.LiveSessions().Select(s => s.Id).ToHashSet();
                var unique = Ids().Where(live.Contains).Distinct().Take(MaxWatched).ToList();
                Store.Update(c => { c.Watched = unique; c.Known = (c.Known ?? new()).Union(unique).ToList(); });
                SendState();
                if (unique.Count == 0) Relay.WithdrawWill(); else SendWill();
                break;
            }
            case "seen":
            {
                var ids = Ids().Take(MaxWatched).ToList();
                Store.Update(c => c.Known = (c.Known ?? new()).Union(ids).ToList());
                SendState();
                break;
            }
            case "prefs":
                if (message["alertNew"] is JsonValue v && v.TryGetValue<bool>(out var on)) { Store.Update(c => c.AlertNew = on); SendState(); }
                break;
            case "restartClaude":
                RestartClaude(message["force"] is JsonValue f && f.TryGetValue<bool>(out var force) && force);
                break;
            case "wake":
            {
                var live = Claude.LiveSessions().Select(s => s.Id).ToHashSet();
                var chosen = Store.Watched.ToHashSet();
                EnqueueWake(Ids().Where(id => live.Contains(id) && chosen.Contains(id) && !waking.Contains(id)).Take(MaxBatch).ToList());
                break;
            }
        }
    }

    static JsonObject Brief(Session s) => new()
    {
        ["id"] = s.Id, ["title"] = s.Title.Length > 120 ? s.Title[..120] : s.Title, ["pinned"] = s.Pinned, ["last"] = (long)s.LastTurn,
    };

    // MARK: State for the phone

    /// Your chosen sessions, in the order you picked them, with their status. Runs on `queue` or not;
    /// it only reads.
    public void SendState()
    {
        var status = RemoteControlStatus.Now();
        var launch = status.Launch;
        var live = Claude.LiveSessions().GroupBy(s => s.Id).ToDictionary(g => g.Key, g => g.First());
        HashSet<string> wakingNow;
        lock (waking) wakingNow = new(waking);
        var sessions = new JsonArray();
        foreach (var id in Store.Watched)
        {
            if (!live.TryGetValue(id, out var s)) continue;
            var entry = Brief(s);
            entry["on"] = status.IsOn(s);
            entry["waking"] = wakingNow.Contains(s.Id);
            if (s.RemoteId != null) entry["remote"] = s.RemoteId;
            sessions.Add(entry);
        }
        var claude = new JsonObject
        {
            ["running"] = launch != null,
            ["restarting"] = restartingClaude,
            ["since"] = launch == null ? null : new DateTimeOffset(launch.Value).ToUnixTimeMilliseconds(),
            ["version"] = Claude.Version(),
            ["update"] = Claude.UpdateReady(),
            ["code"] = Claude.CodeVersion(),
        };
        if (Claude.InstalledUpdate() is { } installed && launch != null)
        {
            var byPhone = Store.Current.RestartedClaudeAt ?? 0;
            claude["updated"] = new JsonObject
            {
                ["from"] = installed.from, ["to"] = installed.to,
                ["byPhone"] = Math.Abs(new DateTimeOffset(launch.Value).ToUnixTimeSeconds() - byPhone) < 300,
            };
        }
        var fresh = new JsonArray();
        foreach (var s in NewSessions(live.Values.OrderByDescending(x => x.LastTurn).ToList())) fresh.Add(Brief(s));
        Relay.Send(new JsonObject
        {
            ["t"] = "state",
            ["mac"] = new JsonObject { ["name"] = Computer, ["version"] = App.Version, ["platform"] = "windows" },
            ["claude"] = claude,
            ["locked"] = Automation.ScreenLocked(),
            ["ax"] = true,   // Windows needs no permission to type
            ["claudeSetting"] = Claude.ConnectsNewSessions() == true,
            ["max"] = MaxWatched,
            ["update"] = AvailableUpdate,
            ["sessions"] = sessions,
            ["new"] = fresh,
            ["alertNew"] = Store.Current.AlertNew == true,
            ["usage"] = Usage.Plan(),
        });
    }

    /// Sessions made since your phone last looked: not chosen, past their first turn. Newest first, at most 10.
    public List<Session> NewSessions(List<Session>? live = null)
    {
        var known = (Store.Current.Known ?? new()).ToHashSet();
        var watched = Store.Watched.ToHashSet();
        return (live ?? Claude.LiveSessions()).Where(s => s.Turns > 0 && !known.Contains(s.Id) && !watched.Contains(s.Id)).Take(10).ToList();
    }

    /// What the phone shows that can change without any session dropping.
    string ShownSignature(List<Session> sessions)
    {
        var live = sessions.GroupBy(s => s.Id).ToDictionary(g => g.Key, g => g.First());
        var chosen = Store.Watched.Where(live.ContainsKey).Select(id => $"{id}\u0001{live[id].Title}\u0001{live[id].Pinned}");
        return string.Join("\u0002", chosen.Append("|").Concat(NewSessions(sessions).Select(s => $"{s.Id}\u0001{s.Title}")));
    }

    // MARK: Updates

    /// A newer Remote Keeper is out (or null): show it on the phone, and send one notification per version.
    public void SetAvailableUpdate(string? version)
    {
        queue.Run(() =>
        {
            if (AvailableUpdate == version) return;
            AvailableUpdate = version;
            SendState();
            if (version == null || Store.Current.NotifiedUpdate == version || !PhoneLinked) return;
            Store.Update(c => c.NotifiedUpdate = version);
            Relay.Push(new JsonObject
            {
                ["t"] = "alert", ["kind"] = "update", ["title"] = $"Remote Keeper {version} is available",
                ["body"] = $"For {Computer}. Tap to update it from your phone.", ["offline"] = OfflineWatched().Count,
            });
        });
    }

    // MARK: Waking

    /// Wakes sessions one at a time. Call on `queue`.
    void EnqueueWake(List<string> ids)
    {
        if (ids.Count == 0) { SendState(); return; }
        lock (waking) foreach (var id in ids) waking.Add(id);
        SendState();
        wakeQueue.Run(() => Waker.WakeMany(ids, (id, result) => queue.Run(() =>
        {
            lock (waking) waking.Remove(id);
            var name = Claude.Session(id)?.Title ?? "That session";
            if (result.Done != null) Relay.Send(new JsonObject { ["t"] = "result", ["id"] = id, ["ok"] = true, ["text"] = result.Done.Text });
            else Relay.Send(new JsonObject { ["t"] = "result", ["id"] = id, ["ok"] = false, ["text"] = $"{name}: {result.Error!.Value.Describe()}" });
            SendState();
        })));
    }

    /// From the phone's Restart Claude button: quits Claude (which installs a downloaded update),
    /// opens it again, and reconnects your chosen sessions. Not while a session is replying, unless
    /// the phone insists.
    void RestartClaude(bool force)
    {
        if (restartingClaude) return;
        wakeQueue.Run(() =>
        {
            if (!force && Claude.LiveSessions().FirstOrDefault(s => Claude.TurnInProgress(s.Id)) is Session busy)
            {
                Relay.Send(new JsonObject { ["t"] = "result", ["ok"] = false, ["text"] = $"Claude is still working in “{busy.Title}”. Try again when it's done." });
                return;
            }
            var update = Claude.UpdateReady();
            restartingClaude = true;
            SendState();
            try
            {
                Log.Write("Restarting Claude from the phone" + (update != null ? $" to install {update}" : ""));
                if (Claude.Running)
                {
                    QuitClaude();
                    if (!Wait.Poll(90, () => !Claude.Running, 0.5))
                    {
                        Relay.Send(new JsonObject { ["t"] = "result", ["ok"] = false, ["text"] = $"Claude didn't quit on {Computer}. It may be asking something on screen." });
                        return;
                    }
                    Thread.Sleep(3000);
                }
                Claude.Launch();
                Store.Update(c => c.RestartedClaudeAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds());
                if (!Wait.Poll(120, () => Claude.Running, 1))
                {
                    Relay.Send(new JsonObject { ["t"] = "result", ["ok"] = false, ["text"] = $"Claude didn't open again on {Computer}." });
                    return;
                }
                Thread.Sleep(2000);
                Claude.RememberVersion();
                var version = Claude.Version();
                var installed = update != null && update == version;
                var live = Claude.LiveSessions().Select(s => s.Id).ToHashSet();
                var ids = Store.Watched.Where(live.Contains).Take(MaxBatch).ToList();
                Relay.Send(new JsonObject
                {
                    ["t"] = "result", ["ok"] = true,
                    ["text"] = (installed ? $"Claude {version} is installed." : "Claude is open again.")
                        + (ids.Count == 0 ? "" : $" Reconnecting {(ids.Count == 1 ? "your session" : $"your {ids.Count} sessions")}…"),
                });
                queue.Run(() => { lock (waking) ids = ids.Where(id => !waking.Contains(id)).ToList(); EnqueueWake(ids); });
            }
            finally { restartingClaude = false; SendState(); }
        });
    }

    /// Asks Claude's windows to close, then ends any Claude process still running after 15 seconds.
    static void QuitClaude()
    {
        foreach (var p in Claude.Processes())
        {
            try { if (p.MainWindowHandle != IntPtr.Zero) p.CloseMainWindow(); } catch { }
            p.Dispose();
        }
        if (Wait.Poll(15, () => !Claude.Running, 0.5)) return;
        foreach (var p in Claude.Processes())
        {
            try { p.Kill(entireProcessTree: true); } catch { }
            p.Dispose();
        }
    }

    public List<string> OfflineWatched()
    {
        var status = RemoteControlStatus.Now();
        var live = Claude.LiveSessions().GroupBy(s => s.Id).ToDictionary(g => g.Key, g => g.First());
        return Store.Watched.Where(id => live.TryGetValue(id, out var s) && !status.IsOn(s)).ToList();
    }

    public void WakeWatched() => queue.Run(() =>
    {
        List<string> ids;
        lock (waking) ids = OfflineWatched().Where(id => !waking.Contains(id)).Take(MaxBatch).ToList();
        EnqueueWake(ids);
    });

    // MARK: Alerts

    readonly SemaphoreSlim watcherNudge = new(0);
    DateTime lastNudge = DateTime.MinValue;
    readonly List<FileSystemWatcher> watchers = new();

    void Nudge()
    {
        // At most about once a second: Claude writes its log often.
        if ((DateTime.UtcNow - lastNudge).TotalSeconds < 1) return;
        lastNudge = DateTime.UtcNow;
        if (watcherNudge.CurrentCount == 0) watcherNudge.Release();
    }

    /// Instant updates: Claude writes to its log whenever a session's Remote Control changes, and
    /// saves a usage reading about every 5 minutes.
    void WatchClaudeFiles()
    {
        foreach (var w in watchers) w.Dispose();
        watchers.Clear();
        void Watch(string file, Action changed)
        {
            try
            {
                var dir = Path.GetDirectoryName(file)!;
                if (!Directory.Exists(dir)) return;
                var w = new FileSystemWatcher(dir, Path.GetFileName(file)) { NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.FileName };
                w.Changed += (_, _) => changed();
                w.Created += (_, _) => changed();
                w.Renamed += (_, _) => changed();
                w.EnableRaisingEvents = true;
                watchers.Add(w);
            }
            catch (Exception e) { Log.Write($"Can't watch {file}: {e.Message}"); }
        }
        Watch(Claude.LogPath, Nudge);
        Watch(Claude.PlanUsageFile, () => { if (PhoneLinked) queue.Run(SendState); });
    }

    void WatchForRestarts()
    {
        WatchClaudeFiles();
        var thread = new Thread(() =>
        {
            var lastLaunch = Claude.LaunchDate();
            var lastOffline = OfflineWatched().ToHashSet();
            var live0 = Claude.LiveSessions();
            var lastShown = ShownSignature(live0);
            var lastNew = NewSessions(live0).Select(s => s.Id).ToHashSet();
            DateTime? quitSince = null;
            var quitAlerted = false;
            var updateCheckedAt = DateTime.MinValue;
            DateTime? restartAlertAt = null;
            var logPath = Claude.LogPath;

            bool IsWaking(string id) { lock (waking) return waking.Contains(id); }

            void Pass()
            {
                if (Claude.LogPath != logPath) { logPath = Claude.LogPath; WatchClaudeFiles(); }
                var launch = Claude.LaunchDate();

                // Claude quit: say so once if it stays closed for a minute.
                if (launch == null)
                {
                    if (quitSince == null) queue.Run(SendState);
                    quitSince ??= DateTime.UtcNow;
                    if (!quitAlerted && !restartingClaude && (DateTime.UtcNow - quitSince.Value).TotalSeconds > 60 && Store.Watched.Count > 0)
                    {
                        quitAlerted = true;
                        queue.Run(SendState);
                        var n = Store.Watched.Count;
                        Relay.Push(new JsonObject
                        {
                            ["t"] = "alert", ["title"] = $"Claude quit on {Computer}", ["offline"] = n,
                            ["body"] = $"Remote Control is off for {(n == 1 ? "your session" : $"all {n} of your sessions")}. Tap to reconnect; Remote Keeper opens Claude.",
                        });
                    }
                    lastOffline = Store.Watched.ToHashSet();
                    return;
                }
                quitSince = null;
                quitAlerted = false;

                // Claude downloaded an update: say so once per version.
                if ((DateTime.UtcNow - updateCheckedAt).TotalSeconds > 120)
                {
                    updateCheckedAt = DateTime.UtcNow;
                    Claude.RememberVersion();
                    if (Claude.UpdateReady() is string update && Store.Current.ClaudeUpdateAlerted != update)
                    {
                        Store.Update(c => c.ClaudeUpdateAlerted = update);
                        Log.Write($"Claude {update} is ready to install");
                        queue.Run(SendState);
                        if (PhoneLinked)
                            Relay.Push(new JsonObject
                            {
                                ["t"] = "alert", ["kind"] = "claudeUpdate", ["version"] = update,
                                ["title"] = $"Claude {update} is ready on {Computer}",
                                ["body"] = "Install it now and Remote Keeper brings your sessions right back. Otherwise Claude restarts by itself later and they go offline.",
                            });
                    }
                }

                // A chosen session was renamed or pinned, or a new session appeared: tell the phone.
                var live = Claude.LiveSessions();
                var shown = ShownSignature(live);
                if (shown != lastShown)
                {
                    lastShown = shown;
                    queue.Run(SendState);
                    var fresh = NewSessions(live);
                    var added = fresh.Where(s => !lastNew.Contains(s.Id)).ToList();
                    lastNew = fresh.Select(s => s.Id).ToHashSet();
                    if (added.Count > 0 && Store.Current.AlertNew == true && PhoneLinked)
                    {
                        var title = added.Count == 1 ? $"“{added[0].Title}”" : $"{added.Count} new sessions";
                        Relay.Push(new JsonObject
                        {
                            ["t"] = "alert", ["kind"] = "new", ["title"] = $"New session on {Computer}",
                            ["body"] = $"{title}. Tap to keep {(added.Count == 1 ? "it" : "them")} connected.",
                        });
                    }
                }

                // Claude restarted: every session dropped. The alert waits 45 seconds, so sessions that
                // come back by themselves don't set it off.
                if (launch != lastLaunch)
                {
                    lastLaunch = launch;
                    Log.Write("Claude restarted");
                    lastOffline = OfflineWatched().ToHashSet();
                    restartAlertAt = DateTime.UtcNow.AddSeconds(45);
                    queue.Run(SendState);
                    return;
                }
                if (restartAlertAt is DateTime due && DateTime.UtcNow >= due && !restartingClaude)
                {
                    restartAlertAt = null;
                    var offlineNow = OfflineWatched().Where(id => !IsWaking(id)).ToList();
                    lastOffline = OfflineWatched().ToHashSet();
                    queue.Run(SendState);
                    if (offlineNow.Count > 0)
                        Relay.Push(new JsonObject
                        {
                            ["t"] = "alert", ["title"] = $"Claude restarted on {Computer}", ["offline"] = offlineNow.Count,
                            ["body"] = $"Remote Control is off for {(offlineNow.Count == 1 ? "1 of your sessions" : $"{offlineNow.Count} of your sessions")}. Tap to reconnect.",
                        });
                    return;
                }

                // A session went off (its switch, or it dropped) or came back.
                var offline = OfflineWatched().ToHashSet();
                if (offline.SetEquals(lastOffline)) return;
                var newlyOff = offline.Except(lastOffline).Where(id => !IsWaking(id)).ToList();
                lastOffline = offline;
                queue.Run(SendState);
                if (newlyOff.Count == 0) return;
                var name = newlyOff.Count == 1 ? (Claude.Session(newlyOff[0])?.Title ?? "A session") : $"{newlyOff.Count} sessions";
                Relay.Push(new JsonObject
                {
                    ["t"] = "alert", ["title"] = $"Remote Control off on {Computer}", ["offline"] = offline.Count,
                    ["body"] = $"{name} can't be reached from your phone. Tap to reconnect.",
                });
            }

            while (true)
            {
                // Every 10 seconds, or sooner when Claude writes to its log.
                watcherNudge.Wait(TimeSpan.FromSeconds(10));
                try { Pass(); } catch (Exception e) { Log.Write("Watcher: " + e); }
            }
        }) { IsBackground = true, Name = "watcher" };
        thread.SetApartmentState(ApartmentState.MTA);
        thread.Start();
    }
}
