// Reading the Claude app (read-only): where it keeps its data and log on Windows, whether it's
// running and since when, its sessions, whether each one's Remote Control is on (from Claude's own
// log), its updates, and the plan usage it saves. Mirrors mac/Sessions.swift.
//
// Claude for Windows is a packaged (MSIX) app. It keeps its data in
// %LOCALAPPDATA%\Claude-Data\claude_<publisher id> and its log in %LOCALAPPDATA%\Claude\logs.

using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;

namespace RemoteKeeper;

sealed record Session(string Id, string Title, string Cwd, bool Pinned, bool Archived, double LastTurn, double LastActivity,
                      int Turns, bool? UserEnabled, string? RemoteId, bool Scheduled);

static class Claude
{
    static readonly string LocalAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
    static readonly string RoamingAppData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);

    // MARK: Where things are

    static string? dataDir;
    static DateTime dataDirAt;

    /// Claude's data folder: the packaged app's Claude-Data\claude_*, else %APPDATA%\Claude.
    public static string DataDir
    {
        get
        {
            if (dataDir != null && DateTime.UtcNow - dataDirAt < TimeSpan.FromMinutes(5)) return dataDir;
            var root = Path.Combine(LocalAppData, "Claude-Data");
            string? found = null;
            try
            {
                found = Directory.Exists(root)
                    ? Directory.GetDirectories(root, "claude_*").OrderByDescending(d => Directory.Exists(Path.Combine(d, "claude-code-sessions")))
                        .ThenByDescending(d => File.Exists(Path.Combine(d, "config.json")) ? File.GetLastWriteTimeUtc(Path.Combine(d, "config.json")) : DateTime.MinValue)
                        .FirstOrDefault()
                    : null;
            }
            catch { }
            dataDir = found ?? Path.Combine(RoamingAppData, "Claude");
            dataDirAt = DateTime.UtcNow;
            return dataDir;
        }
    }

    public static string SessionsRoot => Path.Combine(DataDir, "claude-code-sessions");
    public static string PlanUsageFile => Path.Combine(DataDir, "plan-usage-history.json");
    public static string DesktopConfig => Path.Combine(DataDir, "claude_desktop_config.json");

    static string? logPath;
    static DateTime logPathAt;

    /// Claude's main.log: whichever of its possible places Claude wrote to last.
    public static string LogPath
    {
        get
        {
            if (logPath != null && DateTime.UtcNow - logPathAt < TimeSpan.FromSeconds(60)) return logPath;
            var candidates = new[]
            {
                Path.Combine(LocalAppData, "Claude", "logs", "main.log"),
                Path.Combine(DataDir, "logs", "main.log"),
                Path.Combine(RoamingAppData, "Claude", "logs", "main.log"),
            };
            logPath = candidates.Where(File.Exists).OrderByDescending(File.GetLastWriteTimeUtc).FirstOrDefault() ?? candidates[0];
            logPathAt = DateTime.UtcNow;
            return logPath;
        }
    }

    /// The package family ("Claude_pzs8sxrjxfjjc"), from the data folder's name.
    public static string? PackageFamily
    {
        get
        {
            var name = Path.GetFileName(DataDir);
            return name.StartsWith("claude_", StringComparison.OrdinalIgnoreCase) ? "Claude_" + name[7..] : null;
        }
    }

    // MARK: The running app

    public static Process[] Processes()
    {
        try { return Process.GetProcessesByName("claude"); } catch { return Array.Empty<Process>(); }
    }

    /// When Claude started (its first process), or null if it isn't running.
    public static DateTime? LaunchDate()
    {
        DateTime? first = null;
        foreach (var p in Processes())
        {
            try { var t = p.StartTime; if (first == null || t < first) first = t; } catch { }
            p.Dispose();
        }
        return first;
    }

    public static bool Running => LaunchDate() != null;

    /// Claude's main window (the one titled "Claude"), visible or hidden in the tray.
    public static IntPtr MainWindow()
    {
        var pids = new HashSet<uint>(Processes().Select(p => { var id = (uint)p.Id; p.Dispose(); return id; }));
        if (pids.Count == 0) return IntPtr.Zero;
        IntPtr best = IntPtr.Zero;
        var title = new StringBuilder(256);
        Native.EnumWindows((h, _) =>
        {
            Native.GetWindowThreadProcessId(h, out var pid);
            if (!pids.Contains(pid)) return true;
            title.Clear();
            GetWindowText(h, title, title.Capacity);
            if (title.ToString() == "Claude")
            {
                if (best == IntPtr.Zero || Native.IsWindowVisible(h)) best = h;
                if (Native.IsWindowVisible(h)) return false;
            }
            return true;
        }, IntPtr.Zero);
        return best;
    }

    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int max);

    public static bool IsClaudeWindow(IntPtr hWnd)
    {
        if (hWnd == IntPtr.Zero) return false;
        Native.GetWindowThreadProcessId(hWnd, out var pid);
        try { using var p = Process.GetProcessById((int)pid); return p.ProcessName.Equals("claude", StringComparison.OrdinalIgnoreCase); } catch { return false; }
    }

    /// Claude's version ("4.23118.0"), from its install folder (Claude_4.23118.0.0_arm64__…).
    public static string? Version()
    {
        foreach (var p in Processes())
        {
            try
            {
                var path = p.MainModule?.FileName ?? "";
                var m = System.Text.RegularExpressions.Regex.Match(path, @"Claude_(\d+\.\d+\.\d+)(\.\d+)?_");
                if (m.Success) return m.Groups[1].Value;
                var v = p.MainModule?.FileVersionInfo.ProductVersion;
                if (!string.IsNullOrEmpty(v)) return string.Join('.', v.Split('.').Take(3));
            }
            catch { }
            finally { p.Dispose(); }
        }
        return lastVersion;
    }

    static string? lastVersion;
    public static void RememberVersion() { var v = Version(); if (v != null) lastVersion = v; }

    /// The newest Claude Code engine the app has downloaded (DataDir\claude-code\<version>).
    public static string? CodeVersion()
    {
        try
        {
            return Directory.GetDirectories(Path.Combine(DataDir, "claude-code")).Select(Path.GetFileName)
                .Where(n => n != null && n.Split('.').Length == 3 && n.All(c => char.IsDigit(c) || c == '.'))
                .OrderByDescending(n => n!.Split('.').Select(int.Parse).Aggregate(0L, (a, b) => a * 100000 + b)).FirstOrDefault();
        }
        catch { return null; }
    }

    /// Claude's own "Connect new sessions to Remote Control" switch (Settings → Claude Code).
    public static bool? ConnectsNewSessions()
    {
        try
        {
            var o = JsonNode.Parse(File.ReadAllText(DesktopConfig));
            return (bool?)o?["preferences"]?["ccRemoteControlDefaultEnabled"];
        }
        catch { return null; }
    }

    /// Opens a claude:// link (Claude opens or comes forward and shows it).
    public static void Open(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true })?.Dispose(); }
        catch (Exception e) { Log.Write($"Couldn't open {url}: {e.Message}"); }
    }

    /// Starts Claude (through its packaged app id), or brings it forward.
    public static void Launch()
    {
        var family = PackageFamily;
        try
        {
            if (family != null) Process.Start(new ProcessStartInfo("explorer.exe", $"shell:AppsFolder\\{family}!Claude") { UseShellExecute = false })?.Dispose();
            else Open("claude://claude.ai");
        }
        catch (Exception e) { Log.Write("Couldn't start Claude: " + e.Message); }
    }

    // MARK: Sessions (read-only)

    static readonly object cacheLock = new();
    static readonly Dictionary<string, (DateTime modified, long size, Session? session)> cache = new();

    /// Every session file, read only when it changed since the last look.
    public static List<Session> AllSessions()
    {
        var found = new List<Session>();
        var seen = new HashSet<string>();
        try
        {
            if (!Directory.Exists(SessionsRoot)) return found;
            foreach (var account in Directory.GetDirectories(SessionsRoot))
                foreach (var org in Directory.GetDirectories(account))
                    foreach (var file in Directory.GetFiles(org, "local_*.json"))
                    {
                        seen.Add(file);
                        var s = Cached(file);
                        if (s != null) found.Add(s);
                    }
        }
        catch { }
        lock (cacheLock) foreach (var gone in cache.Keys.Where(k => !seen.Contains(k)).ToList()) cache.Remove(gone);
        return found;
    }

    static Session? Cached(string path)
    {
        try
        {
            var info = new FileInfo(path);
            lock (cacheLock)
                if (cache.TryGetValue(path, out var e) && e.modified == info.LastWriteTimeUtc && e.size == info.Length) return e.session;
            var s = ReadSession(path);
            lock (cacheLock) cache[path] = (info.LastWriteTimeUtc, info.Length, s);
            return s;
        }
        catch { return null; }
    }

    static Session? ReadSession(string path)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            if (JsonNode.Parse(stream) is not JsonObject d) return null;
            var id = Json.Str(d["sessionId"]);
            if (id.Length == 0) return null;
            var lastTurn = Json.Double(d["lastTurnEdgeAt"]) ?? Json.Double(d["lastActivityAt"]) ?? 0;
            var title = Json.Str(d["title"]);
            string? remote = null;
            if (d["bridgeSessionIds"] is JsonArray bridges)
                remote = bridges.Select(x => Json.Str(x)).LastOrDefault(IsRemoteId);
            return new Session(id, title.Length == 0 ? "Untitled" : title, Json.Str(d["cwd"]), (bool?)d["isStarred"] == true,
                (bool?)d["isArchived"] == true, lastTurn, Json.Double(d["lastActivityAt"]) ?? lastTurn, (int)(Json.Double(d["completedTurns"]) ?? 0),
                (bool?)d["remoteControlUserEnabled"], remote, Json.Str(d["scheduledTaskId"]).Length > 0);
        }
        catch { return null; }
    }

    /// claude.ai session ids are short and URL-safe; anything else is ignored rather than put in a link.
    static bool IsRemoteId(string id) => id.Length > 0 && id.Length <= 128 && id.All(c => c < 128 && (char.IsLetterOrDigit(c) || c == '_' || c == '-'));

    /// Sessions you can wake: not archived, not a scheduled task's run, and their folder still exists.
    public static List<Session> LiveSessions() =>
        AllSessions().Where(s => !s.Archived && !s.Scheduled && Directory.Exists(s.Cwd)).OrderByDescending(s => s.LastTurn).ToList();

    public static Session? Session(string id) => AllSessions().FirstOrDefault(s => s.Id == id);

    // MARK: Claude's log

    /// A time as Claude's log writes it ("2026-11-05 19:10:07", local time). Those stamps sort as
    /// text, so lines are compared without parsing a date for each one.
    public static string Stamp(DateTime local) => local.ToString("yyyy-MM-dd HH:mm:ss");

    public static DateTime? ParseStamp(string line)
    {
        if (line.Length < 19) return null;
        return DateTime.TryParseExact(line[..19], "yyyy-MM-dd HH:mm:ss", null, System.Globalization.DateTimeStyles.AssumeLocal, out var d) ? d : null;
    }

    /// The last `bytes` of Claude's log as whole lines.
    public static string[] LogTail(long bytes)
    {
        try
        {
            using var f = new FileStream(LogPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var start = Math.Max(0, f.Length - bytes);
            f.Seek(start, SeekOrigin.Begin);
            var buffer = new byte[f.Length - start];
            var read = 0;
            while (read < buffer.Length) { var n = f.Read(buffer, read, buffer.Length - read); if (n <= 0) break; read += n; }
            return Encoding.UTF8.GetString(buffer, 0, read).Split('\n');
        }
        catch { return Array.Empty<string>(); }
    }

    /// Claude's log lines about one session since `start` (from the last 300 KB, so it's quick).
    public static List<string> LogLines(DateTime start, string id)
    {
        var since = Stamp(start.AddSeconds(-1));
        return LogTail(300_000).Where(l => l.Contains(id) && string.CompareOrdinal(Prefix(l), since) >= 0).ToList();
    }

    public static bool LogContains(string text, DateTime start)
    {
        var since = Stamp(start.AddSeconds(-1));
        return LogTail(400_000).Any(l => l.Contains(text) && string.CompareOrdinal(Prefix(l), since) >= 0);
    }

    public static string Prefix(string line) => line.Length >= 19 ? line[..19] : line;

    /// The session Claude's window shows right now ("setFocusedSession: sessionId=X" since it started).
    public static string? ShownSessionId()
    {
        var launch = LaunchDate();
        if (launch == null) return null;
        var since = Stamp(launch.Value.AddSeconds(-1));
        const string marker = "setFocusedSession: sessionId=";
        string? shown = null;
        foreach (var line in LogTail(1_000_000))
        {
            var i = line.IndexOf(marker, StringComparison.Ordinal);
            if (i < 0 || string.CompareOrdinal(Prefix(line), since) < 0) continue;
            var id = line[(i + marker.Length)..].Split(',', ' ', '\r')[0];
            shown = id == "null" ? null : id;
        }
        return shown;
    }

    /// Whether a session is in the middle of a turn, from Claude's log since it started: a turn
    /// begins with "Sending message to session X" (or "Starting local session X" for a session's
    /// first message on Windows) and ends with "Query completed for session X". A start without an
    /// end only counts while the session file shows activity in the last 2 minutes.
    public static bool TurnInProgress(string id)
    {
        var launch = LaunchDate();
        if (launch == null) return false;
        var since = Stamp(launch.Value.AddSeconds(-1));
        var running = false;
        foreach (var line in LogTail(1_000_000))
        {
            if (!line.Contains(id) || string.CompareOrdinal(Prefix(line), since) < 0) continue;
            if (line.Contains($"Query completed for session {id}")) running = false;
            else if (line.Contains($"Sending message to session {id}") || line.Contains($"Starting local session {id}")) running = true;
        }
        var s = running ? Session(id) : null;
        return s != null && Wait.NowMs - s.LastActivity < 120_000;
    }

    /// Waits up to 2 minutes for a session that's replying to finish. False if it's still busy.
    public static bool WaitForTurnToFinish(string id)
    {
        if (!TurnInProgress(id)) return true;
        Log.Write($"Wake {id}: it's in the middle of a turn; waiting for it to finish");
        var deadline = DateTime.UtcNow.AddSeconds(120);
        while (DateTime.UtcNow < deadline)
        {
            Thread.Sleep(3000);
            if (!TurnInProgress(id)) { Log.Write($"Wake {id}: its turn finished"); Thread.Sleep(2000); return true; }
        }
        Log.Write($"Wake {id}: still busy after 2 minutes; nothing typed");
        return false;
    }

    // MARK: Claude's own updates

    /// The update Claude installed when it last started ("[updater] Version changed since last launch: a → b").
    public static (string from, string to)? InstalledUpdate()
    {
        var launch = LaunchDate();
        if (launch == null) return null;
        var since = Stamp(launch.Value.AddSeconds(-5));
        (string, string)? found = null;
        foreach (var line in LogTail(6_000_000))
        {
            const string marker = "[updater] Version changed since last launch: ";
            var i = line.IndexOf(marker, StringComparison.Ordinal);
            if (i < 0 || string.CompareOrdinal(Prefix(line), since) < 0) continue;
            var parts = line[(i + marker.Length)..].Split(" → ");
            if (parts.Length == 2 && parts[0].Trim().Length < 40 && parts[1].Trim().Length < 40) found = (parts[0].Trim(), parts[1].Trim());
        }
        return found;
    }

    /// A Claude update that has downloaded and installs the next time Claude restarts
    /// ("[updater] Update downloaded and ready to install { releaseName: 'Claude 1.2.3' }").
    public static string? UpdateReady()
    {
        var launch = LaunchDate();
        if (launch == null) return null;
        var since = Stamp(launch.Value);
        string? ready = null;
        foreach (var line in LogTail(6_000_000))
        {
            if (!line.Contains("[updater] Update downloaded and ready to install") || string.CompareOrdinal(Prefix(line), since) < 0) continue;
            var i = line.IndexOf("releaseName: '", StringComparison.Ordinal);
            if (i < 0) continue;
            var name = line[(i + 14)..].Split('\'')[0];
            var version = name.Split(' ').Last();
            if (version.Length > 0 && version.Length < 40) ready = version;
        }
        if (ready == null) return null;
        var current = Version();
        return current != null && (ready == current || ready.StartsWith(current + ".") || current.StartsWith(ready + ".")) ? null : ready;
    }
}

