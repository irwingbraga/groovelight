using System.ComponentModel;
using System.Runtime.InteropServices;
using Groovelight.Audio;
using Groovelight.Model;
using SkiaSharp;

namespace Groovelight.Shell;

/// <summary>
/// The Windows shell around the library window (the Mac's menu bar extra and Dock menu): an icon in the notification
/// area (click for the mini player, right-click for the controls), Previous, Play/Pause and Next under the taskbar
/// thumbnail, and the jump list's tasks.
/// </summary>
public sealed partial class TaskbarIntegration : IDisposable
{
    private static AppModel Model => AppModel.Current;
    private readonly IntPtr window;
    private readonly SubclassProcedure procedure;
    private readonly uint taskbarCreated;
    private readonly uint buttonCreated;
    private IntPtr trayIcon;
    private ITaskbarList3? taskbar;
    private readonly IntPtr[] buttonIcons = new IntPtr[3];
    private bool buttonsAdded;

    private const int TrayMessage = 0x8001;
    private const uint TrayId = 1;
    private const int CommandPrevious = 100, CommandPlay = 101, CommandNext = 102;

    public TaskbarIntegration(IntPtr window)
    {
        this.window = window;
        procedure = WindowProcedure;
        SetWindowSubclass(window, procedure, 1, IntPtr.Zero);
        taskbarCreated = RegisterWindowMessage("TaskbarCreated");
        buttonCreated = RegisterWindowMessage("TaskbarButtonCreated");
        AddTrayIcon();
        Model.Player.PropertyChanged += OnPlayerChanged;
        JumpList.Update();
    }

    // MARK: Notification area

    private void AddTrayIcon()
    {
        trayIcon = LoadImage(IntPtr.Zero, Path.Combine(AppContext.BaseDirectory, "Assets", "Groovelight.ico"), 1, GetSystemMetrics(49), GetSystemMetrics(50), 0x10);
        var data = TrayData();
        data.uFlags = 0x1 | 0x2 | 0x4;
        Shell_NotifyIcon(0, ref data);
    }

    private NotifyIconData TrayData()
    {
        var item = Model.Player.Current;
        return new NotifyIconData
        {
            cbSize = Marshal.SizeOf<NotifyIconData>(),
            hWnd = window,
            uID = TrayId,
            uCallbackMessage = TrayMessage,
            hIcon = trayIcon,
            szTip = Truncate(item is null ? "Groovelight" : $"{item.Title} — {item.Artist}", 127),
        };
    }

    private static string Truncate(string text, int length) => text.Length <= length ? text : text[..(length - 1)] + "…";

    private void UpdateTray()
    {
        var data = TrayData();
        data.uFlags = 0x4;
        Shell_NotifyIcon(1, ref data);
    }

    private void ShowTrayMenu()
    {
        var player = Model.Player;
        var menu = CreatePopupMenu();
        var item = player.Current;
        if (item is not null)
        {
            AppendMenu(menu, 0x1, 0, Truncate(item.Title, 60));
            AppendMenu(menu, 0x1, 0, Truncate(item.Artist, 60));
            AppendMenu(menu, 0x800, 0, null);
        }
        AppendMenu(menu, 0, 1, player.State == PlaybackState.Playing ? "Pause" : "Play");
        AppendMenu(menu, 0, 2, "Next");
        AppendMenu(menu, 0, 3, "Previous");
        AppendMenu(menu, 0x800, 0, null);
        AppendMenu(menu, 0, 4, "Mini Player");
        AppendMenu(menu, 0, 5, "Show Groovelight");
        AppendMenu(menu, 0x800, 0, null);
        AppendMenu(menu, 0, 6, "Exit");
        GetCursorPos(out var point);
        SetForegroundWindow(window);
        var chosen = TrackPopupMenu(menu, 0x0100 | 0x0020, point.X, point.Y, 0, window, IntPtr.Zero);
        DestroyMenu(menu);
        Model.Queue.TryEnqueue(() =>
        {
            switch (chosen)
            {
                case 1: player.TogglePlayPause(); break;
                case 2: player.Next(); break;
                case 3: player.Previous(); break;
                case 4: MiniPlayerWindow.Show(); break;
                case 5: MainWindow.Current.BringToFront(); break;
                case 6: Microsoft.UI.Xaml.Application.Current.Exit(); break;
            }
        });
    }

