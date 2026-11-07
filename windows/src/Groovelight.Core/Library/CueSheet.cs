using System.Text;

namespace Groovelight.Core.Library;

/// <summary>A CUE sheet: an album stored as one (or a few) audio files, with the track list and where each track starts.</summary>
public sealed record CueSheet
{
    public sealed record Track
    {
        public int Number { get; set; }
        public string? Title { get; set; }
        public string? Performer { get; set; }
        public string? Songwriter { get; set; }
        public string? Isrc { get; set; }
        /// <summary>INDEX 01, in seconds from the start of the file: where the track starts.</summary>
        public double Start { get; set; }
        /// <summary>INDEX 00 (start of the pregap), when present.</summary>
        public double? Pregap { get; set; }
    }

    public sealed record File(string Name, List<Track> Tracks);

    public string? Title { get; set; }
    public string? Performer { get; set; }
    public string? Songwriter { get; set; }
    public string? Genre { get; set; }
    public int? Year { get; set; }
    public int? DiscNumber { get; set; }
    public int? DiscTotal { get; set; }
    public string? Comment { get; set; }
    public List<File> Files { get; set; } = [];

    /// <summary>All tracks of all files, in order.</summary>
    public IEnumerable<Track> Tracks => Files.SelectMany(file => file.Tracks);

    static CueSheet() => Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

    /// <summary>
    /// Reads a cue sheet, guessing the text encoding (UTF-8 with or without BOM, UTF-16, else Windows-1252, which many
    /// older rips use).
    /// </summary>
    public static CueSheet? Read(string path)
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.Length >= 1_000_000) return null;
            return Parse(Decode(System.IO.File.ReadAllBytes(path)));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    internal static string Decode(byte[] data)
    {
        if (data is [0xEF, 0xBB, 0xBF, ..]) return Encoding.UTF8.GetString(data, 3, data.Length - 3);
        if (data is [0xFF, 0xFE, ..]) return Encoding.Unicode.GetString(data, 2, data.Length - 2);
        if (data is [0xFE, 0xFF, ..]) return Encoding.BigEndianUnicode.GetString(data, 2, data.Length - 2);
        try
        {
            return new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(data);
        }
        catch (DecoderFallbackException)
        {
            return Encoding.GetEncoding(1252).GetString(data);
        }
    }

    /// <summary>Parses cue sheet text; null when it has no FILE with tracks.</summary>
    public static CueSheet? Parse(string text)
    {
        var sheet = new CueSheet();
        Track? current = null;
        void FinishTrack()
        {
            if (current is not null && sheet.Files.Count > 0) sheet.Files[^1].Tracks.Add(current);
            current = null;
        }

        // A byte order mark can survive decoding (or come from an embedded sheet).
        if (text.StartsWith('﻿')) text = text[1..];
        foreach (var rawLine in text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var words = Tokenize(rawLine.Trim(' ', '\t'));
            if (words.Count == 0) continue;
            var command = words[0].ToUpperInvariant();
            var value = words.Count > 1 ? words[1] : null;
            switch (command)
            {
                case "FILE":
                    FinishTrack();
                    if (value is not null) sheet.Files.Add(new File(value, []));
                    break;
                case "TRACK":
                    FinishTrack();
                    // Only audio tracks ("TRACK 03 AUDIO").
                    if (int.TryParse(value, out var number) && (words.Count < 3 || words[2].Equals("AUDIO", StringComparison.OrdinalIgnoreCase)))
                        current = new Track { Number = number };
                    break;
                case "INDEX":
                    if (words.Count < 3 || !int.TryParse(words[1], out var index) || ParseTime(words[2]) is not { } time) continue;
                    if (current is null) continue;
                    if (index == 1) current.Start = time;
                    else if (index == 0) current.Pregap = time;
                    break;
                case "TITLE":
                    if (current is not null) current.Title = value; else sheet.Title = value;
                    break;
                case "PERFORMER":
                    if (current is not null) current.Performer = value; else sheet.Performer = value;
                    break;
                case "SONGWRITER":
                    if (current is not null) current.Songwriter = value; else sheet.Songwriter = value;
                    break;
                case "ISRC":
                    if (current is not null) current.Isrc = value;
                    break;
                case "REM":
                    if (words.Count < 3) continue;
                    var remValue = string.Join(' ', words.Skip(2));
                    switch (words[1].ToUpperInvariant())
                    {
                        case "GENRE": sheet.Genre = remValue; break;
                        case "DATE": sheet.Year = remValue.Length >= 4 && remValue[..4].All(char.IsDigit) ? int.Parse(remValue[..4]) : null; break;
                        case "DISCNUMBER": sheet.DiscNumber = int.TryParse(remValue, out var disc) ? disc : null; break;
                        case "TOTALDISCS": sheet.DiscTotal = int.TryParse(remValue, out var discs) ? discs : null; break;
                        case "COMMENT": sheet.Comment = remValue; break;
                    }
                    break;
            }
        }
        FinishTrack();
        sheet.Files.RemoveAll(file => file.Tracks.Count == 0);
        return sheet.Files.Count == 0 ? null : sheet;
    }

    /// <summary>Splits a line into words, keeping "quoted values" together.</summary>
    internal static List<string> Tokenize(string line)
    {
        var words = new List<string>();
        var current = new StringBuilder();
        var inQuotes = false;
        foreach (var character in line)
        {
            if (character == '"')
            {
                inQuotes = !inQuotes;
                if (!inQuotes) { words.Add(current.ToString()); current.Clear(); }
            }
            else if ((character == ' ' || character == '\t') && !inQuotes)
            {
                if (current.Length > 0) { words.Add(current.ToString()); current.Clear(); }
            }
            else
            {
                current.Append(character);
            }
        }
        if (current.Length > 0) words.Add(current.ToString());
        return words;
    }

    /// <summary>"mm:ss:ff" (75 frames per second) to seconds.</summary>
    internal static double? ParseTime(string text)
    {
        var parts = text.Split(':');
        if (parts.Length != 3 || !parts.All(part => int.TryParse(part, out _))) return null;
        var numbers = parts.Select(int.Parse).ToArray();
        return numbers[0] * 60 + numbers[1] + numbers[2] / 75.0;
    }

    /// <summary>
    /// Finds the audio file a FILE line refers to: the exact name, a case-insensitive match, or (rips often say ".wav"
    /// for a file later compressed to ".flac") the same name with another audio extension.
    /// </summary>
    public static string? Resolve(string name, string directory, IReadOnlySet<string> audioFiles)
    {
        var normalized = name.Replace('\\', System.IO.Path.DirectorySeparatorChar).Replace('/', System.IO.Path.DirectorySeparatorChar);
        var direct = System.IO.Path.GetFullPath(System.IO.Path.Combine(directory, normalized));
        if (audioFiles.Contains(direct)) return direct;
        var folder = System.IO.Path.GetDirectoryName(direct);
        var siblings = audioFiles.Where(path => System.IO.Path.GetDirectoryName(path) == folder).ToList();
        var exact = siblings.FirstOrDefault(path => System.IO.Path.GetFileName(path).Equals(System.IO.Path.GetFileName(direct), StringComparison.OrdinalIgnoreCase));
        if (exact is not null) return exact;
        var stem = System.IO.Path.GetFileNameWithoutExtension(direct);
        return siblings.FirstOrDefault(path => System.IO.Path.GetFileNameWithoutExtension(path).Equals(stem, StringComparison.OrdinalIgnoreCase));
    }
}
