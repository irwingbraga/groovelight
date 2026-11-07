using System.Text;
using Microsoft.Data.Sqlite;

namespace Groovelight.Core.Library;

/// <summary>
/// Small helpers over Microsoft.Data.Sqlite: statements with <c>?</c> placeholders bound in order (as GRDB takes them),
/// values converted the way the Mac stores them (dates as UTC text, booleans as 0 and 1).
/// </summary>
public static class Sql
{
    public static int Execute(this SqliteConnection connection, string sql, params object?[] arguments)
    {
        using var command = Command(connection, sql, arguments);
        return command.ExecuteNonQuery();
    }

    public static T? Scalar<T>(this SqliteConnection connection, string sql, params object?[] arguments)
    {
        using var command = Command(connection, sql, arguments);
        var value = command.ExecuteScalar();
        return value is null or DBNull ? default : Convert<T>(value);
    }

    public static List<T> Query<T>(this SqliteConnection connection, string sql, Func<Row, T> map, params object?[] arguments)
    {
        using var command = Command(connection, sql, arguments);
        using var reader = command.ExecuteReader();
        var row = new Row(reader);
        var results = new List<T>();
        while (reader.Read()) results.Add(map(row));
        return results;
    }

    public static T? QueryOne<T>(this SqliteConnection connection, string sql, Func<Row, T> map, params object?[] arguments) where T : class?
    {
        using var command = Command(connection, sql, arguments);
        using var reader = command.ExecuteReader();
        return reader.Read() ? map(new Row(reader)) : null;
    }

    public static List<T> Column<T>(this SqliteConnection connection, string sql, params object?[] arguments) =>
        connection.Query(sql, row => row.Get<T>(0)!, arguments);

    public static long LastInsertRowId(this SqliteConnection connection) => connection.Scalar<long>("SELECT last_insert_rowid()");

    public static SqliteCommand Command(SqliteConnection connection, string sql, IReadOnlyList<object?> arguments)
    {
        var command = connection.CreateCommand();
        command.CommandText = Number(sql, arguments.Count);
        for (var index = 0; index < arguments.Count; index++)
            command.Parameters.AddWithValue("$p" + (index + 1), ToDatabase(arguments[index]));
        return command;
    }

    /// <summary>Rewrites the <c>?</c> placeholders outside string literals as <c>$p1</c>, <c>$p2</c>...</summary>
    private static string Number(string sql, int count)
    {
        if (count == 0) return sql;
        var builder = new StringBuilder(sql.Length + count * 3);
        var number = 0;
        char? quote = null;
        foreach (var character in sql)
        {
            if (quote is { } open)
            {
                if (character == open) quote = null;
                builder.Append(character);
            }
            else if (character is '\'' or '"')
            {
                quote = character;
                builder.Append(character);
            }
            else if (character == '?')
            {
                builder.Append("$p").Append(++number);
            }
            else
            {
                builder.Append(character);
            }
        }
        if (number != count) throw new ArgumentException($"The statement has {number} placeholders for {count} arguments: {sql}");
        return builder.ToString();
    }

    public static object ToDatabase(object? value) => value switch
    {
        null => DBNull.Value,
        bool boolean => boolean ? 1L : 0L,
        DateTime date => Dates.ToDatabase(date),
        Enum enumeration => System.Convert.ToInt64(enumeration),
        _ => value,
    };

    internal static T Convert<T>(object value)
    {
        var type = Nullable.GetUnderlyingType(typeof(T)) ?? typeof(T);
        object converted = type switch
        {
            _ when type == typeof(DateTime) => value is string text ? Dates.FromDatabase(text) : DateTime.SpecifyKind((DateTime)value, DateTimeKind.Utc),
            _ when type == typeof(bool) => System.Convert.ToInt64(value) != 0,
            _ when type == typeof(byte[]) => value is string text ? Encoding.UTF8.GetBytes(text) : value,
            _ when type == typeof(string) => value is byte[] bytes ? Encoding.UTF8.GetString(bytes) : System.Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture)!,
            _ => System.Convert.ChangeType(value, type, System.Globalization.CultureInfo.InvariantCulture),
        };
        return (T)converted;
    }
}

/// <summary>The current row of a reader, read by column name or index.</summary>
public sealed class Row(SqliteDataReader reader)
{
    private Dictionary<string, int>? ordinals;

    public int Ordinal(string name)
    {
        ordinals ??= Enumerable.Range(0, reader.FieldCount).ToDictionary(reader.GetName, index => index, StringComparer.OrdinalIgnoreCase);
        return ordinals[name];
    }

    public bool Has(string name)
    {
        ordinals ??= Enumerable.Range(0, reader.FieldCount).ToDictionary(reader.GetName, index => index, StringComparer.OrdinalIgnoreCase);
        return ordinals.ContainsKey(name);
    }

    public T? Get<T>(string name) => Get<T>(Ordinal(name));

    public T? Get<T>(int index) => reader.IsDBNull(index) ? default : Sql.Convert<T>(reader.GetValue(index));

    public T Required<T>(string name) => Get<T>(name) ?? throw new InvalidOperationException($"Column {name} is null.");
}
