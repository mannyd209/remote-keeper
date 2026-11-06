// Shared plumbing: where things live, the log, the settings file, small work queues, and polling.

using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

namespace RemoteKeeper;

static class App
{
    public const string Version = "0.4.0";   // one version line with the Mac app (the iPhone app enables features by version)
    public static readonly string SupportDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Remote Keeper");
    public static readonly string InstallDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Remote Keeper");
    public static readonly string InstalledExe = Path.Combine(InstallDir, "RemoteKeeper.exe");
    public static string ExePath => Environment.ProcessPath ?? InstalledExe;
    public static readonly string ConfigPath = Environment.GetEnvironmentVariable("REMOTE_KEEPER_CONFIG") ?? Path.Combine(SupportDir, "config.json");
    public static readonly string LogPath = Path.Combine(SupportDir, "Remote Keeper.log");

    /// This PC's name as you named it ("Mannys-PC"), not the upper-case NetBIOS name.
    public static string ComputerName
    {
        get
        {
            try { var n = System.Net.Dns.GetHostName(); if (!string.IsNullOrWhiteSpace(n)) return n; } catch { }
            return Environment.MachineName;
        }
    }

    public static string Arch => System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture == System.Runtime.InteropServices.Architecture.Arm64 ? "arm64" : "x64";
}

static class Log
{
    static readonly object Lock = new();

    public static void Write(string message)
    {
        var line = $"{DateTime.Now:yyyy-MM-ddTHH:mm:ss} {message}";
        lock (Lock)
        {
            try
            {
                Directory.CreateDirectory(App.SupportDir);
                var info = new FileInfo(App.LogPath);
                if (info.Exists && info.Length > 5_000_000)
                {
                    File.Copy(App.LogPath, App.LogPath + ".1", true);
                    File.WriteAllText(App.LogPath, "");
                }
                File.AppendAllText(App.LogPath, line + "\n");
            }
            catch { }
        }
        if (Program.Console) System.Console.Error.WriteLine(line);
    }
}

/// The settings file (%LOCALAPPDATA%\Remote Keeper\config.json). Same fields as the Mac's.
sealed class Config
{
    public string? Secret;           // base64url, 32 bytes; shown only inside the QR code
    public List<string>? Watched;
    public double? PhoneSeenAt;      // last message from a linked phone
    public bool? SetupDone;
    public string? NotifiedUpdate;   // the newest release we already sent a notification about
    public bool? LoginOff;           // you turned off Open at Login
    public List<string>? Known;      // sessions your phone has already been told about
    public bool? AlertNew;           // also send a notification for a new session
    public string? ClaudeUpdateAlerted;
    public double? RestartedClaudeAt;

    public JsonObject ToJson()
    {
        var o = new JsonObject();
        if (Secret != null) o["secret"] = Secret;
        if (Watched != null) o["watched"] = new JsonArray(Watched.Select(x => (JsonNode)x!).ToArray());
        if (PhoneSeenAt != null) o["phoneSeenAt"] = PhoneSeenAt;
        if (SetupDone != null) o["setupDone"] = SetupDone;
        if (NotifiedUpdate != null) o["notifiedUpdate"] = NotifiedUpdate;
        if (LoginOff != null) o["loginOff"] = LoginOff;
        if (Known != null) o["known"] = new JsonArray(Known.Select(x => (JsonNode)x!).ToArray());
        if (AlertNew != null) o["alertNew"] = AlertNew;
        if (ClaudeUpdateAlerted != null) o["claudeUpdateAlerted"] = ClaudeUpdateAlerted;
        if (RestartedClaudeAt != null) o["restartedClaudeAt"] = RestartedClaudeAt;
        return o;
    }

    public static Config FromJson(JsonObject? o)
    {
        var c = new Config();
        if (o == null) return c;
        c.Secret = (string?)o["secret"];
        c.Watched = o["watched"]?.AsArray().Select(x => (string?)x).OfType<string>().ToList();
        c.PhoneSeenAt = Json.Double(o["phoneSeenAt"]);
        c.SetupDone = (bool?)o["setupDone"];
        c.NotifiedUpdate = (string?)o["notifiedUpdate"];
        c.LoginOff = (bool?)o["loginOff"];
        c.Known = o["known"]?.AsArray().Select(x => (string?)x).OfType<string>().ToList();
        c.AlertNew = (bool?)o["alertNew"];
        c.ClaudeUpdateAlerted = (string?)o["claudeUpdateAlerted"];
        c.RestartedClaudeAt = Json.Double(o["restartedClaudeAt"]);
        return c;
    }

