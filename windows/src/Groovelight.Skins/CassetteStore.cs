using System.IO.Compression;

namespace Groovelight.Skins;

/// <summary>
/// The user's cassettes, beside the built-in ones (the Mac's CassetteStore): a folder for each (named by its id) holding
/// <c>cassette.json</c> and its pictures. A design is shared as a zip of that folder (as Android shares it: it opens on
/// the Mac and the iPhone too), and imported from one, from the folder itself or from its <c>cassette.json</c>.
/// </summary>
public sealed class CassetteStore
{
    public const string FileName = "cassette.json";

    public enum Picture { Shell, Label }

    public string Folder { get; }
    public IReadOnlyList<CassetteDesign> Custom { get; private set; } = [];
    /// <summary>Bumped when a design's pictures change, so what shows them loads them again.</summary>
    public int Revision { get; private set; }
    /// <summary>The designs or their pictures changed.</summary>
    public event Action? Changed;

    public CassetteStore(string folder)
    {
        Folder = folder;
        Reload();
    }

    public IEnumerable<CassetteDesign> All => CassetteDesign.BuiltIn.Concat(Custom);

    /// <summary>The design with that id, or the first built-in one (a deleted design's choice falls back to it).</summary>
    public CassetteDesign Design(Guid? id) => All.FirstOrDefault(design => design.Id == id) ?? CassetteDesign.BuiltIn[0];

    public CassetteDesign Design(string? id) => Design(Guid.TryParse(id, out var guid) ? guid : null);

