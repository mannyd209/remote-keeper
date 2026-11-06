// Working Claude's window: Windows UI Automation (the Remote Control switch and the message box),
// bringing Claude to the front, and typing into it. Typing only ever goes to Claude: every key is
// sent only while Claude's window is the one in front.
//
// Claude is a Chromium app, which builds its accessibility tree only when something asks for it.
// Asking through the old MSAA interface and listening for focus changes (what screen readers do)
// turns it on; it fills in once Claude's window is shown.

using System.Runtime.InteropServices;
using Interop.UIAutomationClient;

namespace RemoteKeeper;

static class Automation
{
    const int ButtonType = 50000, EditType = 50004;
    const int TogglePattern = 10015, ValuePattern = 10002;

    [ThreadStatic] static CUIAutomation8? uia;
    static CUIAutomation8 Uia => uia ??= new CUIAutomation8();

    static readonly object focusGate = new();
    static bool focusHandlerAdded;

    sealed class FocusListener : IUIAutomationFocusChangedEventHandler
    {
        public void HandleFocusChangedEvent(IUIAutomationElement sender) { }
    }

    /// Makes Claude's window build its accessibility tree.
    public static void EnableAccessibility(IntPtr hWnd)
    {
        if (hWnd == IntPtr.Zero) return;
        try
        {
            var iid = new Guid("618736e0-3c3d-11cf-810c-00aa00389b71");   // IAccessible
            Native.AccessibleObjectFromWindow(hWnd, 0xFFFFFFFC, ref iid, out _);   // OBJID_CLIENT
        }
        catch { }
        lock (focusGate)
        {
            if (focusHandlerAdded) return;
            try { Uia.AddFocusChangedEventHandler(null, new FocusListener()); focusHandlerAdded = true; } catch (Exception e) { Log.Write("Focus listener: " + e.Message); }
        }
    }

    /// Walks Claude's window (the raw tree, which reaches into its web pages) and returns the first
    /// element `match` accepts, or all of them with `all`.
    static List<IUIAutomationElement> Find(IntPtr hWnd, Func<IUIAutomationElement, bool> match, bool all = false, int limit = 8000)
    {
        var found = new List<IUIAutomationElement>();
        if (hWnd == IntPtr.Zero) return found;
        try
        {
            var walker = Uia.RawViewWalker;
            var root = Uia.ElementFromHandle(hWnd);
            var stack = new Stack<IUIAutomationElement>();
            stack.Push(root);
            var count = 0;
            while (stack.Count > 0 && count < limit)
            {
                var e = stack.Pop();
                var children = new List<IUIAutomationElement>();
                IUIAutomationElement? c = null;
                try { c = walker.GetFirstChildElement(e); } catch { }
                while (c != null)
                {
                    count++;
                    bool ok = false;
                    try { ok = match(c); } catch { }
                    if (ok) { found.Add(c); if (!all) return found; }
                    children.Add(c);
                    try { c = walker.GetNextSiblingElement(c); } catch { c = null; }
                }
                for (var i = children.Count - 1; i >= 0; i--) stack.Push(children[i]);
            }
        }
        catch (COMException e) { Log.Write("Automation: " + e.Message); }
        return found;
    }

    /// How many elements Claude's window shows, up to 400 (a full tree is hundreds; the frame alone is about 14).
    static int CountElements(IntPtr hWnd)
    {
        var n = 0;
        Find(hWnd, _ => { n++; return false; }, limit: 400);
        return n;
    }

    /// Waits up to `seconds` for Claude's window to show its page in the accessibility tree.
    public static bool WaitForTree(IntPtr hWnd, double seconds)
    {
        EnableAccessibility(hWnd);
        return Wait.Poll(seconds, () => CountElements(hWnd) > 60, 0.5);
    }

    // MARK: The Remote Control switch

    /// The open session's Remote Control switch (Claude 4.23 and later, in the session panel on the right).
    public static IUIAutomationElement? RemoteControlSwitch(IntPtr hWnd) =>
        Find(hWnd, e => e.CurrentName == "Remote Control" && e.CurrentControlType == ButtonType && e.GetCurrentPattern(TogglePattern) != null).FirstOrDefault();

    /// On, off, or null when unknown.
    public static bool? SwitchIsOn(IUIAutomationElement toggle)
    {
        try { return ((IUIAutomationTogglePattern)toggle.GetCurrentPattern(TogglePattern)).CurrentToggleState == ToggleState.ToggleState_On; }
        catch { return null; }
    }

    public static bool PressSwitch(IUIAutomationElement toggle)
    {
        try { ((IUIAutomationTogglePattern)toggle.GetCurrentPattern(TogglePattern)).Toggle(); return true; }
        catch (Exception e) { Log.Write("Couldn't press the switch: " + e.Message); return false; }
    }

    // MARK: Claude's usage popup

    const int ProgressBarType = 50012, TextType = 50020, RangeValuePattern = 10003, ExpandCollapsePattern = 10005;