    public Config Copy() => FromJson(ToJson());
}

sealed class Store
{
    readonly object gate = new();
    Config config;

    public Store()
    {
        config = Load() ?? new Config();
        if (Base64Url.Decode(config.Secret ?? "")?.Length != 32) config.Secret = NewSecret();
        Save();
    }

    public static Config? Load()
    {
        try { return Config.FromJson(JsonNode.Parse(File.ReadAllText(App.ConfigPath)) as JsonObject); } catch { return null; }
    }

    public static string NewSecret() => Base64Url.Encode(RandomNumberGenerator.GetBytes(32));

    public Config Current { get { lock (gate) return config.Copy(); } }

    public void Update(Action<Config> change)
    {
        lock (gate) { change(config); Save(); }
    }

    void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(App.ConfigPath)!);
            var tmp = App.ConfigPath + ".tmp";
            File.WriteAllText(tmp, config.ToJson().ToJsonString());
            File.Move(tmp, App.ConfigPath, true);
        }
        catch (Exception e) { Log.Write("Couldn't save settings: " + e.Message); }
    }

    public byte[] SecretData => Base64Url.Decode(Current.Secret ?? "") ?? Array.Empty<byte>();
    public List<string> Watched => Current.Watched ?? new();
    public string PairingUrl => $"https://{(Relay.IsLocal ? "localhost:8787" : Relay.Host)}/#k={Current.Secret}";
}

static class Base64Url
{
    public static string Encode(byte[] data) => Convert.ToBase64String(data).Replace('+', '-').Replace('/', '_').TrimEnd('=');

    public static byte[]? Decode(string text)
    {
        try
        {
            var s = text.Replace('-', '+').Replace('_', '/');
            s += new string('=', (4 - s.Length % 4) % 4);
            return Convert.FromBase64String(s);
        }
        catch { return null; }
    }
}

static class Json
{
    public static double? Double(JsonNode? n)
    {
        if (n is not JsonValue v) return null;
        if (v.TryGetValue<double>(out var d)) return d;
        if (v.TryGetValue<long>(out var l)) return l;
        if (v.TryGetValue<int>(out var i)) return i;
        return null;
    }

    public static string Str(JsonNode? n) => n is JsonValue v && v.TryGetValue<string>(out var s) ? s : "";

    public static JsonArray Strings(IEnumerable<string> items) => new(items.Select(x => (JsonNode)x!).ToArray());
}

/// One background thread that runs jobs in order (like a serial dispatch queue on the Mac).
sealed class SerialQueue
{
    readonly BlockingCollection<Action> jobs = new();

    public SerialQueue(string name)
    {
        var t = new Thread(() =>
        {
            foreach (var job in jobs.GetConsumingEnumerable())
            {
                try { job(); } catch (Exception e) { Log.Write($"{name}: {e}"); }
            }
        }) { IsBackground = true, Name = name };
        t.SetApartmentState(ApartmentState.MTA);
        t.Start();
    }

    public void Run(Action job) => jobs.Add(job);

    public void After(TimeSpan delay, Action job) => _ = Task.Delay(delay).ContinueWith(_ => Run(job));

    /// Runs a job and waits for it (never call from the queue itself).
    public T Sync<T>(Func<T> job)
    {
        T result = default!;
        using var done = new ManualResetEventSlim();
        Run(() => { try { result = job(); } finally { done.Set(); } });
        done.Wait();
        return result;
    }
}

static class Wait
{
    /// Runs `check` every `every` seconds until it's true or `seconds` pass.
    public static bool Poll(double seconds, Func<bool> check, double every = 0.2)
    {
        var deadline = DateTime.UtcNow.AddSeconds(seconds);
        do
        {
            if (check()) return true;
            Thread.Sleep(TimeSpan.FromSeconds(every));
        } while (DateTime.UtcNow < deadline);
        return check();
    }

    public static double NowMs => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
}