    public void Reload()
    {
        var designs = new List<CassetteDesign>();
        if (Directory.Exists(Folder))
        {
            foreach (var directory in Directory.EnumerateDirectories(Folder))
            {
                try { designs.Add(Read(Path.Combine(directory, FileName))); }
                catch (Exception error) when (error is IOException or FormatException or UnauthorizedAccessException) { }
            }
        }
        Custom = designs.OrderBy(design => design.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
        Changed?.Invoke();
    }

    public string FolderOf(CassetteDesign design) => Path.Combine(Folder, design.Id.ToString().ToUpperInvariant());

    /// <summary>Where a design's picture is (null for none, or for a built-in design, which has none).</summary>
    public string? PathOf(Picture picture, CassetteDesign design)
    {
        var name = picture == Picture.Shell ? design.ShellImage : design.LabelImage;
        if (name is null || design.IsBuiltIn) return null;
        // Only a file in the design's own folder, whatever a hand-written file says.
        var path = Path.Combine(FolderOf(design), Path.GetFileName(name.Replace('\\', '/').Split('/').Last()));
        return File.Exists(path) ? path : null;
    }

    public void Save(CassetteDesign design)
    {
        if (design.IsBuiltIn) throw new InvalidOperationException("The built-in cassettes cannot be changed. Duplicate one to make your own.");
        var directory = FolderOf(design);
        Directory.CreateDirectory(directory);
        Write(design, Path.Combine(directory, FileName));
        Reload();
    }

    /// <summary>A copy to change: built-in designs are changed this way.</summary>
    public CassetteDesign Duplicate(CassetteDesign design, string? name = null)
    {
        var copy = design.Copy();
        copy.Id = Guid.NewGuid();
        copy.Name = name ?? $"{design.Name} Copy";
        var directory = FolderOf(copy);
        Directory.CreateDirectory(directory);
        foreach (var picture in new[] { Picture.Shell, Picture.Label })
        {
            if (PathOf(picture, design) is { } source) File.Copy(source, Path.Combine(directory, Path.GetFileName(source)));
        }
        Write(copy, Path.Combine(directory, FileName));
        Reload();
        return copy;
    }

    public void Delete(CassetteDesign design)
    {
        if (design.IsBuiltIn) throw new InvalidOperationException("The built-in cassettes cannot be changed. Duplicate one to make your own.");
        var directory = FolderOf(design);
        if (Directory.Exists(directory)) Directory.Delete(directory, true);
        Reload();
    }

    /// <summary>Sets (or with null, removes) the shell's or the label's picture, copied into the design's folder.</summary>
    public CassetteDesign SetPicture(Picture picture, string? source, CassetteDesign design)
    {
        if (design.IsBuiltIn) throw new InvalidOperationException("The built-in cassettes cannot be changed. Duplicate one to make your own.");
        design = design.Copy();
        var directory = FolderOf(design);
        Directory.CreateDirectory(directory);
        if (PathOf(picture, design) is { } old) File.Delete(old);
        string? name = null;
        if (source is not null)
        {
            var extension = Path.GetExtension(source) is { Length: > 1 } ext ? ext[1..].ToLowerInvariant() : "png";
            // A new name each time, so nothing holds on to the old picture.
            name = $"{(picture == Picture.Shell ? "shell" : "label")}-{Guid.NewGuid().ToString("N")[..8].ToUpperInvariant()}.{extension}";
            File.Copy(source, Path.Combine(directory, name));
        }
        if (picture == Picture.Shell) design.ShellImage = name;
        else design.LabelImage = name;
        Save(design);
        Revision++;
        Changed?.Invoke();
        return design;
    }

    /// <summary>
    /// Adds a design from a zip of its folder (a shared <c>.cassette</c>, its files at the top or in one folder), from the
    /// folder, or from its <c>cassette.json</c> (its pictures beside it). It keeps its id unless one here has it already,
    /// then it is added as a copy.
    /// </summary>
    public CassetteDesign Import(string path)
    {
        var files = new Dictionary<string, byte[]>(StringComparer.OrdinalIgnoreCase);
        if (Directory.Exists(path))
        {
            foreach (var file in Directory.EnumerateFiles(path)) files[Path.GetFileName(file)] = File.ReadAllBytes(file);
        }
        else if (IsZip(path))
        {
            using var zip = ZipFile.OpenRead(path);
            foreach (var entry in zip.Entries)
            {
                // Only the name: nothing is written outside the design's folder, whatever the zip says.
                if (entry.FullName.EndsWith('/') || entry.FullName.Contains("__MACOSX", StringComparison.Ordinal)) continue;
                using var stream = entry.Open();
                using var memory = new MemoryStream();
                stream.CopyTo(memory);
                files[entry.Name] = memory.ToArray();
            }
        }
        else if (File.Exists(path))
        {
            var folder = Path.GetDirectoryName(path)!;
            files[FileName] = File.ReadAllBytes(path);
            var beside = CassetteDesign.Parse(System.Text.Encoding.UTF8.GetString(files[FileName]));
            foreach (var name in new[] { beside.ShellImage, beside.LabelImage }.OfType<string>())
            {
                var source = Path.Combine(folder, Path.GetFileName(name));
                if (File.Exists(source)) files[Path.GetFileName(name)] = File.ReadAllBytes(source);
            }
        }
        if (!files.TryGetValue(FileName, out var json)) throw new FormatException($"{Path.GetFileName(path)} is not a cassette: it has no {FileName}.");
        var design = CassetteDesign.Parse(System.Text.Encoding.UTF8.GetString(json));
        if (All.Any(existing => existing.Id == design.Id)) design.Id = Guid.NewGuid();
        var directory = FolderOf(design);
        Directory.CreateDirectory(directory);
        // A picture the file names but that did not come with it: drawn without it.
        string? Keep(string? name)
        {
            if (name is null) return null;
            var file = Path.GetFileName(name.Replace('\\', '/').Split('/').Last());
            if (!files.TryGetValue(file, out var bytes)) return null;
            File.WriteAllBytes(Path.Combine(directory, file), bytes);
            return file;
        }
        design.ShellImage = Keep(design.ShellImage);
        design.LabelImage = Keep(design.LabelImage);
        Write(design, Path.Combine(directory, FileName));
        Reload();
        return design;
    }

    /// <summary>The design as a zip of its <c>.cassette</c> folder ("Name.cassette/cassette.json" and its pictures).</summary>
    public void Export(CassetteDesign design, string target)
    {
        var root = SafeName(design.Name) + ".cassette/";
        if (File.Exists(target)) File.Delete(target);
        using var zip = ZipFile.Open(target, ZipArchiveMode.Create);
        using (var writer = new StreamWriter(zip.CreateEntry(root + FileName).Open())) writer.Write(design.ToJson());
        foreach (var picture in new[] { Picture.Shell, Picture.Label })
        {
            if (PathOf(picture, design) is { } source) zip.CreateEntryFromFile(source, root + Path.GetFileName(source));
        }
    }

    public static string SafeName(string name) => string.Join("-", name.Split(['/', ':', '\\']));

    public static CassetteDesign Read(string file) => CassetteDesign.Parse(File.ReadAllText(file));

    public static void Write(CassetteDesign design, string file)
    {
        var temporary = file + ".tmp";
        File.WriteAllText(temporary, design.ToJson());
        File.Move(temporary, file, true);
    }

    private static bool IsZip(string path)
    {
        if (!File.Exists(path)) return false;
        using var stream = File.OpenRead(path);
        Span<byte> header = stackalloc byte[2];
        return stream.Read(header) == 2 && header[0] == 0x50 && header[1] == 0x4B;
    }
}
