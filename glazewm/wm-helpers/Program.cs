// wm-helpers — the small pieces of this setup that need the Win32 window API,
// which Node cannot reach.
//
// Everything prints one line of JSON on stdout so the daemon can parse it.
//
//   wm-helpers fix-fullscreen [--dry]   find the window covering a monitor and
//                                       nudge it; --dry only reports
//   wm-helpers nudge <hwnd>             move a window 1px and put it back
//   wm-helpers inspect <hwnd>           the window's style bits, owner and
//                                       geometry — how a popup is recognised
//   wm-helpers classify <hwnd> <state>  diagnose how a window is fullscreen
//   wm-helpers mark-fullscreen <hwnd> <0|1>
//                                       ITaskbarList2::MarkFullscreenWindow;
//                                       kept for diagnostics, see below
//
// Why the odd-looking nudge is the actual fix, and why mark-fullscreen is not,
// is written up in docs/FULLSCREEN-GAMES.md.

using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

[ComImport]
[Guid("56FDF342-FD6D-11D0-958A-006097C9A090")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ITaskbarList
{
    void HrInit();
    void AddTab(IntPtr hwnd);
    void DeleteTab(IntPtr hwnd);
    void ActivateTab(IntPtr hwnd);
    void SetActiveAlt(IntPtr hwnd);
}

[ComImport]
[Guid("602D4995-B13A-429B-A66E-1935E44F4317")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ITaskbarList2 : ITaskbarList
{
    void MarkFullscreenWindow(IntPtr hwnd, [MarshalAs(UnmanagedType.Bool)] bool fullscreen);
}

[ComImport]
[Guid("56FDF344-FD6D-11D0-958A-006097C9A090")]
class CTaskbarList
{
}

static class Native
{
    public const int GwlStyle = -16;
    public const int GwlExStyle = -20;
    public const int WsCaption = 0x00C00000;
    public const int WsPopup = unchecked((int)0x80000000);
    public const int WsChild = 0x40000000;
    public const int WsMaximize = 0x01000000;
    public const int WsThickFrame = 0x00040000;
    public const int WsMinimizeBox = 0x00020000;
    public const int WsMaximizeBox = 0x00010000;
    public const int WsSysMenu = 0x00080000;
    public const int SwShowMaximized = 3;

    public const int WsExDlgModalFrame = 0x00000001;
    public const int WsExToolWindow = 0x00000080;
    public const int WsExAppWindow = 0x00040000;
    public const int WsExNoActivate = 0x08000000;

    public const uint GwOwner = 4;

    public const uint SwpNoSize = 0x0001;
    public const uint SwpNoZOrder = 0x0004;
    public const uint SwpNoActivate = 0x0010;

    public const uint MonitorDefaultToNearest = 2;
    public const int DwmwaCloaked = 14;

    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out Rect rect);

    [DllImport("user32.dll")]
    public static extern bool GetWindowPlacement(IntPtr hWnd, ref WindowPlacement placement);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindowEnabled(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetWindow(IntPtr hWnd, uint command);

    [DllImport("user32.dll")]
    public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MonitorInfo info);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(
        IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, uint flags);

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder buffer, int max);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder buffer, int max);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(
        IntPtr hWnd, int attribute, out int value, int size);

    [StructLayout(LayoutKind.Sequential)]
    public struct Rect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;

        public int Width => Right - Left;
        public int Height => Bottom - Top;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WindowPlacement
    {
        public int Length;
        public int Flags;
        public int ShowCmd;
        public Point MinPosition;
        public Point MaxPosition;
        public Rect NormalPosition;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Point
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MonitorInfo
    {
        public int Size;
        public Rect Monitor;
        public Rect Work;
        public uint Flags;
    }
}