/// Whether each session's Remote Control is on right now, from Claude's log since it started:
/// "Enabling/Disabling remote control for session X" (its switch, or /remote-control), and
/// "Remote control enabled" after "Mapping internal session X" (it reconnected after a turn).
/// A session with no log entry is on if it ran a turn since Claude started, and its switch isn't off.
sealed class RemoteControlStatus
{
    public readonly DateTime? Launch;
    readonly Dictionary<string, bool> events;

    RemoteControlStatus(DateTime? launch, Dictionary<string, bool> events) { Launch = launch; this.events = events; }

    public static RemoteControlStatus Now()
    {
        var launch = Claude.LaunchDate();
        return launch == null ? new(null, new()) : new(launch, Reader.Read(launch.Value).events);
    }

    /// Sessions Claude has started since it launched (only those can take /remote-control or the switch).
    public static HashSet<string> StartedSessions()
    {
        var launch = Claude.LaunchDate();
        return launch == null ? new() : Reader.Read(launch.Value).started;
    }

    public bool IsOn(Session s)
    {
        if (Launch == null) return false;
        if (s.UserEnabled == false) return false;
        if (events.TryGetValue(s.Id, out var on)) return on;
        return s.LastTurn / 1000 > new DateTimeOffset(Launch.Value).ToUnixTimeSeconds();
    }

