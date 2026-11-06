// The tray icon and its menu, the setup window (QR code to link a phone), and the popups. Plain
// Win32, so the app stays small. Everything here runs on the main (UI) thread; other threads post
// messages to the tray's hidden window.

using System.Runtime.InteropServices;
using QRCoder;

namespace RemoteKeeper;

sealed class Tray
{
    public static Tray? Current;
    const string ClassName = "RemoteKeeperTray";
    const uint WM_TRAY = Native.WM_APP + 1, WM_SHOW_SETUP = Native.WM_APP + 10, WM_QUIT_APP = Native.WM_APP + 11,
        WM_REFRESH = Native.WM_APP + 12, WM_SETTINGS = Native.WM_APP + 13, WM_UPDATE = Native.WM_APP + 14;

    readonly Keeper keeper = new();
    readonly Updater updater = new();
    readonly Native.WndProc proc;
    IntPtr hWnd, icon;
    uint taskbarCreated;
    SetupWindow? setup;
    bool exiting;

    public Tray() { proc = WndProc; Current = this; }

    public void Run(bool showSetup)
    {
        var instance = Native.GetModuleHandle(null);
        var wc = new Native.WNDCLASSEX
        {
            cbSize = (uint)Marshal.SizeOf<Native.WNDCLASSEX>(), lpfnWndProc = Marshal.GetFunctionPointerForDelegate(proc),
            hInstance = instance, lpszClassName = ClassName,
        };
        Native.RegisterClassEx(ref wc);
        hWnd = Native.CreateWindowEx(Native.WS_EX_TOOLWINDOW, ClassName, "Remote Keeper", Native.WS_OVERLAPPED, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, instance, IntPtr.Zero);
        taskbarCreated = Native.RegisterWindowMessage("TaskbarCreated");
        var small = new IntPtr[1];
        Native.ExtractIconEx(App.ExePath, 0, null, small, 1);
        icon = small[0];
        AddIcon();

        keeper.OnChange = () => Native.PostMessage(hWnd, WM_REFRESH, IntPtr.Zero, IntPtr.Zero);
        keeper.OnNeedsSettings = () => Native.PostMessage(hWnd, WM_SETTINGS, IntPtr.Zero, IntPtr.Zero);
        keeper.OnUpdateRequested = () => _ = updater.InstallLatestAsync();
        updater.OnChange = () => keeper.SetAvailableUpdate(updater.Available?.Version);
        keeper.Start();
        updater.Start();

        if (keeper.Store.Current.SetupDone != true)
        {
            keeper.Store.Update(c => c.SetupDone = true);
            ShowSetup();
        }
        else if (showSetup) ShowSetup();
        else if (Missing().Count > 0) ShowChecklist();

        while (Native.GetMessage(out var msg, IntPtr.Zero, 0, 0) > 0)
        {
            Native.TranslateMessage(ref msg);
            Native.DispatchMessage(ref msg);
        }
        PrepareToExit();
    }

    /// Closed on purpose: no "offline" alert on your phone, and the tray icon goes away.
    public void PrepareToExit()
    {
        if (exiting) return;
        exiting = true;
        keeper.WithdrawWill();
        var data = IconData();
        Native.Shell_NotifyIcon(Native.NIM_DELETE, ref data);
        Log.Write("Remote Keeper quit");
    }

    /// Another copy (an update or a fresh install) asks this one to quit.
    public static void AskRunningCopyToQuit()
    {
        var other = Native.FindWindow(ClassName, null);
        if (other == IntPtr.Zero) return;
        Native.PostMessage(other, WM_QUIT_APP, IntPtr.Zero, IntPtr.Zero);
        Wait.Poll(10, () => Native.FindWindow(ClassName, null) == IntPtr.Zero, 0.2);
        Thread.Sleep(500);
    }

    /// Opening Remote Keeper again (Start menu) shows the running copy's setup window.
    public static bool ShowRunningCopy()
    {
        var other = Native.FindWindow(ClassName, null);
        if (other == IntPtr.Zero) return false;
        Native.AllowSetForegroundWindow(-1);
        Native.PostMessage(other, WM_SHOW_SETUP, IntPtr.Zero, IntPtr.Zero);
        return true;
    }

