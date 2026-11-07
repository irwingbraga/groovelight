using System.Globalization;
using System.Text;

namespace Groovelight.Core;

/// <summary>Text helpers shared by the library, matching the Mac's string handling.</summary>
public static class Text
{
    /// <summary>The value trimmed, or null when it is null or only whitespace.</summary>
    public static string? NonEmpty(this string? value)
    {
        var trimmed = value?.Trim();
        return string.IsNullOrEmpty(trimmed) ? null : trimmed;
    }

    /// <summary>Case, diacritic and width insensitive form (Swift's <c>folding(options:)</c> with those three).</summary>
    public static string Fold(string value)
    {
        var decomposed = value.Normalize(NormalizationForm.FormKD);
        var builder = new StringBuilder(decomposed.Length);
        foreach (var character in decomposed)
        {
            if (CharUnicodeInfo.GetUnicodeCategory(character) != UnicodeCategory.NonSpacingMark) builder.Append(character);
        }
        return builder.ToString().Normalize(NormalizationForm.FormC).ToLowerInvariant();
    }

    /// <summary>Case, diacritic and width insensitive key, with a leading "The " removed (album grouping).</summary>
    public static string NormalizedKey(this string value)
    {
        var folded = Fold(value).Trim();
        return folded.StartsWith("the ", StringComparison.Ordinal) ? folded[4..] : folded;
    }
}