    // MARK: Thumbnail buttons

    private void AddThumbButtons()
    {
        try
        {
            taskbar ??= (ITaskbarList3)new TaskbarList();
            taskbar.HrInit();
            var size = GetSystemMetrics(11) > 0 ? Math.Max(16, GetSystemMetrics(49)) : 16;
            buttonIcons[0] = GlyphIcon("", size);
            buttonIcons[1] = GlyphIcon(Model.Player.State == PlaybackState.Playing ? "" : "", size);
            buttonIcons[2] = GlyphIcon("", size);
            var buttons = Buttons();
            taskbar.ThumbBarAddButtons(window, (uint)buttons.Length, buttons);
            buttonsAdded = true;
        }
        catch (Exception error) when (error is COMException or InvalidCastException)
        {
            taskbar = null;
        }
    }

    private ThumbButton[] Buttons()
    {
        var playing = Model.Player.State == PlaybackState.Playing;
        return
        [
            new ThumbButton { dwMask = 0x2 | 0x4 | 0x8, iId = CommandPrevious, hIcon = buttonIcons[0], szTip = "Previous", dwFlags = 0 },
            new ThumbButton { dwMask = 0x2 | 0x4 | 0x8, iId = CommandPlay, hIcon = buttonIcons[1], szTip = playing ? "Pause" : "Play", dwFlags = 0 },
            new ThumbButton { dwMask = 0x2 | 0x4 | 0x8, iId = CommandNext, hIcon = buttonIcons[2], szTip = "Next", dwFlags = 0 },
        ];
    }

    private PlaybackState? shownState;

    private void UpdateThumbButtons()
    {
        if (!buttonsAdded || taskbar is null || shownState == Model.Player.State) return;
        shownState = Model.Player.State;
        var size = Math.Max(16, GetSystemMetrics(49));
        if (buttonIcons[1] != IntPtr.Zero) DestroyIcon(buttonIcons[1]);
        buttonIcons[1] = GlyphIcon(Model.Player.State == PlaybackState.Playing ? "" : "", size);
        var buttons = Buttons();
        try { taskbar.ThumbBarUpdateButtons(window, (uint)buttons.Length, buttons); }
        catch (COMException) { }
    }

    /// <summary>A Segoe Fluent Icons glyph as a white icon (thumbnail buttons sit on the dark taskbar preview).</summary>
    internal static IntPtr GlyphIcon(string glyph, int size)
    {
        using var bitmap = new SKBitmap(new SKImageInfo(size, size, SKColorType.Bgra8888, SKAlphaType.Premul));
        using (var canvas = new SKCanvas(bitmap))
        {
            canvas.Clear(SKColors.Transparent);
            using var typeface = SKTypeface.FromFamilyName("Segoe Fluent Icons") ?? SKTypeface.FromFamilyName("Segoe MDL2 Assets");
            using var font = new SKFont(typeface, size * 0.8f);
            using var paint = new SKPaint { Color = SKColors.White, IsAntialias = true };
            var width = font.MeasureText(glyph);
            canvas.DrawText(glyph, (size - width) / 2, size * 0.83f, SKTextAlign.Left, font, paint);
        }
        var header = new BitmapInfoHeader { biSize = Marshal.SizeOf<BitmapInfoHeader>(), biWidth = size, biHeight = -size, biPlanes = 1, biBitCount = 32 };
        var color = CreateDIBSection(IntPtr.Zero, ref header, 0, out var bits, IntPtr.Zero, 0);
        Marshal.Copy(bitmap.Bytes, 0, bits, size * size * 4);
        var mask = CreateBitmap(size, size, 1, 1, IntPtr.Zero);
        var info = new IconInfo { fIcon = true, hbmColor = color, hbmMask = mask };
        var icon = CreateIconIndirect(ref info);
        DeleteObject(color);
        DeleteObject(mask);
        return icon;
    }