    /// Opens the usage button under Claude's message box ("Usage: Weekly · all models: 22%, …"),
    /// reads each limit (name, percent used, "Resets at 10:40 PM"), and closes it again.
    /// Null when there's no usage button (no session or new-session page shown).
    public static List<(string label, double percent, string? reset)>? ReadUsagePopup(IntPtr hWnd)
    {
        var button = Find(hWnd, e => e.CurrentControlType == ButtonType && (e.CurrentName ?? "").StartsWith("Usage:")).FirstOrDefault();
        if (button == null || button.GetCurrentPattern(ExpandCollapsePattern) is not IUIAutomationExpandCollapsePattern expander) return null;
        var opened = false;
        try
        {
            if (expander.CurrentExpandCollapseState != ExpandCollapseState.ExpandCollapseState_Expanded) { expander.Expand(); opened = true; }
            List<IUIAutomationElement> bars = new();
            Wait.Poll(3, () => (bars = Find(hWnd, e => e.CurrentControlType == ProgressBarType && !string.IsNullOrEmpty(e.CurrentName), all: true)).Count > 0, 0.2);
            if (bars.Count == 0) return null;
            var texts = Find(hWnd, e => e.CurrentControlType == TextType && !string.IsNullOrEmpty(e.CurrentName), all: true)
                .Select(e => (name: e.CurrentName.Trim(), rect: e.CurrentBoundingRectangle)).ToList();
            var rows = new List<(string, double, string?)>();
            foreach (var bar in bars)
            {
                var label = bar.CurrentName.Trim();
                double percent;
                try
                {
                    var range = (IUIAutomationRangeValuePattern)bar.GetCurrentPattern(RangeValuePattern);
                    percent = range.CurrentMaximum > 0 ? range.CurrentValue / range.CurrentMaximum * 100 : range.CurrentValue;
                }
                catch { continue; }
                // The reset text sits on the label's row, above the bar.
                var labelRow = texts.FirstOrDefault(t => t.name == label);
                var reset = labelRow.name == null ? null
                    : texts.Where(t => t.name.StartsWith("Resets", StringComparison.OrdinalIgnoreCase) && Math.Abs(t.rect.top - labelRow.rect.top) < 12)
                        .Select(t => t.name).FirstOrDefault();
                rows.Add((label, Math.Round(percent, 1), reset));
            }
            return rows.Count > 0 ? rows : null;
        }
        catch (Exception e) { Log.Write("Usage popup: " + e.Message); return null; }
        finally
        {
            if (opened) { try { expander.Collapse(); } catch { } }
        }
    }

    // MARK: Quitting Claude

    const int MenuItemType = 50011, InvokePattern = 10000;

    static bool Invoke(IUIAutomationElement e)
    {
        try
        {
            if (e.GetCurrentPattern(InvokePattern) is IUIAutomationInvokePattern i) { i.Invoke(); return true; }
            if (e.GetCurrentPattern(ExpandCollapsePattern) is IUIAutomationExpandCollapsePattern x) { x.Expand(); return true; }
        }
        catch (Exception ex) { Log.Write("Invoke: " + ex.Message); }
        return false;
    }

    /// Claude's Menu → File → Exit, through UI Automation. False if the menu couldn't be found.
    public static bool QuitClaude(IntPtr hWnd)
    {
        if (hWnd == IntPtr.Zero) return false;
        if (Native.IsIconic(hWnd) || !Native.IsWindowVisible(hWnd)) Native.ShowWindow(hWnd, Native.SW_RESTORE);
        if (!WaitForTree(hWnd, 10)) return false;
        IUIAutomationElement? Item(string name) =>
            Find(hWnd, e => e.CurrentControlType == MenuItemType && e.CurrentName == name).FirstOrDefault();
        // The File menu shows once the window's Menu button is pressed.
        var file = Item("File");
        if (file == null)
        {
            var menu = Find(hWnd, e => e.CurrentControlType == ButtonType && e.CurrentName == "Menu").FirstOrDefault();
            if (menu == null || !Invoke(menu)) return false;
            Wait.Poll(3, () => (file = Item("File")) != null, 0.2);
        }
        if (file == null || !Invoke(file)) return false;
        IUIAutomationElement? exit = null;
        if (!Wait.Poll(3, () => (exit = Find(hWnd, e => e.CurrentControlType == MenuItemType && (e.CurrentName == "Exit" || e.CurrentName == "Quit" || (e.CurrentName ?? "").StartsWith("Quit "))).FirstOrDefault()) != null, 0.2) || exit == null)
            return false;
        return Invoke(exit);
    }

    /// If Claude asks whether to quit, says yes once (its Quit / Exit button).
    public static bool ConfirmQuit(IntPtr hWnd)
    {
        if (hWnd == IntPtr.Zero) return false;
        var button = Find(hWnd, e => e.CurrentControlType == ButtonType && e.CurrentName is "Quit" or "Exit" or "Quit Claude" or "Quit anyway" or "Quit Anyway").FirstOrDefault();
        if (button == null) return false;
        Log.Write($"Claude asked to confirm quitting; pressing {button.CurrentName}");
        return Invoke(button);
    }

    // MARK: The message box

