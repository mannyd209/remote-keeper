// Updates from GitHub Releases. Checks every 4 hours for the newest release that has a Windows build
// for this PC (Remote-Keeper-Windows-arm64.exe / -x64.exe), tells your phone (Keeper.SetAvailableUpdate),
// and when you choose Update, downloads it, checks it against the SHA-256 GitHub publishes for that
// file, swaps it in and restarts.

using System.Diagnostics;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json.Nodes;

namespace RemoteKeeper;

sealed record Release(string Version, string Notes, string Download, string? Sha256);

sealed class Updater
{
    public const string Repo = "mannyd209/remote-keeper";
    public static string AssetName => $"Remote-Keeper-Windows-{App.Arch}.exe";
    public Release? Available;
    public Action? OnChange;
    Timer? timer;

    static HttpClient Http()
    {
        var http = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
        http.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("RemoteKeeper", App.Version));
        http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        return http;
    }

    public void Start()
    {
        timer = new Timer(_ => _ = CheckAsync(), null, TimeSpan.FromSeconds(20), TimeSpan.FromHours(4));
    }

    /// Asks GitHub for the newest release with a Windows build.
    public async Task<Release?> CheckAsync()
    {
        Release? found = null;
        try
        {
            using var http = Http();
            var text = await http.GetStringAsync($"https://api.github.com/repos/{Repo}/releases?per_page=15");
            if (JsonNode.Parse(text) is JsonArray releases)
            {
                foreach (var r in releases)
                {
                    if (r == null || (bool?)r["draft"] == true || (bool?)r["prerelease"] == true) continue;
                    var tag = Json.Str(r["tag_name"]);
                    var version = tag.StartsWith('v') ? tag[1..] : tag;
                    var asset = (r["assets"] as JsonArray)?.FirstOrDefault(a => Json.Str(a?["name"]) == AssetName);
                    if (asset == null) continue;
                    var digest = Json.Str(asset["digest"]);
                    if (IsNewer(version, App.Version))
                        found = new Release(version, Json.Str(r["body"]), Json.Str(asset["browser_download_url"]),
                            digest.StartsWith("sha256:") ? digest[7..].ToLowerInvariant() : null);
                    break;   // the newest release with a Windows build
                }
            }
        }
        catch (Exception e) { Log.Write("Update check: " + e.Message); return Available; }
        Available = found;
        OnChange?.Invoke();
        return found;
    }

    /// Checks GitHub, then installs the newest release if it's newer (from the phone's Update).
    public async Task InstallLatestAsync()
    {
        var release = await CheckAsync();
        if (release != null) await InstallAsync(interactive: false);
    }

    /// Downloads, checks and installs the update, then restarts. False if it didn't.
    public async Task<bool> InstallAsync(bool interactive)
    {
        var release = Available;
        if (release == null) return false;
        try
        {
            if (release.Sha256 == null) throw new Exception("GitHub didn't list a checksum for the update.");
            Log.Write($"Downloading Remote Keeper {release.Version}");
            using var http = Http();
            var data = await http.GetByteArrayAsync(release.Download);
            var hash = Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
            if (hash != release.Sha256) throw new Exception("The download doesn't match the checksum on GitHub, so it wasn't installed.");
            Installer.ReplaceAndRestart(data, release.Version);
            return true;
        }
        catch (Exception e)
        {
            Log.Write("Update failed: " + e.Message);
            if (interactive) Tray.Message($"Couldn't update Remote Keeper.\n\n{e.Message}\n\nYou can download it from github.com/{Repo}/releases.", warning: true);
            return false;
        }
    }

    public static bool IsNewer(string version, string other)
    {
        var a = version.Split('.').Select(x => int.TryParse(x, out var n) ? n : 0).ToArray();
        var b = other.Split('.').Select(x => int.TryParse(x, out var n) ? n : 0).ToArray();
        for (var i = 0; i < Math.Max(a.Length, b.Length); i++)
        {
            var x = i < a.Length ? a[i] : 0; var y = i < b.Length ? b[i] : 0;
            if (x != y) return x > y;
        }
        return false;
    }
}