    public static void Message(string text, bool warning = false) =>
        Native.MessageBox(IntPtr.Zero, text, "Remote Keeper", Native.MB_OK | (warning ? Native.MB_ICONWARNING : Native.MB_ICONINFORMATION) | Native.MB_SETFOREGROUND | Native.MB_TOPMOST);

    static bool Ask(string text, uint icon = Native.MB_ICONQUESTION) =>
        Native.MessageBox(IntPtr.Zero, text, "Remote Keeper", Native.MB_YESNO | icon | Native.MB_SETFOREGROUND | Native.MB_TOPMOST) == Native.IDYES;

    // MARK: Tray icon

    Native.NOTIFYICONDATA IconData() => new()
    {
        cbSize = (uint)Marshal.SizeOf<Native.NOTIFYICONDATA>(), hWnd = hWnd, uID = 1,
        uFlags = Native.NIF_MESSAGE | Native.NIF_ICON | Native.NIF_TIP | Native.NIF_SHOWTIP,
        uCallbackMessage = WM_TRAY, hIcon = icon, szTip = Tooltip(), szInfo = "", szInfoTitle = "",
    };

    string Tooltip()
    {
        var status = !Relay.Configured ? "No relay set up in this build"
            : keeper.RelayConnected ? (keeper.PhoneLinked ? "Phone linked" : "No phone linked yet") : "Connecting…";
        var text = $"Remote Keeper: {status}";
        if (Missing().Count > 0) text += " (a setting needs turning on)";
        return text.Length > 127 ? text[..127] : text;
    }

    void AddIcon()
    {
        var data = IconData();
        Native.Shell_NotifyIcon(Native.NIM_ADD, ref data);
        data.uVersion = 4;
        Native.Shell_NotifyIcon(Native.NIM_SETVERSION, ref data);
    }

    void RefreshIcon()
    {
        var data = IconData();
        Native.Shell_NotifyIcon(Native.NIM_MODIFY, ref data);
        setup?.Refresh(keeper.PhoneLinked);
    }

    // MARK: Menu

    const int CmdChecklist = 10, CmdSetup = 11, CmdWake = 12, CmdUpdate = 13, CmdLogin = 14, CmdUnlink = 15, CmdQuit = 16, CmdLog = 17;

