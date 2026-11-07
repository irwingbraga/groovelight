using System.Globalization;

namespace Groovelight.Core;

/// <summary>
/// The app's settings, the counterpart of the Mac's <c>UserDefaults</c>: the same keys and property list values, so
/// the preferences in a backup move between a Mac and a PC. Kept in <c>Preferences.plist</c> in the data folder and
/// saved shortly after each change. Thread safe.
/// </summary>
public sealed class Preferences
{
    private readonly string? path;
    private readonly Dictionary<string, object?> values;
    private readonly Dictionary<string, object?> defaults = [];
    private readonly Lock gate = new();
    private Timer? saveTimer;

    /// <summary>A setting changed (its key), on the thread that changed it.</summary>
    public event Action<string>? Changed;

    /// <summary>Preferences kept at <paramref name="path"/> (none: in memory only, for tests).</summary>
    public Preferences(string? path)
    {
        this.path = path;
        values = [];
        if (path is null || !File.Exists(path)) return;
        try
        {
            if (PropertyList.Parse(File.ReadAllBytes(path)) is Dictionary<string, object?> saved) values = saved;
        }
        catch (Exception)
        {
            // A damaged file starts over from the defaults rather than stopping the app.
        }
    }

    /// <summary>Values used while a key has none of its own (UserDefaults' registered defaults).</summary>
    public void Register(IReadOnlyDictionary<string, object?> registered)
    {
        lock (gate) foreach (var (key, value) in registered) defaults[key] = value;
    }

    public object? this[string key]
    {
        get { lock (gate) return values.TryGetValue(key, out var value) ? value : defaults.GetValueOrDefault(key); }
        set => Set(key, value);
    }

    public bool Contains(string key)
    {
        lock (gate) return values.ContainsKey(key);
    }

    public void Set(string key, object? value)
    {
        lock (gate)
        {
            if (value is null) { if (!values.Remove(key)) return; }
            else
            {
                value = Normalize(value);
                if (values.TryGetValue(key, out var old) && Equals(old, value)) return;
                values[key] = value;
            }
            ScheduleSave();
        }
        Changed?.Invoke(key);
    }

    public void Remove(string key) => Set(key, null);

    public bool Bool(string key, bool fallback = false) => this[key] switch
    {
        bool value => value,
        long number => number != 0,
        double number => number != 0,
        string text => text is "1" or "YES" or "true",
        _ => fallback,
    };

    public double Double(string key, double fallback = 0) => this[key] switch
    {
        double value => value,
        long number => number,
        bool flag => flag ? 1 : 0,
        string text when double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed) => parsed,
        _ => fallback,
    };

    public long Integer(string key, long fallback = 0) => this[key] switch
    {
        long value => value,
        double number => (long)number,
        bool flag => flag ? 1 : 0,
        string text when long.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed) => parsed,
        _ => fallback,
    };

    public string? String(string key) => this[key] switch
    {
        string value => value,
        null => null,
        IConvertible value => value.ToString(CultureInfo.InvariantCulture),
        _ => null,
    };

    public byte[]? Data(string key) => this[key] as byte[];

    public DateTime? Date(string key) => this[key] as DateTime?;

    public List<string> Strings(string key) => this[key] is List<object?> list ? list.OfType<string>().ToList() : [];

    /// <summary>Every stored value whose key starts with one of <paramref name="prefixes"/> (for backups).</summary>
    public Dictionary<string, object?> Export(IReadOnlyList<string> prefixes)
    {
        lock (gate)
        {
            return values.Where(pair => prefixes.Any(prefix => pair.Key.StartsWith(prefix, StringComparison.Ordinal)))
                         .ToDictionary(pair => pair.Key, pair => pair.Value);
        }
    }

    /// <summary>Replaces the values under <paramref name="prefixes"/> with <paramref name="imported"/> (a restore).</summary>
    public void Import(IReadOnlyDictionary<string, object?> imported, IReadOnlyList<string> prefixes)
    {
        List<string> changed;
        lock (gate)
        {
            changed = values.Keys.Where(key => prefixes.Any(prefix => key.StartsWith(prefix, StringComparison.Ordinal))).ToList();
            foreach (var key in changed) values.Remove(key);
            foreach (var (key, value) in imported)
            {
                if (value is null || !prefixes.Any(prefix => key.StartsWith(prefix, StringComparison.Ordinal))) continue;
                values[key] = value;
                changed.Add(key);
            }
            ScheduleSave();
        }
        foreach (var key in changed.Distinct()) Changed?.Invoke(key);
    }

    /// <summary>Writes pending changes now (when the app quits).</summary>
    public void Flush()
    {
        lock (gate)
        {
            saveTimer?.Dispose();
            saveTimer = null;
            SaveLocked();
        }
    }

    private static object Normalize(object value) => value switch
    {
        int number => (long)number,
        float number => (double)number,
        Enum item => item.ToString(),
        _ => value,
    };

    private void ScheduleSave()
    {
        if (path is null) return;
        saveTimer ??= new Timer(_ =>
        {
            lock (gate)
            {
                saveTimer?.Dispose();
                saveTimer = null;
                SaveLocked();
            }
        }, null, TimeSpan.FromMilliseconds(500), Timeout.InfiniteTimeSpan);
    }

    private void SaveLocked()
    {
        if (path is null) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
            var temporary = path + ".tmp";
            File.WriteAllBytes(temporary, PropertyList.Write(values));
            File.Move(temporary, path, overwrite: true);
        }
        catch (IOException)
        {
            // Saved again with the next change.
        }
        catch (UnauthorizedAccessException)
        {
        }
    }
}
