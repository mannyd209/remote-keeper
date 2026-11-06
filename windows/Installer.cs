// Installing for you only (no administrator): the app copies itself to
// %LOCALAPPDATA%\Programs\Remote Keeper, opens at login (HKCU\...\Run), has a Start menu shortcut,
// and shows in Settings → Apps with an Uninstall button. Also swaps in updates.

using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace RemoteKeeper;

static class Installer
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\RemoteKeeper";
    const string RunName = "Remote Keeper";
    static readonly string StartMenuLink = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "Remote Keeper.lnk");

    public static bool RunningInstalled => string.Equals(Path.GetFullPath(App.ExePath), Path.GetFullPath(App.InstalledExe), StringComparison.OrdinalIgnoreCase);

    /// Run from anywhere else (Downloads): copies itself into place, sets it up, starts the installed
    /// copy and returns true (this copy then exits).
    public static bool InstallIfNeeded()
    {
        if (RunningInstalled) return false;
        try
        {
            Tray.AskRunningCopyToQuit();
            Directory.CreateDirectory(App.InstallDir);
            var copied = false;
            for (var i = 0; i < 20 && !copied; i++)
            {
                try { File.Copy(App.ExePath, App.InstalledExe, true); copied = true; }
                catch (IOException) { Thread.Sleep(500); }
            }
            if (!copied) throw new IOException("Remote Keeper is still running and couldn't be replaced.");
            Register();
            Log.Write($"Installed {App.Version} to {App.InstallDir}");
            Process.Start(new ProcessStartInfo(App.InstalledExe, "--setup") { UseShellExecute = false })?.Dispose();
            return true;
        }
        catch (Exception e)
        {
            Log.Write("Install failed: " + e.Message);
            Tray.Message($"Remote Keeper couldn't install itself.\n\n{e.Message}\n\nIt will run from where it is for now.", warning: true);
            return false;
        }
    }

    /// Open at login, the Start menu shortcut and the Apps entry, pointing at the installed copy.
    public static void Register()
    {
        if (Store.Load()?.LoginOff != true) SetOpenAtLogin(true);
        try
        {
            using var k = Registry.CurrentUser.CreateSubKey(UninstallKey);
            k.SetValue("DisplayName", "Remote Keeper");
            k.SetValue("DisplayVersion", App.Version);
            k.SetValue("Publisher", "MannyD Labs");
            k.SetValue("DisplayIcon", App.InstalledExe);
            k.SetValue("InstallLocation", App.InstallDir);
            k.SetValue("UninstallString", $"\"{App.InstalledExe}\" --uninstall");
            k.SetValue("URLInfoAbout", "https://mannydlabs.com/remote-keeper");
            k.SetValue("HelpLink", $"https://github.com/{Updater.Repo}");
            k.SetValue("NoModify", 1, RegistryValueKind.DWord);
            k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            k.SetValue("EstimatedSize", (int)(new FileInfo(App.InstalledExe).Length / 1024), RegistryValueKind.DWord);
        }
        catch (Exception e) { Log.Write("Apps entry: " + e.Message); }
        try { Shortcut.Create(StartMenuLink, App.InstalledExe, "--setup", "Reconnect Claude Code sessions from your phone"); }
        catch (Exception e) { Log.Write("Start menu shortcut: " + e.Message); }
    }

    public static bool OpenAtLogin
    {
        get { try { using var k = Registry.CurrentUser.OpenSubKey(RunKey); return k?.GetValue(RunName) != null; } catch { return false; } }
    }

    public static void SetOpenAtLogin(bool on)
    {
        try
        {
            using var k = Registry.CurrentUser.CreateSubKey(RunKey);
            if (on) k.SetValue(RunName, $"\"{(RunningInstalled || File.Exists(App.InstalledExe) ? App.InstalledExe : App.ExePath)}\" --background");
            else k.DeleteValue(RunName, false);
        }
        catch (Exception e) { Log.Write("Open at login: " + e.Message); }
    }

    /// Settings → Apps → Uninstall (or RemoteKeeper.exe --uninstall).
    public static void Uninstall()
    {
        if (Native.MessageBox(IntPtr.Zero, "Uninstall Remote Keeper?\n\nIt stops watching your Claude Code sessions, and your phone can't reconnect them on this PC anymore.",
                "Remote Keeper", Native.MB_YESNO | Native.MB_ICONQUESTION | Native.MB_SETFOREGROUND | Native.MB_TOPMOST) != Native.IDYES) return;
        Tray.AskRunningCopyToQuit();
        SetOpenAtLogin(false);
        try { Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, false); } catch { }
        try { File.Delete(StartMenuLink); } catch { }
        try { if (Directory.Exists(App.SupportDir)) Directory.Delete(App.SupportDir, true); } catch { }
        // This copy is running from the install folder, so a helper removes it after we exit.
        var script = $"/c ping -n 3 127.0.0.1 >nul & rmdir /s /q \"{App.InstallDir}\"";
        Process.Start(new ProcessStartInfo("cmd.exe", script) { CreateNoWindow = true, UseShellExecute = false, WindowStyle = ProcessWindowStyle.Hidden })?.Dispose();
        Native.MessageBox(IntPtr.Zero, "Remote Keeper was removed from this PC.", "Remote Keeper", Native.MB_OK | Native.MB_ICONINFORMATION | Native.MB_SETFOREGROUND);
    }

    /// Swaps in a downloaded update and starts it. A running .exe can be renamed but not overwritten,
    /// so this one moves aside and the new one takes its place.
    public static void ReplaceAndRestart(byte[] data, string version)
    {
        var exe = App.ExePath;
        var dir = Path.GetDirectoryName(exe)!;
        var fresh = Path.Combine(dir, "RemoteKeeper.new.exe");
        var old = Path.Combine(dir, "RemoteKeeper.old.exe");
        File.WriteAllBytes(fresh, data);
        try { File.Delete(old); } catch { }
        File.Move(exe, old);
        try { File.Move(fresh, exe); }
        catch { File.Move(old, exe); throw; }
        Log.Write($"Updated to {version}; restarting");
        Tray.Current?.PrepareToExit();
        Process.Start(new ProcessStartInfo(exe, "--updated") { UseShellExecute = false })?.Dispose();
        Environment.Exit(0);
    }

    /// Leftovers from an update.
    public static void CleanUp()
    {
        try { File.Delete(Path.Combine(Path.GetDirectoryName(App.ExePath)!, "RemoteKeeper.old.exe")); } catch { }
        if (RunningInstalled)
        {
            // Keep the Apps entry's version current after an update.
            try { using var k = Registry.CurrentUser.OpenSubKey(UninstallKey, true); k?.SetValue("DisplayVersion", App.Version); } catch { }
        }
    }
}

