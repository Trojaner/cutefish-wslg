<#
.SYNOPSIS
Gives the windows of Cutefish applications running under WSLg the background
blur Cutefish's own compositor would draw.

.DESCRIPTION
Under WSLg every Linux window is a Windows window of the Remote Desktop
client, and what lies behind it is the Windows desktop, which neither the
application nor WSLg's compositor can see. Windows' compositor blurs it
instead: this script watches for the client's windows, and gives those whose
relaunch command runs a Cutefish application a blurred background, Windows'
rounded corners, which clip the blur with the window, and no border line.

It runs without a window, one instance per user; install.ps1 starts it at
logon through a shortcut in the Startup folder.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$mutex = New-Object System.Threading.Mutex($false, 'Local\cutefish-wslg-blur')
if (-not $mutex.WaitOne(0)) { exit 0 }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class CutefishWslgBlur
{
    const uint EVENT_OBJECT_DESTROY = 0x8001, EVENT_OBJECT_SHOW = 0x8002, EVENT_OBJECT_NAMECHANGE = 0x800C;
    const uint WINEVENT_OUTOFCONTEXT = 0, WINEVENT_SKIPOWNPROCESS = 2;
    const int OBJID_WINDOW = 0, GWL_STYLE = -16, WS_CHILD = 0x40000000;
    const int WCA_ACCENT_POLICY = 19, ACCENT_ENABLE_BLURBEHIND = 3;
    const int DWMWA_WINDOW_CORNER_PREFERENCE = 33, DWMWCP_ROUND = 2;
    const int DWMWA_BORDER_COLOR = 34, DWMWA_COLOR_NONE = unchecked((int)0xFFFFFFFE);
    const uint WM_TIMER = 0x0113;

    delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hwnd, int obj, int child, uint thread, uint time);
    delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)] struct AccentPolicy { public int State, Flags; public uint Gradient; public int Animation; }
    [StructLayout(LayoutKind.Sequential)] struct CompositionData { public int Attribute; public IntPtr Data; public int Size; }
    [StructLayout(LayoutKind.Sequential)] struct PropertyKey { public Guid Format; public uint Id; }
    [StructLayout(LayoutKind.Explicit, Size = 24)] struct PropVariant { [FieldOffset(0)] public ushort Type; [FieldOffset(8)] public IntPtr Pointer; }
    [StructLayout(LayoutKind.Sequential)] struct Msg { public IntPtr Hwnd; public uint Message; public IntPtr WParam, LParam; public uint Time; public int X, Y; }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore
    {
        int GetCount(out uint count);
        int GetAt(uint index, out PropertyKey key);
        int GetValue(ref PropertyKey key, out PropVariant value);
        int SetValue(ref PropertyKey key, ref PropVariant value);
        int Commit();
    }

    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEventProc proc, uint process, uint thread, uint flags);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc proc, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint process);
    [DllImport("user32.dll")] static extern int SetWindowCompositionAttribute(IntPtr hwnd, ref CompositionData data);
    [DllImport("user32.dll")] static extern UIntPtr SetTimer(IntPtr hwnd, UIntPtr id, uint ms, IntPtr proc);
    [DllImport("user32.dll")] static extern int GetMessage(out Msg msg, IntPtr hwnd, uint min, uint max);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref Msg msg);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref Msg msg);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
    [DllImport("shell32.dll")] static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);
    [DllImport("ole32.dll")] static extern int PropVariantClear(ref PropVariant value);

    static readonly HashSet<IntPtr> applied = new HashSet<IntPtr>();
    static readonly Dictionary<uint, bool> clients = new Dictionary<uint, bool>();
    static WinEventProc eventProc;

    // The Remote Desktop clients WSLg shows windows through.
    static bool IsRdpClient(uint process)
    {
        bool known;
        if (clients.TryGetValue(process, out known))
            return known;
        try {
            string name = Process.GetProcessById((int)process).ProcessName;
            known = name.Equals("msrdc", StringComparison.OrdinalIgnoreCase)
                || name.Equals("mstsc", StringComparison.OrdinalIgnoreCase);
        } catch (ArgumentException) {
            known = false;
        }
        clients[process] = known;
        return known;
    }

    // WSLg gives each application window a relaunch command such as
    // "wslg.exe -d Ubuntu --cd ~ -- cutefish-calculator".
    static string RelaunchCommand(IntPtr hwnd)
    {
        Guid iid = typeof(IPropertyStore).GUID;
        IPropertyStore store;
        if (SHGetPropertyStoreForWindow(hwnd, ref iid, out store) != 0 || store == null)
            return null;
        try {
            PropertyKey key = new PropertyKey { Format = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), Id = 2 };
            PropVariant value;
            if (store.GetValue(ref key, out value) != 0)
                return null;
            string command = value.Type == 31 ? Marshal.PtrToStringUni(value.Pointer) : null;
            PropVariantClear(ref value);
            return command;
        } finally {
            Marshal.ReleaseComObject(store);
        }
    }

    static bool IsCutefishWindow(IntPtr hwnd)
    {
        if (!IsWindowVisible(hwnd) || (GetWindowLong(hwnd, GWL_STYLE) & WS_CHILD) != 0)
            return false;
        uint process;
        GetWindowThreadProcessId(hwnd, out process);
        if (!IsRdpClient(process))
            return false;
        string command = RelaunchCommand(hwnd);
        return command != null && command.IndexOf(" -- cutefish-", StringComparison.Ordinal) >= 0;
    }

    static void Apply(IntPtr hwnd)
    {
        if (applied.Contains(hwnd) || !IsCutefishWindow(hwnd))
            return;
        AccentPolicy accent = new AccentPolicy { State = ACCENT_ENABLE_BLURBEHIND };
        int size = Marshal.SizeOf(accent);
        IntPtr data = Marshal.AllocHGlobal(size);
        try {
            Marshal.StructureToPtr(accent, data, false);
            CompositionData composition = new CompositionData { Attribute = WCA_ACCENT_POLICY, Data = data, Size = size };
            if (SetWindowCompositionAttribute(hwnd, ref composition) == 0)
                return;
        } finally {
            Marshal.FreeHGlobal(data);
        }
        int corner = DWMWCP_ROUND, border = DWMWA_COLOR_NONE;
        DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref corner, sizeof(int));
        DwmSetWindowAttribute(hwnd, DWMWA_BORDER_COLOR, ref border, sizeof(int));
        applied.Add(hwnd);
    }

    static void Sweep()
    {
        applied.RemoveWhere(hwnd => !IsWindowVisible(hwnd));
        EnumWindows((hwnd, lParam) => { Apply(hwnd); return true; }, IntPtr.Zero);
    }

    static void OnEvent(IntPtr hook, uint ev, IntPtr hwnd, int obj, int child, uint thread, uint time)
    {
        if (obj != OBJID_WINDOW || child != 0 || hwnd == IntPtr.Zero)
            return;
        if (ev == EVENT_OBJECT_DESTROY)
            applied.Remove(hwnd);
        else
            Apply(hwnd);
    }

    public static void Run()
    {
        eventProc = OnEvent;
        SetWinEventHook(EVENT_OBJECT_DESTROY, EVENT_OBJECT_SHOW, IntPtr.Zero, eventProc, 0, 0,
                        WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
        // The relaunch command may arrive after the window shows; the title
        // change and a periodic sweep catch those.
        SetWinEventHook(EVENT_OBJECT_NAMECHANGE, EVENT_OBJECT_NAMECHANGE, IntPtr.Zero, eventProc, 0, 0,
                        WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
        SetTimer(IntPtr.Zero, UIntPtr.Zero, 3000, IntPtr.Zero);
        Sweep();
        Msg msg;
        while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0) {
            if (msg.Message == WM_TIMER && msg.Hwnd == IntPtr.Zero) {
                clients.Clear();
                Sweep();
                continue;
            }
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }
    }
}
'@

[CutefishWslgBlur]::Run()
