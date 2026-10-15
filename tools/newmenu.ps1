# Lists Explorer's New submenu for a folder, through the shell's own CLSID_NewMenu - what Explorer would show.
# Usage: powershell -STA -File tools\newmenu.ps1 -Folder <dir>. ASCII only.
param([string]$Folder)
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

[ComImport, Guid("000214E8-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IShellExtInit { [PreserveSig] int Initialize(IntPtr pidlFolder, IntPtr pdtobj, IntPtr hkeyProgID); }

[ComImport, Guid("000214F4-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IContextMenu2
{
    [PreserveSig] int QueryContextMenu(IntPtr hmenu, uint index, uint idFirst, uint idLast, uint flags);
    [PreserveSig] int InvokeCommand(IntPtr pici);
    [PreserveSig] int GetCommandString(UIntPtr id, uint type, IntPtr reserved, IntPtr name, uint cch);
    [PreserveSig] int HandleMenuMsg(uint msg, IntPtr wParam, IntPtr lParam);
}

public static class NewMenu
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHParseDisplayName(string name, IntPtr bc, out IntPtr pidl, uint sfgao, out uint psfgao);
    [DllImport("user32.dll")] static extern IntPtr CreatePopupMenu();
    [DllImport("user32.dll")] static extern int GetMenuItemCount(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetSubMenu(IntPtr h, int pos);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetMenuString(IntPtr h, uint id, StringBuilder s, int max, uint flags);

    public static List<string> Items(string folder)
    {
        var o = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("D969A300-E7FF-11d0-A93B-00A0C90F2719")));
        IntPtr pidl; uint x;
        SHParseDisplayName(folder, IntPtr.Zero, out pidl, 0, out x);
        ((IShellExtInit)o).Initialize(pidl, IntPtr.Zero, IntPtr.Zero);
        var cm = (IContextMenu2)o;
        var menu = CreatePopupMenu();
        cm.QueryContextMenu(menu, 0, 1, 0x7FFF, 0);
        var list = new List<string>();
        for (int i = 0; i < GetMenuItemCount(menu); i++)
        {
            var sub = GetSubMenu(menu, i);
            if (sub == IntPtr.Zero) continue;
            cm.HandleMenuMsg(0x0117, sub, (IntPtr)i);   // WM_INITMENUPOPUP: the shell fills New... only now
            for (int j = 0; j < GetMenuItemCount(sub); j++)
            {
                var sb = new StringBuilder(260);
                GetMenuString(sub, (uint)j, sb, sb.Capacity, 0x400);   // MF_BYPOSITION
                if (sb.Length > 0) list.Add(sb.ToString());
            }
        }
        return list;
    }
}
'@
[NewMenu]::Items($Folder)