/// A Start menu shortcut, through the shell's own IShellLink.
static class Shortcut
{
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")] class ShellLink { }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
    interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder file, int max, IntPtr data, uint flags);
        void GetIDList(out IntPtr list);
        void SetIDList(IntPtr list);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder name, int max);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder dir, int max);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string dir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder args, int max);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
        void GetHotkey(out short key);
        void SetHotkey(short key);
        void GetShowCmd(out int cmd);
        void SetShowCmd(int cmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder path, int max, out int index);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int index);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
        void Resolve(IntPtr hwnd, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string file);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("0000010b-0000-0000-C000-000000000046")]
    interface IPersistFile
    {
        void GetClassID(out Guid id);
        [PreserveSig] int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string file, uint mode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string file, [MarshalAs(UnmanagedType.Bool)] bool remember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string file);
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string file);
    }

    public static void Create(string link, string target, string args, string description)
    {
        var shell = (IShellLinkW)new ShellLink();
        shell.SetPath(target);
        shell.SetArguments(args);
        shell.SetDescription(description);
        shell.SetWorkingDirectory(Path.GetDirectoryName(target)!);
        shell.SetIconLocation(target, 0);
        Directory.CreateDirectory(Path.GetDirectoryName(link)!);
        ((IPersistFile)shell).Save(link, true);
        Marshal.ReleaseComObject(shell);
    }
}