static class WmHelpersEntry
{
    public static int Main(string[] args)
    {
        try
        {
            if (args.Length == 0)
            {
                Usage();
                return 1;
            }

            return args[0] switch
            {
                "fix-fullscreen" => FixFullscreen(args),
                "nudge" => Nudge(args),
                "inspect" => Inspect(args),
                "classify" => Classify(args),
                "mark-fullscreen" => MarkFullscreen(args),
                _ => Unknown(args[0]),
            };
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex);
            return 2;
        }
    }

    static void Usage()
    {
        Console.Error.WriteLine("Usage: wm-helpers fix-fullscreen [--dry]");
        Console.Error.WriteLine("       wm-helpers nudge <hwnd>");
        Console.Error.WriteLine("       wm-helpers inspect <hwnd>");
        Console.Error.WriteLine("       wm-helpers classify <hwnd> <glazeState>");
        Console.Error.WriteLine("       wm-helpers mark-fullscreen <hwnd> <0|1>");
    }

    static int Unknown(string command)
    {
        Console.Error.WriteLine($"Unknown command: {command}");
        Usage();
        return 1;
    }

    /// <summary>
    /// Finds the window covering a whole monitor and nudges it.
    ///
    /// It enumerates windows itself rather than asking GlazeWM, because the
    /// case that breaks is precisely a window GlazeWM does not manage: measured,
    /// a managed window in fullscreen state survives a workspace switch and an
    /// unmanaged one does not.
    ///
    /// EnumWindows walks in Z order, front to back, so the first match is the
    /// one in front.
    /// </summary>
    static int FixFullscreen(string[] args)
    {
        var dryRun = args.Contains("--dry");
        var candidates = FindCoveringWindows();

        if (candidates.Count == 0)
        {
            Console.WriteLine(JsonSerializer.Serialize(new { ok = true, found = false }));
            return 0;
        }

        var chosen = candidates[0];
        if (!dryRun) NudgeWindow(new IntPtr(chosen.Hwnd));

        Console.WriteLine(JsonSerializer.Serialize(new
        {
            ok = true,
            found = true,
            nudged = !dryRun,
            hwnd = chosen.Hwnd,
            process = chosen.Process,
            title = chosen.Title,
            className = chosen.ClassName,
            hasCaption = chosen.HasCaption,
            otherCandidates = candidates.Count - 1,
        }));
        return 0;
    }

    static int Nudge(string[] args)
    {
        if (args.Length != 2)
        {
            Console.Error.WriteLine("Usage: wm-helpers nudge <hwnd>");
            return 1;
        }

        var hwnd = new IntPtr(ParseLong(args[1]));
        var done = NudgeWindow(hwnd);
        Console.WriteLine(JsonSerializer.Serialize(new { ok = done, hwnd = hwnd.ToInt64() }));
        return 0;
    }

    /// <summary>
    /// Moves the window down one pixel and back.
    ///
    /// The shell decides whether to suppress the taskbar on an edge, not on a
    /// level: it notices a fullscreen window when it sees a position change that
    /// ends up covering the whole monitor. A workspace switch loses that state
    /// and nothing restores it — not MarkFullscreenWindow, not
    /// SetForegroundWindow, not SWP_FRAMECHANGED. All measured.
    ///
    /// The movement has to genuinely break coverage. Moving down 1px works;
    /// growing by 1px does not, because the window never stops covering the
    /// monitor and there is no edge to see.
    ///
    /// It is a pure move (SWP_NOSIZE) on purpose: a resize forces a DirectX game
    /// to recreate its swap chain, a WM_MOVE does not.
    /// </summary>
    static bool NudgeWindow(IntPtr hwnd)
    {
        if (!Native.IsWindowVisible(hwnd)) return false;

        Native.GetWindowRect(hwnd, out var rect);
        const uint flags = Native.SwpNoSize | Native.SwpNoZOrder | Native.SwpNoActivate;

        Native.SetWindowPos(hwnd, IntPtr.Zero, rect.Left, rect.Top + 1, 0, 0, flags);
        Thread.Sleep(120);
        Native.SetWindowPos(hwnd, IntPtr.Zero, rect.Left, rect.Top, 0, 0, flags);
        return true;
    }

    // Window classes that are a dialog by construction. `#32770` is the one that
    // matters: it is the class Windows itself registers for every dialog box, so
    // Save As, Print, Properties and most "are you sure?" boxes all report it.
    static readonly string[] DialogClasses = { "#32770", "TaskDialog", "MsgBoxWindowClass" };

    /// <summary>
    /// Reports what Windows knows about one window: its style bits, whether
    /// another window owns it, its class, and how big it is next to the work
    /// area of its monitor.
    ///
    /// These are facts, not a verdict. Whether a window is a popup worth
    /// floating is a policy question, and policy lives in autotiling.mjs where
    /// it can be edited without a compiler. What cannot be done there is this:
    /// GlazeWM's IPC exposes neither the style bits nor the owner, and those are
    /// what separates a modal dialog from an ordinary window that happens to be
    /// small.
    /// </summary>
    static int Inspect(string[] args)
    {
        if (args.Length != 2)
        {
            Console.Error.WriteLine("Usage: wm-helpers inspect <hwnd>");
            return 1;
        }

        var hwnd = new IntPtr(ParseLong(args[1]));
        if (!Native.IsWindow(hwnd))
        {
            Console.WriteLine(JsonSerializer.Serialize(new { ok = false, error = "no such window" }));
            return 0;
        }

        var style = Native.GetWindowLong(hwnd, Native.GwlStyle);
        var exStyle = Native.GetWindowLong(hwnd, Native.GwlExStyle);
        var owner = Native.GetWindow(hwnd, Native.GwOwner);
        var className = TextOf((sb, max) => Native.GetClassName(hwnd, sb, max));

        Native.GetWindowRect(hwnd, out var rect);
        var monitor = MonitorRectOf(hwnd);

        Console.WriteLine(JsonSerializer.Serialize(new
        {
            ok = true,
            hwnd = hwnd.ToInt64(),
            @class = className,
            title = TextOf((sb, max) => Native.GetWindowText(hwnd, sb, max)),
            process = ProcessNameOf(hwnd),
            visible = Native.IsWindowVisible(hwnd),
            owner = owner.ToInt64(),
            ownerProcess = owner == IntPtr.Zero ? "" : ProcessNameOf(owner),
            // A modal dialog disables its owner while it is up. That is the only
            // reliable way to tell "modal" from "merely owned".
            ownerDisabled = owner != IntPtr.Zero && !Native.IsWindowEnabled(owner),
            dialogClass = DialogClasses.Contains(className),
            style = new
            {
                popup = (style & Native.WsPopup) != 0,
                child = (style & Native.WsChild) != 0,
                caption = (style & Native.WsCaption) == Native.WsCaption,
                thickFrame = (style & Native.WsThickFrame) != 0,
                minimizeBox = (style & Native.WsMinimizeBox) != 0,
                maximizeBox = (style & Native.WsMaximizeBox) != 0,
                sysMenu = (style & Native.WsSysMenu) != 0,
            },
            exStyle = new
            {
                toolWindow = (exStyle & Native.WsExToolWindow) != 0,
                appWindow = (exStyle & Native.WsExAppWindow) != 0,
                modalFrame = (exStyle & Native.WsExDlgModalFrame) != 0,
                noActivate = (exStyle & Native.WsExNoActivate) != 0,
            },
            rect = new { x = rect.Left, y = rect.Top, width = rect.Width, height = rect.Height },
            work = new
            {
                x = monitor.Work.Left,
                y = monitor.Work.Top,
                width = monitor.Work.Width,
                height = monitor.Work.Height,
            },
        }));
        return 0;
    }

    static int Classify(string[] args)
    {
        if (args.Length != 3)
        {
            Console.Error.WriteLine("Usage: wm-helpers classify <hwnd> <glazeState>");
            return 1;
        }

        var hwnd = new IntPtr(ParseLong(args[1]));
        var glazeState = args[2].ToLowerInvariant();
        Console.WriteLine(JsonSerializer.Serialize(WindowClassifier.Classify(hwnd, glazeState)));
        return 0;
    }

    /// <summary>
    /// The documented way to tell the shell a window is fullscreen. Measured not
    /// to fix the taskbar bug from another process, in either direction. Kept
    /// because it is useful to be able to rule it out again.
    /// </summary>
    static int MarkFullscreen(string[] args)
    {
        if (args.Length != 3)
        {
            Console.Error.WriteLine("Usage: wm-helpers mark-fullscreen <hwnd> <0|1>");
            return 1;
        }

        var hwnd = new IntPtr(ParseLong(args[1]));
        var fullscreen = args[2] == "1";

        var taskbar = (ITaskbarList2)new CTaskbarList();
        taskbar.HrInit();
        taskbar.MarkFullscreenWindow(hwnd, fullscreen);

        Console.WriteLine(
            JsonSerializer.Serialize(new { ok = true, hwnd = hwnd.ToInt64(), fullscreen }));
        return 0;
    }

    sealed record CoveringWindow(
        long Hwnd, string Process, string Title, string ClassName, bool HasCaption);

    // Shell and bar windows: they cover or surround the screen but are never
    // what we are looking for.
    static readonly string[] IgnoredClasses =
    {
        "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "Progman", "WorkerW",
        "Windows.UI.Core.CoreWindow", "ApplicationFrameWindow",
    };

    static readonly string[] IgnoredProcesses = { "explorer", "yasb", "zebar", "glazewm" };

    static List<CoveringWindow> FindCoveringWindows()
    {
        const int tolerance = 8;
        var found = new List<CoveringWindow>();

        Native.EnumWindows((hwnd, _) =>
        {
            if (!Native.IsWindowVisible(hwnd)) return true;

            // UWP applications leave cloaked ghost windows behind that are still
            // visible as far as EnumWindows is concerned.
            if (Native.DwmGetWindowAttribute(hwnd, Native.DwmwaCloaked, out var cloaked, sizeof(int)) == 0
                && cloaked != 0)
            {
                return true;
            }

            var className = TextOf((sb, max) => Native.GetClassName(hwnd, sb, max));
            if (IgnoredClasses.Contains(className)) return true;

            var process = ProcessNameOf(hwnd);
            if (IgnoredProcesses.Contains(process, StringComparer.OrdinalIgnoreCase)) return true;

            Native.GetWindowRect(hwnd, out var rect);
            var monitor = MonitorRectOf(hwnd).Monitor;

            // Covering the whole MONITOR is required, not the work area, so an
            // ordinary maximized window does not count.
            var covers =
                rect.Left <= monitor.Left + tolerance &&
                rect.Top <= monitor.Top + tolerance &&
                rect.Right >= monitor.Right - tolerance &&
                rect.Bottom >= monitor.Bottom - tolerance;
            if (!covers) return true;

            var style = Native.GetWindowLong(hwnd, Native.GwlStyle);
            found.Add(new CoveringWindow(
                hwnd.ToInt64(),
                process,
                TextOf((sb, max) => Native.GetWindowText(hwnd, sb, max)),
                className,
                (style & Native.WsCaption) == Native.WsCaption));
            return true;
        }, IntPtr.Zero);

        return found;
    }

    internal static (Native.Rect Monitor, Native.Rect Work) MonitorRectOf(IntPtr hwnd)
    {
        var hMonitor = Native.MonitorFromWindow(hwnd, Native.MonitorDefaultToNearest);
        var info = new Native.MonitorInfo { Size = Marshal.SizeOf<Native.MonitorInfo>() };
        Native.GetMonitorInfo(hMonitor, ref info);
        return (info.Monitor, info.Work);
    }

    static string TextOf(Func<StringBuilder, int, int> read)
    {
        var sb = new StringBuilder(256);
        read(sb, sb.Capacity);
        return sb.ToString();
    }

    static string ProcessNameOf(IntPtr hwnd)
    {
        Native.GetWindowThreadProcessId(hwnd, out var pid);
        try
        {
            using var p = System.Diagnostics.Process.GetProcessById((int)pid);
            return p.ProcessName;
        }
        catch
        {
            return "";
        }
    }

    static long ParseLong(string value) =>
        Convert.ToInt64(value, CultureInfo.InvariantCulture);
}