    // MARK: Messages

    private IntPtr WindowProcedure(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, IntPtr id, IntPtr data)
    {
        if (message == TrayMessage)
        {
            switch ((int)lParam)
            {
                case 0x0202: // left button up: the mini player by the icon
                    GetCursorPos(out var point);
                    Model.Queue.TryEnqueue(() => MiniPlayerWindow.Toggle(new Windows.Graphics.PointInt32(point.X, point.Y)));
                    break;
                case 0x0205: // right button up
                    ShowTrayMenu();
                    break;
            }
            return IntPtr.Zero;
        }
        if (message == taskbarCreated)
        {
            // Explorer restarted: the icon must be added again.
            AddTrayIcon();
        }
        else if (message == buttonCreated)
        {
            AddThumbButtons();
        }
        else if (message == 0x0111 && ((long)wParam >> 16 & 0xFFFF) == 0x1800)
        {
            var player = Model.Player;
            switch ((int)wParam & 0xFFFF)
            {
                case CommandPrevious: Model.Queue.TryEnqueue(player.Previous); break;
                case CommandPlay: Model.Queue.TryEnqueue(player.TogglePlayPause); break;
                case CommandNext: Model.Queue.TryEnqueue(player.Next); break;
            }
            return IntPtr.Zero;
        }
        return DefSubclassProc(hwnd, message, wParam, lParam);
    }