    /// Reads only what Claude added to its log since the last look.
    static class Reader
    {
        static readonly object gate = new();
        static DateTime? launch;
        static string? path;
        static long offset;
        static readonly Dictionary<string, bool> events = new();
        static readonly HashSet<string> started = new();
        static string? recent;
        static string since = "";

        public static (Dictionary<string, bool> events, HashSet<string> started) Read(DateTime at)
        {
            lock (gate)
            {
                try
                {
                    var file = Claude.LogPath;
                    using var f = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                    var size = f.Length;
                    if (launch != at || path != file || size < offset)
                    {
                        launch = at; path = file;
                        offset = Math.Max(0, size - 3_000_000);
                        events.Clear(); started.Clear(); recent = null;
                        since = Claude.Stamp(at.AddSeconds(-1));
                    }
                    f.Seek(offset, SeekOrigin.Begin);
                    var buffer = new byte[size - offset];
                    var read = 0;
                    while (read < buffer.Length) { var n = f.Read(buffer, read, buffer.Length - read); if (n <= 0) break; read += n; }
                    var last = Array.LastIndexOf(buffer, (byte)'\n', Math.Max(0, read - 1));
                    if (last >= 0)
                    {
                        offset += last + 1;
                        foreach (var line in Encoding.UTF8.GetString(buffer, 0, last + 1).Split('\n')) Parse(line);
                    }
                }
                catch { }
                return (new(events), new(started));
            }
        }