    void ShowMenu()
    {
        var menu = Native.CreatePopupMenu();
        void Item(int id, string text, bool enabled = true, bool check = false) =>
            Native.AppendMenu(menu, Native.MF_STRING | (enabled ? 0 : Native.MF_GRAYED) | (check ? Native.MF_CHECKED : 0), (UIntPtr)id, text);
        void Line() => Native.AppendMenu(menu, Native.MF_SEPARATOR, UIntPtr.Zero, null);

        Item(0, "Remote Keeper", enabled: false);
        Item(0, !Relay.Configured ? "No relay set up in this build"
            : keeper.RelayConnected ? (keeper.PhoneLinked ? "Phone linked" : "No phone linked yet") : "Connecting to the relay…", enabled: false);
        var launch = Claude.LaunchDate();
        Item(0, launch != null ? $"Claude running since {launch.Value:t}" : "Claude isn't running", enabled: false);
        Line();
        var missing = Missing().Count;
        if (missing > 0) Item(CmdChecklist, missing == 1 ? "⚠ Turn On 1 Setting…" : $"⚠ Turn On {missing} Settings…");
        Item(CmdSetup, keeper.PhoneLinked ? "Link Another Phone…" : "Link Your Phone…");
        var offline = keeper.OfflineWatched().Count;
        Item(CmdWake, offline > 0 ? $"Reconnect Offline Sessions ({Math.Min(offline, Keeper.MaxBatch)})" : "Your Sessions Are Connected", enabled: offline > 0);
        Line();
        Item(CmdUpdate, updater.Available != null ? $"Update to {updater.Available.Version}…" : "Check for Updates…");
        Item(CmdLogin, "Open at Login", check: Installer.OpenAtLogin);
        Item(CmdUnlink, "Unlink All Phones…");
        Item(CmdLog, "Show Log");
        Line();
        Item(CmdQuit, "Quit Remote Keeper");

        Native.GetCursorPos(out var pt);
        Native.SetForegroundWindow(hWnd);
        var cmd = Native.TrackPopupMenu(menu, Native.TPM_RETURNCMD | Native.TPM_RIGHTBUTTON | Native.TPM_BOTTOMALIGN, pt.X, pt.Y, 0, hWnd, IntPtr.Zero);
        Native.PostMessage(hWnd, 0, IntPtr.Zero, IntPtr.Zero);
        Native.DestroyMenu(menu);
        switch (cmd)
        {
            case CmdChecklist: ShowChecklist(); break;
            case CmdSetup: ShowSetup(); break;
            case CmdWake: keeper.WakeWatched(); break;
            case CmdUpdate: _ = UpdateFromMenu(); break;
            case CmdLogin:
                var on = !Installer.OpenAtLogin;
                Installer.SetOpenAtLogin(on);
                keeper.Store.Update(c => c.LoginOff = !on);
                break;
            case CmdUnlink:
                if (Ask("Unlink all phones?\n\nEvery phone that scanned the QR code stops working with this PC, and the QR code changes. Scan the new one to link a phone again.", Native.MB_ICONWARNING))
                {
                    keeper.UnlinkAllPhones();
                    ShowSetup();
                }
                break;
            case CmdLog:
                try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("notepad.exe", $"\"{App.LogPath}\"") { UseShellExecute = false })?.Dispose(); } catch { }
                break;
            case CmdQuit: Native.PostQuitMessage(0); break;
        }
    }

    async Task UpdateFromMenu()
    {
        var release = await updater.CheckAsync();
        if (release == null) { Message($"Remote Keeper is up to date.\n\nYou have the latest version, {App.Version}."); return; }
        var notes = release.Notes.Length > 600 ? release.Notes[..600] + "…" : release.Notes;
        if (Ask($"Remote Keeper {release.Version} is available. You have {App.Version}.\n\n{notes}\n\nUpdate now?")) await updater.InstallAsync(interactive: true);
    }

    // MARK: Settings Remote Keeper needs

    static List<(string title, string detail, Action open)> Missing()
    {
        var list = new List<(string, string, Action)>();
        if (Claude.ConnectsNewSessions() != true)
            list.Add(("Connect new sessions to Remote Control",
                "In Claude's Settings → Claude Code, turn on “Connect new sessions to Remote Control”. That's what lets a session reconnect by itself.",
                () => Claude.Open("claude://claude.ai/settings/claude-code")));
        return list;
    }

    void ShowChecklist()
    {
        var missing = Missing();
        if (missing.Count == 0) { Message("Remote Keeper is ready.\n\nEverything it needs is turned on."); return; }
        var item = missing[0];
        if (Ask($"Finish setting up Remote Keeper\n\n{item.title}\n{item.detail}\n\nOpen Claude's settings now?", Native.MB_ICONWARNING)) item.open();
    }

    // MARK: Setup window

    void ShowSetup()
    {
        setup ??= new SetupWindow(keeper.Store.PairingUrl, () => { setup = null; if (Missing().Count > 0) ShowChecklist(); });
        setup.Show(keeper.PhoneLinked);
    }

    // MARK: Messages

    IntPtr WndProc(IntPtr h, uint msg, IntPtr w, IntPtr l)
    {
        if (msg == WM_TRAY)
        {
            var e = (uint)((long)l & 0xFFFF);
            if (e == Native.WM_RBUTTONUP || e == Native.WM_CONTEXTMENU || e == Native.WM_LBUTTONUP) ShowMenu();
            return IntPtr.Zero;
        }
        if (msg == taskbarCreated && taskbarCreated != 0) { AddIcon(); return IntPtr.Zero; }
        switch (msg)
        {
            case WM_SHOW_SETUP: ShowSetup(); return IntPtr.Zero;
            case WM_QUIT_APP: Native.PostQuitMessage(0); return IntPtr.Zero;
            case WM_REFRESH: RefreshIcon(); return IntPtr.Zero;
            case WM_SETTINGS: ShowChecklist(); return IntPtr.Zero;
            case Native.WM_POWERBROADCAST:
                if ((uint)w == Native.PBT_APMSUSPEND) { Log.Write("Going to sleep"); keeper.WillSleep(); }
                else if ((uint)w == Native.PBT_APMRESUMEAUTOMATIC || (uint)w == Native.PBT_APMRESUMESUSPEND) { Log.Write("Woke up"); keeper.DidWake(); }
                return (IntPtr)1;
            case Native.WM_QUERYENDSESSION: return (IntPtr)1;
            case Native.WM_ENDSESSION: if (w != IntPtr.Zero) PrepareToExit(); return IntPtr.Zero;
        }
        return Native.DefWindowProc(h, msg, w, l);
    }
}