    private void OnPlayerChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (args.PropertyName == nameof(PlaybackController.Current)) UpdateTray();
        else if (args.PropertyName == nameof(PlaybackController.State)) UpdateThumbButtons();
    }

    public void Dispose()
    {
        Model.Player.PropertyChanged -= OnPlayerChanged;
        var data = TrayData();
        Shell_NotifyIcon(2, ref data);
        RemoveWindowSubclass(window, procedure, 1);
        if (trayIcon != IntPtr.Zero) DestroyIcon(trayIcon);
        foreach (var icon in buttonIcons) if (icon != IntPtr.Zero) DestroyIcon(icon);
    }

    // MARK: Win32

    private delegate IntPtr SubclassProcedure(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, IntPtr id, IntPtr data);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public int cbSize;
        public IntPtr hWnd;
        public uint uID;
        public uint uFlags;
        public int uCallbackMessage;
        public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public uint dwState;
        public uint dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public uint uVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public uint dwInfoFlags;
        public Guid guidItem;
        public IntPtr hBalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ThumbButton
    {
        public uint dwMask;
        public uint iId;
        public uint iBitmap;
        public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szTip;
        public uint dwFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct BitmapInfoHeader
    {
        public int biSize, biWidth, biHeight;
        public short biPlanes, biBitCount;
        public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IconInfo
    {
        [MarshalAs(UnmanagedType.Bool)] public bool fIcon;
        public int xHotspot, yHotspot;
        public IntPtr hbmMask, hbmColor;
    }

    [ComImport, Guid("56FDF344-FD6D-11d0-958A-006097C9A090"), ClassInterface(ClassInterfaceType.None)]
    private class TaskbarList;

    [ComImport, Guid("ea1afb91-9e28-4b86-90e9-9e9f8a5eefaf"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ITaskbarList3
    {
        void HrInit();
        void AddTab(IntPtr hwnd);
        void DeleteTab(IntPtr hwnd);
        void ActivateTab(IntPtr hwnd);
        void SetActiveAlt(IntPtr hwnd);
        void MarkFullscreenWindow(IntPtr hwnd, [MarshalAs(UnmanagedType.Bool)] bool fullscreen);
        void SetProgressValue(IntPtr hwnd, ulong completed, ulong total);
        void SetProgressState(IntPtr hwnd, int flags);
        void RegisterTab(IntPtr tab, IntPtr window);
        void UnregisterTab(IntPtr tab);
        void SetTabOrder(IntPtr tab, IntPtr insertBefore);
        void SetTabActive(IntPtr tab, IntPtr window, uint reserved);
        void ThumbBarAddButtons(IntPtr hwnd, uint count, [MarshalAs(UnmanagedType.LPArray)] ThumbButton[] buttons);
        void ThumbBarUpdateButtons(IntPtr hwnd, uint count, [MarshalAs(UnmanagedType.LPArray)] ThumbButton[] buttons);
    }

    [DllImport("comctl32.dll")] private static extern bool SetWindowSubclass(IntPtr hwnd, SubclassProcedure procedure, UIntPtr id, IntPtr data);
    private static bool SetWindowSubclass(IntPtr hwnd, SubclassProcedure procedure, int id, IntPtr data) => SetWindowSubclass(hwnd, procedure, (UIntPtr)id, data);
    [DllImport("comctl32.dll")] private static extern bool RemoveWindowSubclass(IntPtr hwnd, SubclassProcedure procedure, UIntPtr id);
    private static bool RemoveWindowSubclass(IntPtr hwnd, SubclassProcedure procedure, int id) => RemoveWindowSubclass(hwnd, procedure, (UIntPtr)id);
    [DllImport("comctl32.dll")] private static extern IntPtr DefSubclassProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterWindowMessage(string name);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] private static extern bool Shell_NotifyIcon(uint message, ref NotifyIconData data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr LoadImage(IntPtr instance, string name, uint type, int width, int height, uint flags);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] private static extern IntPtr CreatePopupMenu();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool AppendMenu(IntPtr menu, uint flags, uint id, string? text);
    [DllImport("user32.dll")] private static extern int TrackPopupMenu(IntPtr menu, uint flags, int x, int y, int reserved, IntPtr hwnd, IntPtr rect);
    [DllImport("user32.dll")] private static extern bool DestroyMenu(IntPtr menu);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr icon);
    [DllImport("user32.dll")] private static extern IntPtr CreateIconIndirect(ref IconInfo info);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateDIBSection(IntPtr dc, ref BitmapInfoHeader header, uint usage, out IntPtr bits, IntPtr section, uint offset);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateBitmap(int width, int height, uint planes, uint bitsPerPixel, IntPtr bits);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr handle);
}

/// <summary>
/// The jump list's tasks (the Mac's Dock menu): Play/Pause, Next, Previous and the mini player, each starting
/// Groovelight with <c>--command</c>, which the running app receives.
/// </summary>
public static class JumpList
{
    private static readonly (string Title, string Command)[] Tasks =
        [("Play / Pause", "play-pause"), ("Next", "next"), ("Previous", "previous"), ("Mini Player", "mini-player")];

