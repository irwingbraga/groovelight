using System.Globalization;
using Groovelight.Audio;
using Groovelight.Core;

namespace Groovelight.Model;

/// <summary>Playback preferences (Settings, Playback and the Controls menu), saved under "player." so backups include them.</summary>
public static class PlaybackPrefs
{
    public const string Crossfade = "player.crossfade";
    public const string CrossfadeSkipsAlbum = "player.crossfadeSkipsAlbum";
    public const string Normalization = "player.normalization";
    public const string Rate = "player.rate";
    public const string BitPerfect = "player.bitPerfect";
    /// <summary>The Mac's separate exclusive access; on Windows bit-perfect always takes the device exclusively.</summary>
    public const string Exclusive = "player.exclusive";
    /// <summary>The output device chosen in Settings (its endpoint id), or none for the system's default.</summary>
    public const string Device = "player.device";

    public static readonly IReadOnlyList<float> Speeds = [0.5f, 0.75f, 1, 1.25f, 1.5f, 1.75f, 2];

    public static void Register(Preferences preferences) => preferences.Register(new Dictionary<string, object?>
    {
        [Crossfade] = 0.0, [CrossfadeSkipsAlbum] = true, [Normalization] = "off", [Rate] = 1.0, [BitPerfect] = false, [Exclusive] = false,
    });

    /// <summary>Puts the saved preferences on the player.</summary>
    public static void Apply(Preferences preferences, PlaybackController player)
    {
        player.CrossfadeDuration = preferences.Double(Crossfade);
        player.CrossfadeSkipsSameAlbum = preferences.Bool(CrossfadeSkipsAlbum, true);
        player.Normalization = ParseNormalization(preferences.String(Normalization));
        player.Rate = (float)preferences.Double(Rate, 1);
        player.BitPerfect = preferences.Bool(BitPerfect);
    }

    /// <summary>The Mac's raw values: "off", "track", "album".</summary>
    public static VolumeNormalization ParseNormalization(string? value) => value switch
    {
        "track" => VolumeNormalization.Track,
        "album" => VolumeNormalization.Album,
        _ => VolumeNormalization.Off,
    };

    public static string RawValue(VolumeNormalization value) => value switch
    {
        VolumeNormalization.Track => "track",
        VolumeNormalization.Album => "album",
        _ => "off",
    };

    public static string SpeedLabel(float rate) => rate == 1 ? "Normal" : rate.ToString("0.##", CultureInfo.CurrentCulture) + "×";
}