    /// Claude's message box (the Edit named "Prompt"); the lowest one if there are several.
    public static IUIAutomationElement? MessageBox(IntPtr hWnd) =>
        Find(hWnd, e => e.CurrentControlType == EditType && e.CurrentName == "Prompt", all: true)
            .OrderByDescending(e => { try { return e.CurrentBoundingRectangle.bottom; } catch { return 0; } }).FirstOrDefault();

    public static string? Text(IUIAutomationElement box)
    {
        try { return ((IUIAutomationValuePattern)box.GetCurrentPattern(ValuePattern)).CurrentValue; } catch { return null; }
    }

    public static bool HasFocus(IUIAutomationElement box)
    {
        try { return box.CurrentHasKeyboardFocus != 0; } catch { return false; }
    }

    public static bool Focus(IUIAutomationElement box)
    {
        try { box.SetFocus(); Thread.Sleep(300); return HasFocus(box); } catch { return false; }
    }

    // MARK: The front window

    /// Brings Claude's window to the front (restoring it if it's minimized or in the tray).
    public static bool BringForward(IntPtr hWnd)
    {
        if (hWnd == IntPtr.Zero) return false;
        if (Native.IsIconic(hWnd) || !Native.IsWindowVisible(hWnd)) Native.ShowWindow(hWnd, Native.SW_RESTORE);
        if (Claude.IsClaudeWindow(Native.GetForegroundWindow())) return true;
        // Windows only lets the app in front hand over the foreground; a tap of Alt counts as input.
        Native.keybd_event((byte)Native.VK_MENU, 0, 0, UIntPtr.Zero);
        Native.keybd_event((byte)Native.VK_MENU, 0, Native.KEYEVENTF_KEYUP, UIntPtr.Zero);
        Native.SetForegroundWindow(hWnd);
        Native.BringWindowToTop(hWnd);
        return Wait.Poll(2, () => Claude.IsClaudeWindow(Native.GetForegroundWindow()), 0.1);
    }

    public static bool ClaudeInFront() => Claude.IsClaudeWindow(Native.GetForegroundWindow());

    // MARK: Typing (only into Claude)

    static Native.INPUT Key(ushort vk, ushort scan, uint flags) =>
        new() { type = Native.INPUT_KEYBOARD, u = new Native.InputUnion { ki = new Native.KEYBDINPUT { wVk = vk, wScan = scan, dwFlags = flags } } };

    static bool Send(Native.INPUT[] inputs)
    {
        if (!ClaudeInFront()) return false;
        return Native.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Native.INPUT>()) == inputs.Length;
    }

    /// Types `text` into Claude, a few characters at a time, checking before each that Claude is
    /// still in front. False if it stopped (something else came to the front).
    public static bool Type(string text)
    {
        foreach (var chunk in text.Chunk(16))
        {
            var inputs = new List<Native.INPUT>();
            foreach (var ch in chunk)
            {
                inputs.Add(Key(0, ch, Native.KEYEVENTF_UNICODE));
                inputs.Add(Key(0, ch, Native.KEYEVENTF_UNICODE | Native.KEYEVENTF_KEYUP));
            }
            if (!Send(inputs.ToArray())) { Log.Write("Typing stopped: Claude isn't in front"); return false; }
            Thread.Sleep(15);
        }
        return true;
    }

    public static bool Press(ushort vk) => Send(new[] { Key(vk, 0, 0), Key(vk, 0, Native.KEYEVENTF_KEYUP) });

    /// Ctrl+A, Delete: clears the focused message box.
    public static bool ClearBox() =>
        Send(new[] { Key(Native.VK_CONTROL, 0, 0), Key(Native.VK_A, 0, 0), Key(Native.VK_A, 0, Native.KEYEVENTF_KEYUP), Key(Native.VK_CONTROL, 0, Native.KEYEVENTF_KEYUP) })
        && Press(Native.VK_DELETE);

    // MARK: The person at the PC

    public static double SecondsSinceInput()
    {
        var info = new Native.LASTINPUTINFO { cbSize = (uint)Marshal.SizeOf<Native.LASTINPUTINFO>() };
        return Native.GetLastInputInfo(ref info) ? unchecked(Native.GetTickCount() - info.dwTime) / 1000.0 : 999;
    }

    /// Waits (up to `seconds`) until nobody has touched the PC for `quiet` seconds.
    public static bool WaitUntilIdle(double quiet, double seconds) => Wait.Poll(seconds, () => SecondsSinceInput() >= quiet, 1);

    /// True while the lock screen (or another secure desktop) is up.
    public static bool ScreenLocked()
    {
        var desk = Native.OpenInputDesktop(0, false, 0x0001);
        if (desk == IntPtr.Zero) return true;
        try
        {
            var name = new char[64];
            if (!Native.GetUserObjectInformation(desk, 2, name, name.Length * 2, out _)) return false;   // UOI_NAME
            return !new string(name).TrimEnd('\0').Equals("Default", StringComparison.OrdinalIgnoreCase);
        }
        finally { Native.CloseDesktop(desk); }
    }
}