sealed record ClassifyResult(
    string mode,
    bool hideTaskbar,
    bool hasCaption,
    bool maximized,
    int width,
    int height,
    int x,
    int y,
    int monitorWidth,
    int monitorHeight);

/// <summary>
/// Works out how a window is fullscreen, if at all. Diagnostics only: the
/// daemon does not use this, but it answers "why did fix-fullscreen not see my
/// game" without guessing.
/// </summary>
static class WindowClassifier
{
    const int CoverTolerance = 8;

    public static ClassifyResult Classify(IntPtr hwnd, string glazeState)
    {
        if (!Native.IsWindowVisible(hwnd))
        {
            return Result("hidden", false, hwnd, false, false);
        }

        if (glazeState == "fullscreen")
        {
            return Result("glaze_fullscreen", true, hwnd, false, false);
        }

        Native.GetWindowRect(hwnd, out var rect);
        var monitor = WmHelpersEntry.MonitorRectOf(hwnd);
        var style = Native.GetWindowLong(hwnd, Native.GwlStyle);
        var hasCaption = (style & Native.WsCaption) == Native.WsCaption;
        var isPopup = (style & Native.WsPopup) == Native.WsPopup;

        var placement = new Native.WindowPlacement
        {
            Length = Marshal.SizeOf<Native.WindowPlacement>(),
        };
        Native.GetWindowPlacement(hwnd, ref placement);
        var maximized = placement.ShowCmd == Native.SwShowMaximized;

        var coversMonitor =
            rect.Width >= monitor.Monitor.Width - CoverTolerance &&
            rect.Height >= monitor.Monitor.Height - CoverTolerance &&
            rect.Left <= monitor.Monitor.Left + CoverTolerance &&
            rect.Top <= monitor.Monitor.Top + CoverTolerance;

        var coversWorkArea =
            rect.Width >= monitor.Work.Width - CoverTolerance &&
            rect.Height >= monitor.Work.Height - CoverTolerance &&
            rect.Left <= monitor.Work.Left + CoverTolerance &&
            rect.Top <= monitor.Work.Top + CoverTolerance;

        // No title bar and covering almost everything: borderless or exclusive.
        if (!hasCaption && (coversMonitor || coversWorkArea))
        {
            if (rect.Top <= monitor.Monitor.Top + CoverTolerance && coversMonitor)
            {
                return Result("exclusive", true, hwnd, hasCaption, maximized);
            }

            return Result("borderless", true, hwnd, hasCaption, maximized);
        }

        if (maximized || (style & Native.WsMaximize) == Native.WsMaximize)
        {
            return Result("maximized", false, hwnd, hasCaption, maximized);
        }

        if (isPopup && !hasCaption && rect.Width > 800 && rect.Height > 600)
        {
            return Result("borderless", true, hwnd, hasCaption, maximized);
        }

        return Result("normal", false, hwnd, hasCaption, maximized);
    }

    static ClassifyResult Result(
        string mode, bool hideTaskbar, IntPtr hwnd, bool hasCaption, bool maximized)
    {
        Native.GetWindowRect(hwnd, out var rect);
        var monitor = WmHelpersEntry.MonitorRectOf(hwnd);
        return new ClassifyResult(
            mode,
            hideTaskbar,
            hasCaption,
            maximized,
            rect.Width,
            rect.Height,
            rect.Left,
            rect.Top,
            monitor.Monitor.Width,
            monitor.Monitor.Height);
    }
}