/// "Set up Remote Keeper": the QR code your phone scans, painted with GDI.
sealed class SetupWindow
{
    const string ClassName = "RemoteKeeperSetup";
    const int IdCopy = 101, IdDone = 102;
    static bool registered;
    static SetupWindow? active;   // the one window of this class (Windows calls the class's procedure)
    static readonly Native.WndProc proc = (h, m, w, l) => active?.WndProc(h, m, w, l) ?? Native.DefWindowProc(h, m, w, l);
    readonly string url;
    readonly Action closed;
    readonly bool[,] qr;
    IntPtr hWnd, copyButton, doneButton, fontTitle, fontBody, fontBold, fontSmall, white;
    bool linked, copied;
    double scale = 1;

    public SetupWindow(string url, Action closed)
    {
        this.url = url;
        this.closed = closed;
        var data = new QRCodeGenerator().CreateQrCode(url, QRCodeGenerator.ECCLevel.M);
        var n = data.ModuleMatrix.Count;
        qr = new bool[n, n];
        for (var y = 0; y < n; y++) for (var x = 0; x < n; x++) qr[x, y] = data.ModuleMatrix[y][x];
    }

    int S(double v) => (int)Math.Round(v * scale);

    public void Show(bool phoneLinked)
    {
        linked = phoneLinked;
        if (hWnd == IntPtr.Zero) Create();
        Native.ShowWindow(hWnd, Native.SW_SHOWNORMAL);
        Native.AllowSetForegroundWindow(-1);
        Native.SetForegroundWindow(hWnd);
        Native.InvalidateRect(hWnd, IntPtr.Zero, true);
    }

    public void Refresh(bool phoneLinked)
    {
        if (hWnd == IntPtr.Zero || linked == phoneLinked) return;
        linked = phoneLinked;
        Native.SetWindowText(doneButton, linked ? "Done" : "Finish Later");
        Native.InvalidateRect(hWnd, IntPtr.Zero, true);
    }

