using SharpCompress.Archives;
using SharpCompress.Common;
using SharpCompress.Readers;

namespace Groovelight.Core.Library;

/// <summary>
/// Archives of music (zip, 7z, rar, tar and its compressed forms), extracted before an import (the Mac uses the
/// system's bsdtar; Windows has SharpCompress). Entries that would land outside the folder and links are left out.
/// </summary>
public static class ArchiveExtractor
{
    public static readonly IReadOnlySet<string> Extensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        { "zip", "7z", "rar", "tar", "tgz", "tbz", "tbz2", "txz", "gz", "bz2", "xz" };

    public static bool IsArchive(string path) => Extensions.Contains(Path.GetExtension(path).TrimStart('.'));

    public sealed class ExtractException(string message) : Exception(message)
    {
        public static ExtractException Encrypted(string name) => new($"“{name}” is protected with a password, which Groovelight cannot open.");
        public static ExtractException Failed(string name, string reason) => new($"Could not extract “{name}”: {reason}");
    }

    /// <summary>Extracts <paramref name="archive"/> into <paramref name="folder"/> (created when missing).</summary>
    public static void Extract(string archive, string folder)
    {
        Directory.CreateDirectory(folder);
        var name = Path.GetFileName(archive);
        var root = Path.GetFullPath(folder).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        try
        {
            using var stream = File.OpenRead(archive);
            if (TryOpenArchive(stream) is { } opened)
            {
                using (opened)
                {
                    foreach (var entry in opened.Entries)
                    {
                        if (entry.IsEncrypted) throw ExtractException.Encrypted(name);
                        if (entry.IsDirectory || entry.LinkTarget is not null || entry.Key is null) continue;
                        using var input = entry.OpenEntryStream();
                        Write(input, entry.Key, root);
                    }
                }
                return;
            }
            // Compressed tars and single compressed files read forward only.
            stream.Position = 0;
            using var reader = ReaderFactory.OpenReader(stream);
            while (reader.MoveToNextEntry())
            {
                var entry = reader.Entry;
                if (entry.IsEncrypted) throw ExtractException.Encrypted(name);
                if (entry.IsDirectory || entry.LinkTarget is not null) continue;
                var key = entry.Key ?? Path.GetFileNameWithoutExtension(archive);
                using var input = reader.OpenEntryStream();
                Write(input, key, root);
            }
        }
        catch (ExtractException)
        {
            throw;
        }
        catch (CryptographicException)
        {
            throw ExtractException.Encrypted(name);
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            if (error.Message.Contains("password", StringComparison.OrdinalIgnoreCase) || error.Message.Contains("encrypt", StringComparison.OrdinalIgnoreCase))
                throw ExtractException.Encrypted(name);
            throw ExtractException.Failed(name, error.Message);
        }
    }

    private static IArchive? TryOpenArchive(Stream stream)
    {
        try
        {
            return ArchiveFactory.OpenArchive(stream);
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            return null;
        }
    }

    /// <summary>Writes an entry under <paramref name="root"/>; entries reaching outside it (with "..") are left out.</summary>
    private static void Write(Stream input, string key, string root)
    {
        var relative = key.Replace('/', Path.DirectorySeparatorChar).Replace('\\', Path.DirectorySeparatorChar).TrimStart(Path.DirectorySeparatorChar);
        if (relative.Length == 0 || Path.IsPathRooted(relative)) return;
        var destination = Path.GetFullPath(Path.Combine(root, relative));
        if (!destination.StartsWith(root, StringComparison.OrdinalIgnoreCase)) return;
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        using var output = File.Create(destination);
        input.CopyTo(output);
    }
}
