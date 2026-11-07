using System.Runtime.InteropServices;
using Groovelight.Core.Library;

namespace Groovelight.Support;

/// <summary>
/// The Windows Recycle Bin for archives moved there after an import (the Mac's Trash): sent with the shell's own
/// operation, and put back by finding the item by its original place and restoring it, as Explorer's Restore does.
/// </summary>
public sealed class WindowsRecycleBin : IRecycleBin
{
    public string? Recycle(string path)
    {
        var operation = new FileOperation
        {
            wFunc = 3, // FO_DELETE
            pFrom = Path.GetFullPath(path) + "\0\0",
            fFlags = 0x40 | 0x10 | 0x400 | 0x4, // FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT
        };
        if (SHFileOperation(ref operation) != 0 || operation.fAnyOperationsAborted || File.Exists(path)) return null;
        // Where it is kept is not told; Restore finds it by its original place.
        return path;
    }

    public bool Restore(string originalPath, string? keptAt)
    {
        try
        {
            var shellType = Type.GetTypeFromProgID("Shell.Application");
            if (shellType is null) return false;
            dynamic shell = Activator.CreateInstance(shellType)!;
            dynamic bin = shell.NameSpace(10);
            var folder = Path.GetDirectoryName(Path.GetFullPath(originalPath)) ?? "";
            var name = Path.GetFileName(originalPath);
            foreach (var item in bin.Items())
            {
                // Column 1 is "Original Location".
                string location = bin.GetDetailsOf(item, 1);
                string itemName = item.Name;
                if (!string.Equals(location, folder, StringComparison.OrdinalIgnoreCase)) continue;
                if (!string.Equals(itemName, name, StringComparison.OrdinalIgnoreCase)
                    && !string.Equals(itemName, Path.GetFileNameWithoutExtension(name), StringComparison.OrdinalIgnoreCase)) continue;
                // The item's own path in the bin ($R...): moved back to where it was.
                string kept = item.Path;
                Directory.CreateDirectory(folder);
                File.Move(kept, originalPath);
                return true;
            }
        }
        catch (Exception error) when (error is COMException or IOException or UnauthorizedAccessException or Microsoft.CSharp.RuntimeBinder.RuntimeBinderException)
        {
        }
        return false;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct FileOperation
    {
        public IntPtr hwnd;
        public uint wFunc;
        public string pFrom;
        public string? pTo;
        public ushort fFlags;
        [MarshalAs(UnmanagedType.Bool)] public bool fAnyOperationsAborted;
        public IntPtr hNameMappings;
        public string? lpszProgressTitle;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHFileOperation(ref FileOperation operation);
}