    void Create()
    {
        active = this;
        var instance = Native.GetModuleHandle(null);
        if (!registered)
        {
            var small = new IntPtr[1]; var large = new IntPtr[1];
            Native.ExtractIconEx(App.ExePath, 0, large, small, 1);
            var wc = new Native.WNDCLASSEX
            {
                cbSize = (uint)Marshal.SizeOf<Native.WNDCLASSEX>(), lpfnWndProc = Marshal.GetFunctionPointerForDelegate(proc),
                hInstance = instance, lpszClassName = ClassName, hCursor = Native.LoadCursor(IntPtr.Zero, (IntPtr)32512),
                hIcon = large[0], hIconSm = small[0],
            };
            Native.RegisterClassEx(ref wc);
            registered = true;
        }
        scale = Native.GetDpiForSystem() / 96.0;
        var w = S(560); var h = S(600);
        var x = (Native.GetSystemMetrics(0) - w) / 2; var y = (Native.GetSystemMetrics(1) - h) / 2;
        hWnd = Native.CreateWindowEx(0, ClassName, "Remote Keeper", Native.WS_OVERLAPPED | Native.WS_CAPTION | Native.WS_SYSMENU | Native.WS_MINIMIZEBOX,
            x, y, w, h, IntPtr.Zero, IntPtr.Zero, instance, IntPtr.Zero);
        scale = Native.GetDpiForWindow(hWnd) / 96.0;
        white = Native.CreateSolidBrush(Native.RGB(255, 255, 255));
        copyButton = Native.CreateWindowEx(0, "BUTTON", "Copy Link", Native.WS_CHILD | Native.WS_VISIBLE | Native.WS_TABSTOP | Native.BS_PUSHBUTTON, 0, 0, 0, 0, hWnd, (IntPtr)IdCopy, instance, IntPtr.Zero);
        doneButton = Native.CreateWindowEx(0, "BUTTON", linked ? "Done" : "Finish Later", Native.WS_CHILD | Native.WS_VISIBLE | Native.WS_TABSTOP | Native.BS_DEFPUSHBUTTON, 0, 0, 0, 0, hWnd, (IntPtr)IdDone, instance, IntPtr.Zero);
        Layout();
    }

    void MakeFonts()
    {
        foreach (var f in new[] { fontTitle, fontBody, fontBold, fontSmall }) if (f != IntPtr.Zero) Native.DeleteObject(f);
        IntPtr Font(double size, int weight) => Native.CreateFont(-S(size), 0, 0, 0, weight, 0, 0, 0, 1, 0, 0, 5, 0, "Segoe UI");
        fontTitle = Font(22, 700); fontBody = Font(13, 400); fontBold = Font(14, 600); fontSmall = Font(11.5, 400);
    }

    void Layout()
    {
        MakeFonts();
        Native.GetClientRect(hWnd, out var rc);
        foreach (var b in new[] { copyButton, doneButton }) Native.SendMessage(b, Native.WM_SETFONT, fontBody, (IntPtr)1);
        Native.SetWindowPos(copyButton, IntPtr.Zero, S(272), S(330), S(110), S(30), 0x0004);
        Native.SetWindowPos(doneButton, IntPtr.Zero, rc.Right - S(24) - S(130), rc.Bottom - S(24) - S(32), S(130), S(32), 0x0004);
    }