    public static void Update()
    {
        try
        {
            var list = (ICustomDestinationList)new DestinationList();
            list.BeginList(out _, typeof(IObjectArray).GUID, out _);
            var collection = (IObjectCollection)new EnumerableObjectCollection();
            var exe = Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "Groovelight.exe");
            foreach (var (title, command) in Tasks)
            {
                var link = (IShellLinkW)new ShellLink();
                link.SetPath(exe);
                link.SetArguments($"--command {command}");
                link.SetIconLocation(exe, 0);
                var properties = (IPropertyStore)link;
                var key = new PropertyKey(new Guid("F29F85E0-4FF9-1068-AB91-08002B27B3D9"), 2);
                var value = new PropVariant(title);
                properties.SetValue(ref key, ref value);
                properties.Commit();
                value.Clear();
                collection.AddObject(link);
            }
            list.AddUserTasks((IObjectArray)collection);
            list.CommitList();
        }
        catch (Exception error) when (error is COMException or InvalidCastException)
        {
            // No jump list (an unusual shell): the menus still have every command.
        }
    }

    /// <summary>Runs a <c>--command</c> from a jump list task.</summary>
    public static void Run(string command)
    {
        var model = AppModel.Current;
        switch (command)
        {
            case "play-pause": model.Player.TogglePlayPause(); break;
            case "next": model.Player.Next(); break;
            case "previous": model.Player.Previous(); break;
            case "mini-player": MiniPlayerWindow.Show(); break;
            default: MainWindow.Current.BringToFront(); break;
        }
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct PropertyKey(Guid format, uint id)
    {
        public Guid Format = format;
        public uint Id = id;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct PropVariant
    {
        [FieldOffset(0)] private ushort type;
        [FieldOffset(8)] private IntPtr pointer;

        public PropVariant(string text)
        {
            type = 31; // VT_LPWSTR
            pointer = Marshal.StringToCoTaskMemUni(text);
        }

        public void Clear()
        {
            if (pointer != IntPtr.Zero) Marshal.FreeCoTaskMem(pointer);
            pointer = IntPtr.Zero;
        }
    }

    [ComImport, Guid("77F10CF0-3DB5-4966-B520-B7C54FD35ED6"), ClassInterface(ClassInterfaceType.None)]
    private class DestinationList;

    [ComImport, Guid("2D3468C1-36A7-43B6-AC24-D3F02FD9607A"), ClassInterface(ClassInterfaceType.None)]
    private class EnumerableObjectCollection;

    [ComImport, Guid("00021401-0000-0000-C000-000000000046"), ClassInterface(ClassInterfaceType.None)]
    private class ShellLink;

    [ComImport, Guid("6332DEBF-87B5-4670-90C0-5E57B408A49E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ICustomDestinationList
    {
        void SetAppID([MarshalAs(UnmanagedType.LPWStr)] string id);
        void BeginList(out uint minSlots, [In] in Guid riid, [MarshalAs(UnmanagedType.Interface)] out object removed);
        void AppendCategory([MarshalAs(UnmanagedType.LPWStr)] string category, IObjectArray array);
        void AppendKnownCategory(int category);
        void AddUserTasks(IObjectArray array);
        void CommitList();
        void GetRemovedDestinations([In] in Guid riid, [MarshalAs(UnmanagedType.Interface)] out object removed);
        void DeleteList([MarshalAs(UnmanagedType.LPWStr)] string id);
        void AbortList();
    }

    [ComImport, Guid("92CA9DCD-5622-4BBA-A805-5E9F541BD8C9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IObjectArray
    {
        void GetCount(out uint count);
        void GetAt(uint index, [In] in Guid riid, [MarshalAs(UnmanagedType.Interface)] out object item);
    }

    [ComImport, Guid("5632B1A4-E38A-400A-928A-D4CD63230295"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IObjectCollection
    {
        void GetCount(out uint count);
        void GetAt(uint index, [In] in Guid riid, [MarshalAs(UnmanagedType.Interface)] out object item);
        void AddObject([MarshalAs(UnmanagedType.Interface)] object item);
        void AddFromArray(IObjectArray array);
        void RemoveObjectAt(uint index);
        void Clear();
    }

    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellLinkW
    {
        void GetPath(IntPtr file, int size, IntPtr data, uint flags);
        void GetIDList(out IntPtr list);
        void SetIDList(IntPtr list);
        void GetDescription(IntPtr name, int size);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetWorkingDirectory(IntPtr directory, int size);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string directory);
        void GetArguments(IntPtr arguments, int size);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string arguments);
        void GetHotkey(out short hotkey);
        void SetHotkey(short hotkey);
        void GetShowCmd(out int command);
        void SetShowCmd(int command);
        void GetIconLocation(IntPtr path, int size, out int icon);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int icon);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
        void Resolve(IntPtr hwnd, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string file);
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore
    {
        void GetCount(out uint count);
        void GetAt(uint index, out PropertyKey key);
        void GetValue(ref PropertyKey key, out PropVariant value);
        void SetValue(ref PropertyKey key, ref PropVariant value);
        void Commit();
    }
}
