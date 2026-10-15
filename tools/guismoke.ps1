# GUI smoke of the main window on monitor 1: start the Debug build (or -Exe) with -Arg, then for each -Steps entry
# press its keys and save <Out>_<n>.png/.txt via uiadump.ps1. Closes it at the end.
# Keys: space-separated chords, '' = none. A chord is [ctrl+][alt+][shift+]key, optional *count:
#   'ctrl+t'   'down*5 enter'   'alt+left'   'f2'   'num+'
# Every key goes out with SendInput ONLY while MakePack's window is in front; otherwise the run stops - stray keys
# must never land in the user's apps (a lost Ctrl once turned Ctrl+T into type-ahead and Enter opened a file).
# Do not use Enter on files here: it opens them in the user's apps.
# The tested app must not already run (single instance: a second start only forwards its arguments).
# Usage: tools\guismoke.ps1 -Out C:\tmp\mp -Arg C:\some\folder -Steps '', 'ctrl+t', 'down*3'
# Pure ASCII (PS 5.1).
param([Parameter(Mandatory)][string]$Out, [string]$Arg = '', [string[]]$Steps = @(''), [string]$Exe = '',
      [int]$Screen = 1, [int]$WaitMs = 1200)

if (-not ('Mp.Input' -as [type])) {
    Add-Type -Namespace Mp -Name Input -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr extra; }
[StructLayout(LayoutKind.Explicit, Size = 40)] struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KEYBDINPUT ki; }
[DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint type);
static INPUT Key(ushort vk, bool up)
{
    var i = new INPUT { type = 1 };
    i.ki.wVk = vk; i.ki.wScan = (ushort)MapVirtualKey(vk, 0);
    bool ext = vk == 0x25 || vk == 0x26 || vk == 0x27 || vk == 0x28 || vk == 0x2D || vk == 0x2E || vk == 0x21 || vk == 0x22 || vk == 0x23 || vk == 0x24;
    i.ki.dwFlags = (up ? 2u : 0u) | (ext ? 1u : 0u);
    return i;
}
public static void Chord(ushort[] mods, ushort vk)
{
    var list = new System.Collections.Generic.List<INPUT>();
    foreach (var m in mods) list.Add(Key(m, false));
    list.Add(Key(vk, false)); list.Add(Key(vk, true));
    for (int i = mods.Length - 1; i >= 0; i--) list.Add(Key(mods[i], true));
    SendInput((uint)list.Count, list.ToArray(), Marshal.SizeOf(typeof(INPUT)));
}
'@
}

$names = @{ enter = 0x0D; esc = 0x1B; back = 0x08; tab = 0x09; space = 0x20; del = 0x2E; ins = 0x2D; home = 0x24; end = 0x23
            pgup = 0x21; pgdn = 0x22; left = 0x25; up = 0x26; right = 0x27; down = 0x28; 'num+' = 0x6B; 'num-' = 0x6D; 'num*' = 0x6A
            backslash = 0xDC }
function Vk([string]$k) {
    if ($names.ContainsKey($k)) { return [uint16]$names[$k] }
    if ($k -match '^f(\d+)$') { return [uint16](0x6F + [int]$Matches[1]) }
    if ($k.Length -eq 1) { return [uint16][char]$k.ToUpperInvariant() }
    throw "unknown key '$k'"
}

$root = Split-Path -Parent $PSScriptRoot
if (-not $Exe) { $Exe = Get-ChildItem "$root\src\MakePack\bin\Debug" -Recurse -Filter MakePack.exe | Select-Object -First 1 -ExpandProperty FullName }
if (Get-Process MakePack -ErrorAction SilentlyContinue) { throw 'MakePack is already running: close it first' }
. "$PSScriptRoot\screenpin.ps1"
Start-ScreenPin -Screen $Screen -Exe $Exe
try {
    $env:MAKEPACK_SETTINGS = "$Out`_settings.json"   # never the user's own settings
    if ($Arg) { $p = Start-Process $Exe -ArgumentList ('"' + $Arg + '"') -PassThru } else { $p = Start-Process $Exe -PassThru }
    Start-Sleep -Milliseconds 3000
    $n = 0
    foreach ($step in $Steps) {
        & "$PSScriptRoot\uiadump.ps1" -ProcessName MakePack -Out "$Out`_pre" -Screen $Screen -Depth 0 -Resize:($n -eq 0) | Out-Null   # brings it to front
        foreach ($chord in ($step -split ' ' | Where-Object { $_ })) {
            $count = 1
            if ($chord -match '^(.*)\*(\d+)$') { $chord = $Matches[1]; $count = [int]$Matches[2] }
            $parts = $chord.ToLowerInvariant() -split '\+(?=.)'
            $mods = @(); foreach ($m in $parts[0..($parts.Count - 2)]) { if ($parts.Count -gt 1) { $mods += @{ ctrl = 0x11; alt = 0x12; shift = 0x10 }[$m] } }
            $vk = Vk $parts[-1]
            for ($i = 0; $i -lt $count; $i++) {
                $fpid = 0; [void][Mp.Input]::GetWindowThreadProcessId([Mp.Input]::GetForegroundWindow(), [ref]$fpid)
                if ($fpid -ne $p.Id) { throw "foreground is pid $fpid, not MakePack ($($p.Id)): stopped before '$chord'" }
                [Mp.Input]::Chord([uint16[]]$mods, $vk)
                Start-Sleep -Milliseconds 150
            }
        }
        Start-Sleep -Milliseconds $WaitMs
        & "$PSScriptRoot\uiadump.ps1" -ProcessName MakePack -Out "$Out`_$n" -Screen $Screen -Depth 5
        $n++
    }
}
finally {
    Get-Process MakePack -ErrorAction SilentlyContinue | ForEach-Object { [void]$_.CloseMainWindow() }
    Start-Sleep -Milliseconds 800
    Stop-ScreenPin
}