    void Paint()
    {
        var hdc = Native.BeginPaint(hWnd, out var ps);
        Native.GetClientRect(hWnd, out var rc);
        Native.FillRect(hdc, ref rc, white);
        Native.SetBkMode(hdc, Native.TRANSPARENT);
        void Text(string text, IntPtr font, int left, int top, int width, int height, uint color, uint flags = Native.DT_WORDBREAK | Native.DT_NOPREFIX)
        {
            Native.SelectObject(hdc, font);
            Native.SetTextColor(hdc, color);
            var r = new Native.RECT { Left = left, Top = top, Right = left + width, Bottom = top + height };
            Native.DrawText(hdc, text, -1, ref r, flags);
        }
        uint dark = Native.RGB(20, 20, 24), gray = Native.RGB(96, 96, 104), green = Native.RGB(22, 140, 60);
        var pad = S(24);
        var width = rc.Right - 2 * pad;
        Text("Set up Remote Keeper", fontTitle, pad, S(20), width, S(34), dark);
        Text("Reconnect your Claude Code sessions' Remote Control from your phone.", fontBody, pad, S(58), width, S(40), gray);
        Text(linked ? "✓  Your phone is linked" : "1.  Scan with your phone's camera", fontBold, pad, S(100), width, S(24), linked ? green : dark);

        if (!Relay.Configured)
        {
            Text($"This build has no relay set up. Download Remote Keeper from github.com/{Updater.Repo}/releases, or run your own relay and set REMOTE_KEEPER_HOST and REMOTE_KEEPER_APP_KEY.",
                fontBody, pad, S(136), width, S(80), gray);
        }
        else
        {
            // The QR code, with its quiet zone, in a 224×224 square.
            var n = qr.GetLength(0);
            var box = S(224);
            var cell = Math.Max(1, box / n);
            var size = cell * n;
            var left = pad; var top = S(136);
            var black = Native.CreateSolidBrush(Native.RGB(0, 0, 0));
            for (var y = 0; y < n; y++)
                for (var x = 0; x < n; x++)
                    if (qr[x, y])
                    {
                        var r = new Native.RECT { Left = left + x * cell, Top = top + y * cell, Right = left + (x + 1) * cell, Bottom = top + (y + 1) * cell };
                        Native.FillRect(hdc, ref r, black);
                    }
            Native.DeleteObject(black);
            var textLeft = left + size + S(20);
            var textWidth = rc.Right - pad - textLeft;
            Text(linked ? "Your phone is linked." : "Waiting for your phone…", fontBold, textLeft, top, textWidth, S(24), linked ? green : dark);
            Text("Open the Remote Keeper app on your iPhone and tap ＋, or scan with the Camera to use the web app.", fontBody, textLeft, top + S(30), textWidth, S(80), gray);
            Text("Anyone with this code can reconnect your sessions, so keep it to yourself.", fontSmall, textLeft, top + S(110), textWidth, S(50), gray);
            if (copied) Text("Copied", fontSmall, textLeft + S(120), S(337), S(80), S(20), green);
        }

        Text("2.  In the Claude app", fontBold, pad, S(390), width, S(24), dark);
        Text("Keep Settings → Claude Code → “Connect new sessions to Remote Control” on, so sessions reconnect by themselves after a restart. "
            + "Remote Keeper turns Remote Control back on from your phone when they don't.", fontBody, pad, S(418), width, S(70), gray);
        Text("Remote Keeper lives in the tray (bottom right, near the clock).", fontSmall, pad, S(496), width, S(20), gray);
        Native.EndPaint(hWnd, ref ps);
    }

    void CopyLink()
    {
        if (!Native.OpenClipboard(hWnd)) return;
        Native.EmptyClipboard();
        var bytes = (url.Length + 1) * 2;
        var mem = Native.GlobalAlloc(0x0002, (UIntPtr)bytes);   // GMEM_MOVEABLE
        var ptr = Native.GlobalLock(mem);
        Marshal.Copy((url + "\0").ToCharArray(), 0, ptr, url.Length + 1);
        Native.GlobalUnlock(mem);
        Native.SetClipboardData(13, mem);   // CF_UNICODETEXT
        Native.CloseClipboard();
        copied = true;
        Native.InvalidateRect(hWnd, IntPtr.Zero, true);
    }

    IntPtr WndProc(IntPtr h, uint msg, IntPtr w, IntPtr l)
    {
        switch (msg)
        {
            case Native.WM_PAINT: Paint(); return IntPtr.Zero;
            case Native.WM_ERASEBKGND: return (IntPtr)1;
            case Native.WM_COMMAND:
                var id = (int)((long)w & 0xFFFF);
                if (id == IdCopy) CopyLink();
                if (id == IdDone) Native.DestroyWindow(h);
                return IntPtr.Zero;
            case Native.WM_DPICHANGED:
                scale = ((int)((long)w & 0xFFFF)) / 96.0;
                var r = Marshal.PtrToStructure<Native.RECT>(l);
                Native.SetWindowPos(h, IntPtr.Zero, r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top, 0x0004);
                Layout();
                Native.InvalidateRect(h, IntPtr.Zero, true);
                return IntPtr.Zero;
            case Native.WM_CLOSE: Native.DestroyWindow(h); return IntPtr.Zero;
            case Native.WM_DESTROY:
                foreach (var f in new[] { fontTitle, fontBody, fontBold, fontSmall, white }) if (f != IntPtr.Zero) Native.DeleteObject(f);
                hWnd = IntPtr.Zero;
                if (active == this) active = null;
                closed();
                return IntPtr.Zero;
        }
        return Native.DefWindowProc(h, msg, w, l);
    }
}