        static void Parse(string line)
        {
            if (!line.Contains("emote control") && !line.Contains("Mapping internal session ")) return;
            if (string.CompareOrdinal(Claude.Prefix(line), since) < 0) return;
            string? Id(string marker)
            {
                var i = line.IndexOf(marker, StringComparison.Ordinal);
                return i < 0 ? null : line[(i + marker.Length)..].Split(' ', '\r')[0];
            }
            if (Id("Enabling remote control for session ") is string on) recent = on;
            else if (Id("Disabling remote control for session ") is string off) { events[off] = false; if (recent == off) recent = null; }
            else if (Id("Mapping internal session ") is string mapped) { recent = mapped; started.Add(mapped); }
            else if (line.Contains("Remote control enabled") && recent != null) { events[recent] = true; recent = null; }
        }
    }
}

// MARK: - Plan usage (read-only)

static class Usage
{
    /// The newest plan-usage reading Claude saved ("fh" the 5-hour limit, "sd" weekly across all
    /// models, plus per-model weekly limits), with reset times worked out from its readings. Sent to
    /// the phone as {"at": ms, "limits": {"fh": 7, "sd": 5}, "resets": {"fh": ms, "sd": ms}}.
    public static JsonObject? Plan()
    {
        try
        {
            using var stream = new FileStream(Claude.PlanUsageFile, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            if (JsonNode.Parse(stream)?["samples"] is not JsonArray samples || samples.Count == 0) return null;
            var readings = new List<(double t, Dictionary<string, double> u)>();
            foreach (var s in samples)
            {
                var t = Json.Double(s?["t"]);
                if (t == null || s?["u"] is not JsonObject u) continue;
                var values = new Dictionary<string, double>();
                foreach (var (k, v) in u) if (Json.Double(v) is double d) values[k] = d;
                readings.Add((t.Value, values));
            }
            if (readings.Count == 0 || readings[^1].u.Count == 0) return null;
            var last = readings[^1];
            var resets = EstimateResets(readings, Wait.NowMs, FirstClaudeMessage);
            var limits = new JsonObject();
            foreach (var (k, v) in last.u) limits[k] = v;
            var r = new JsonObject();
            foreach (var (k, v) in resets) r[k] = (long)v;
            return new JsonObject { ["at"] = (long)last.t, ["limits"] = limits, ["resets"] = r };
        }
        catch { return null; }
    }

    /// When the 5-hour and weekly limits reset next (ms since 1970), from Claude's readings. Same
    /// method as the Mac app (see mac/Sessions.swift estimateResets).
    public static Dictionary<string, double> EstimateResets(List<(double t, Dictionary<string, double> u)> readings, double now, Func<double, double?> firstMessage)
    {
        var resets = new Dictionary<string, double>();
        const double hour = 3_600_000, week = 7 * 24 * hour;
        List<(double before, double after, int index)> Drops(string key)
        {
            var output = new List<(double, double, int)>();
            (double t, double v)? prev = null;
            for (var i = 0; i < readings.Count; i++)
            {
                if (!readings[i].u.TryGetValue(key, out var v)) continue;
                if (prev is { } p && v < p.v - 3 && v <= p.v / 2) output.Add((p.t, readings[i].t, i));
                prev = (readings[i].t, v);
            }
            return output;
        }
        var weekly = Drops("sd");
        if (weekly.Count > 0)
        {
            var best = weekly.MinBy(d => d.after - d.before);
            if (best.after - best.before <= 2 * hour)
            {
                var next = (best.before + best.after) / 2;
                while (next <= now) next += week;
                resets["sd"] = next;
            }
        }
        var fiveHour = Drops("fh");
        var latest = readings.LastOrDefault(r => r.u.ContainsKey("fh"));
        if (fiveHour.Count > 0 && latest.u != null && latest.u["fh"] > 0)
        {
            var lastDrop = fiveHour[^1];
            var after = readings.Skip(lastDrop.index).Where(r => r.u.ContainsKey("fh")).ToList();
            var reset = (lastDrop.before + lastDrop.after) / 2;
            double? start = null;
            if (after.Count > 0 && after[0].u["fh"] > 0) start = reset;
            else
            {
                var firstUse = after.FindIndex(r => r.u["fh"] > 0);
                if (firstUse > 0) start = (after[firstUse - 1].t + after[firstUse].t) / 2;
            }
            if (firstMessage(reset) is double sent && sent <= (start ?? double.PositiveInfinity) + 10 * 60_000) start = Math.Max(sent, reset);
            if (start is double s && s + 5 * hour > now) resets["fh"] = s + 5 * hour;
        }
        const double tenMinutes = 600_000;
        return resets.ToDictionary(p => p.Key, p => Math.Round(p.Value / tenMinutes) * tenMinutes);
    }

    /// When the first message after `after` (ms since 1970) was sent in any Claude session here.
    static double? FirstClaudeMessage(double after)
    {
        var since = Claude.Stamp(DateTimeOffset.FromUnixTimeMilliseconds((long)after).LocalDateTime);
        foreach (var line in Claude.LogTail(6_000_000))
        {
            if ((line.Contains("Sending message to session") || line.Contains("Starting local session")) && string.CompareOrdinal(Claude.Prefix(line), since) >= 0)
                return Claude.ParseStamp(line) is DateTime d ? new DateTimeOffset(d).ToUnixTimeMilliseconds() : null;
        }
        return null;
    }
}
