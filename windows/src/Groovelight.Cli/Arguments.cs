using System.Globalization;

namespace Groovelight.Cli;

/// <summary>A command's arguments: <c>--flag</c>, <c>--option value</c> (or <c>--option=value</c>), <c>--ids 1 2 3</c> and the rest in order.</summary>
internal sealed class Arguments
{
    private readonly HashSet<string> flags = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> options = new(StringComparer.Ordinal);
    private readonly Dictionary<string, List<string>> lists = new(StringComparer.Ordinal);

    public List<string> Positional { get; } = [];

    /// <summary>Reads <paramref name="args"/> with the names a command takes; an unknown name is a usage error.</summary>
    public Arguments(IEnumerable<string> args, IReadOnlyCollection<string> flagNames, IReadOnlyCollection<string> optionNames, IReadOnlyCollection<string>? listNames = null)
    {
        listNames ??= [];
        var queue = new Queue<string>(args);
        var onlyPositional = false;
        while (queue.TryDequeue(out var arg))
        {
            if (onlyPositional || !arg.StartsWith("--", StringComparison.Ordinal) || arg == "--")
            {
                if (arg == "--" && !onlyPositional) onlyPositional = true;
                else Positional.Add(arg);
                continue;
            }
            var name = arg[2..];
            string? inline = null;
            if (name.IndexOf('=') is var equals and > 0)
            {
                inline = name[(equals + 1)..];
                name = name[..equals];
            }
            if (flagNames.Contains(name) && inline is null)
            {
                flags.Add(name);
            }
            else if (optionNames.Contains(name))
            {
                options[name] = inline ?? (queue.TryDequeue(out var value) ? value : throw new UsageException($"--{name} needs a value."));
            }
            else if (listNames.Contains(name))
            {
                var values = lists.TryGetValue(name, out var existing) ? existing : lists[name] = [];
                if (inline is not null) values.AddRange(inline.Split(',', StringSplitOptions.RemoveEmptyEntries));
                while (queue.TryPeek(out var next) && !next.StartsWith("--", StringComparison.Ordinal)) values.Add(queue.Dequeue());
                if (values.Count == 0) throw new UsageException($"--{name} needs at least one value.");
            }
            else
            {
                throw new UsageException($"Unknown option --{name}.");
            }
        }
    }

    public bool Flag(string name) => flags.Contains(name);

    public string? Option(string name) => options.GetValueOrDefault(name);

    public int Integer(string name, int fallback)
    {
        if (Option(name) is not { } text) return fallback;
        return int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var value) ? value : throw new UsageException($"--{name} takes a number.");
    }

    public List<long> Ids(string name) => lists.TryGetValue(name, out var values)
        ? values.Select(value => long.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var id) ? id : throw new UsageException($"--{name} takes song ids (numbers): {value}")).ToList()
        : [];
}

/// <summary>A mistake in the command: shown with a hint to --help, exit code 64.</summary>
internal sealed class UsageException(string message) : Exception(message);
