# Keeps the windows a GUI test opens on one monitor, so they do not pop up over the user's work.
# Dot-source it, then: Start-ScreenPin -Screen 1 -Exe <tested exe>  ...  Stop-ScreenPin
# A WinEvent hook (out of context, own thread, per-monitor DPI aware) catches every top-level window shown by the
# tested exe or by anything run from %TEMP% (SFX archives, fixtures) and centres it on \\.\DISPLAY<n>.
# Pure ASCII (PS 5.1). Screen 0 or a monitor that is not there = nothing is moved.

if (-not ('Mp.ScreenPin' -as [type])) {
    Add-Type -Namespace Mp -Name ScreenPin -UsingNamespace System.Text, System.Threading -MemberDefinition @'
delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
delegate bool MonitorEnumProc(IntPtr mon, IntPtr hdc, ref RECT r, IntPtr data);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
struct MONITORINFOEX { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice; }
[StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int x, y; }

[DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventProc proc, uint pid, uint tid, uint flags);
[DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr hook);
[DllImport("user32.dll")] static extern int GetMessage(out MSG m, IntPtr h, uint min, uint max);
[DllImport("user32.dll")] static extern bool PostThreadMessage(uint tid, uint msg, IntPtr w, IntPtr l);
[DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
[DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr mon, ref MONITORINFOEX mi);
[DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
[DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
[DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
[DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
[DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr h, uint flags, StringBuilder name, ref int size);
[DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
[DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);

static RECT work;
static string[] prefixes = new string[0];
static uint loopThread;
static WinEventProc keep;   // the hook holds only a native pointer: keep the delegate alive

static string ImagePath(uint pid)
{
    var h = OpenProcess(0x1000, false, pid);   // PROCESS_QUERY_LIMITED_INFORMATION
    if (h == IntPtr.Zero) return null;
    try { var sb = new StringBuilder(1024); int n = sb.Capacity; return QueryFullProcessImageName(h, 0, sb, ref n) ? sb.ToString() : null; }
    finally { CloseHandle(h); }
}

static void OnShow(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
{
    if (idObject != 0 || hwnd == IntPtr.Zero || GetAncestor(hwnd, 2) != hwnd) return;   // whole top-level windows only
    uint pid; GetWindowThreadProcessId(hwnd, out pid);
    var path = ImagePath(pid);
    if (path == null) return;
    bool ours = false;
    foreach (var p in prefixes) if (path.StartsWith(p, StringComparison.OrdinalIgnoreCase)) ours = true;
    if (!ours) return;
    RECT r; if (!GetWindowRect(hwnd, out r)) return;
    if (r.L >= work.L && r.R <= work.R && r.T >= work.T && r.B <= work.B) return;   // already there
    int w = r.R - r.L, h = r.B - r.T;
    int x = work.L + Math.Max(0, (work.R - work.L - w) / 2), y = work.T + Math.Max(0, (work.B - work.T - h) / 2);
    SetWindowPos(hwnd, IntPtr.Zero, x, y, 0, 0, 0x0001 | 0x0004 | 0x0010);   // NOSIZE | NOZORDER | NOACTIVATE
}

public static bool Start(string device, string[] pathPrefixes)
{
    prefixes = pathPrefixes;
    bool found = false;
    var ready = new ManualResetEvent(false);
    var t = new Thread(() =>
    {
        SetThreadDpiAwarenessContext((IntPtr)(-4));   // per-monitor v2: real pixels, like the app's own windows
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr m, IntPtr dc, ref RECT rc, IntPtr d) =>
        {
            var mi = new MONITORINFOEX(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
            if (GetMonitorInfo(m, ref mi) && mi.szDevice.EndsWith(device, StringComparison.OrdinalIgnoreCase)) { work = mi.rcWork; found = true; }
            return true;
        }, IntPtr.Zero);
        loopThread = GetCurrentThreadId();
        keep = OnShow;
        var hook = found ? SetWinEventHook(0x8002, 0x8002, IntPtr.Zero, keep, 0, 0, 0) : IntPtr.Zero;   // EVENT_OBJECT_SHOW, out of context
        ready.Set();
        if (hook == IntPtr.Zero) return;
        MSG msg;
        while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0) { }
        UnhookWinEvent(hook);
    });
    t.IsBackground = true;
    t.Start();
    ready.WaitOne();
    return found;
}

public static void Stop() { if (loopThread != 0) PostThreadMessage(loopThread, 0x0012, IntPtr.Zero, IntPtr.Zero); loopThread = 0; }   // WM_QUIT
'@
}

function Start-ScreenPin([int]$Screen, [string]$Exe) {
    if ($Screen -le 0) { return }
    $dir = Split-Path -Parent ([IO.Path]::GetFullPath($Exe))
    $ok = [Mp.ScreenPin]::Start(('DISPLAY' + $Screen), @(($dir.TrimEnd('\') + '\'), ([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\')))
    if ($ok) { Write-Host ("windows: pinned to screen " + $Screen) } else { Write-Host ("windows: no screen " + $Screen + ", left where they open") }
}

function Stop-ScreenPin { [Mp.ScreenPin]::Stop() }
