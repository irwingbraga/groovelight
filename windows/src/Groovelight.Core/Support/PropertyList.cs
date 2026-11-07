using System.Globalization;
using System.Xml;
using System.Xml.Linq;

namespace Groovelight.Core;

/// <summary>
/// XML property lists (Apple's format, used by Music / iTunes library exports): dictionaries, arrays, strings,
/// integers, reals, booleans, dates and data, read into and written from plain .NET values.
/// </summary>
public static class PropertyList
{
    public static object? Parse(byte[] data)
    {
        var settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Ignore, XmlResolver = null };
        using var reader = XmlReader.Create(new MemoryStream(data), settings);
        var document = XDocument.Load(reader);
        var root = document.Root?.Elements().FirstOrDefault();
        return root is null ? null : Read(root);
    }

    private static object? Read(XElement element) => element.Name.LocalName switch
    {
        "dict" => ReadDictionary(element),
        "array" => element.Elements().Select(Read).ToList(),
        "string" => element.Value,
        "integer" => long.Parse(element.Value.Trim(), CultureInfo.InvariantCulture),
        "real" => double.Parse(element.Value.Trim(), CultureInfo.InvariantCulture),
        "true" => true,
        "false" => false,
        "date" => DateTime.Parse(element.Value.Trim(), CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal),
        "data" => Convert.FromBase64String(string.Concat(element.Value.Where(character => !char.IsWhiteSpace(character)))),
        _ => null,
    };

    private static Dictionary<string, object?> ReadDictionary(XElement element)
    {
        var dictionary = new Dictionary<string, object?>();
        var children = element.Elements().ToList();
        for (var index = 0; index + 1 < children.Count; index += 2)
        {
            if (children[index].Name.LocalName == "key") dictionary[children[index].Value] = Read(children[index + 1]);
        }
        return dictionary;
    }

    public static byte[] Write(object value)
    {
        var document = new XDocument(
            new XDeclaration("1.0", "UTF-8", null),
            new XDocumentType("plist", "-//Apple//DTD PLIST 1.0//EN", "http://www.apple.com/DTDs/PropertyList-1.0.dtd", null),
            new XElement("plist", new XAttribute("version", "1.0"), Element(value)));
        using var stream = new MemoryStream();
        using (var writer = XmlWriter.Create(stream, new XmlWriterSettings { Indent = true, IndentChars = "\t", Encoding = new System.Text.UTF8Encoding(false) }))
        {
            document.Save(writer);
        }
        return stream.ToArray();
    }

    private static XElement Element(object? value) => value switch
    {
        IDictionary<string, object?> dictionary => new XElement("dict",
            dictionary.OrderBy(pair => pair.Key, StringComparer.Ordinal).SelectMany(pair => new[] { new XElement("key", pair.Key), Element(pair.Value) })),
        string text => new XElement("string", text),
        bool boolean => new XElement(boolean ? "true" : "false"),
        int or long => new XElement("integer", Convert.ToInt64(value, CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture)),
        double number => new XElement("real", number.ToString("R", CultureInfo.InvariantCulture)),
        DateTime date => new XElement("date", date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture)),
        byte[] bytes => new XElement("data", Convert.ToBase64String(bytes)),
        System.Collections.IEnumerable list => new XElement("array", list.Cast<object?>().Select(Element)),
        _ => new XElement("string", value?.ToString() ?? ""),
    };
}
