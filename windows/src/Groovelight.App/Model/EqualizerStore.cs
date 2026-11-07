using System.Text.Json;
using Groovelight.Audio;
using Groovelight.Core;

namespace Groovelight.Model;

/// <summary>
/// The equalizer's state for the app (the Mac's EqualizerStore): the current preset, on and off, the automatic preamp
/// and the user's presets, saved under "eq." in the Mac's JSON so backups carry them.
/// </summary>
public sealed class EqualizerStore : Support.Observable
{
    private const string CurrentKey = "eq.current", EnabledKey = "eq.enabled", AutoPreampKey = "eq.autoPreamp", UserPresetsKey = "eq.userPresets";
    private readonly AppModel model;
    private EQPreset preset = EQPreset.Flat;
    private bool isEnabled;
    private bool autoPreamp = true;
    private List<EQPreset> userPresets = [];

    public EqualizerStore(AppModel model)
    {
        this.model = model;
        Reload();
    }

    private Preferences Preferences => model.Preferences;

    public EQPreset Preset
    {
        get => preset;
        set
        {
            if (!Set(ref preset, value)) return;
            model.Player.EqualizerPreset = value;
            Save(value, CurrentKey);
        }
    }

    public bool IsEnabled
    {
        get => isEnabled;
        set
        {
            if (!Set(ref isEnabled, value)) return;
            model.Player.EqualizerEnabled = value;
            Preferences.Set(EnabledKey, value);
        }
    }

    public bool AutoPreamp
    {
        get => autoPreamp;
        set
        {
            if (!Set(ref autoPreamp, value)) return;
            Preferences.Set(AutoPreampKey, value);
            if (value) ApplyAutoPreamp();
        }
    }

    public IReadOnlyList<EQPreset> UserPresets => userPresets;

    public IEnumerable<EQPreset> AllPresets => EQPreset.BuiltIns.Concat(userPresets);

    /// <summary>Picks up the settings in the preferences (at launch, after restoring a backup).</summary>
    public void Reload()
    {
        Preset = Load<EQPreset>(CurrentKey) ?? EQPreset.Flat;
        IsEnabled = Preferences.Bool(EnabledKey);
        autoPreamp = Preferences[AutoPreampKey] is null || Preferences.Bool(AutoPreampKey);
        OnPropertyChanged(nameof(AutoPreamp));
        userPresets = Load<List<EQPreset>>(UserPresetsKey) ?? [];
        OnPropertyChanged(nameof(UserPresets));
        model.Player.EqualizerPreset = preset;
        model.Player.EqualizerEnabled = isEnabled;
    }

    public void Select(EQPreset newPreset)
    {
        Preset = newPreset;
        if (autoPreamp) ApplyAutoPreamp();
    }

    public void UpdateBand(int index, Func<EQBand, EQBand> change)
    {
        if (index < 0 || index >= preset.Bands.Count) return;
        var bands = preset.Bands.ToList();
        var changed = change(bands[index]);
        // Controls write back values they were given; ignore writes that change nothing so the preset keeps its name.
        if (changed == bands[index]) return;
        bands[index] = changed;
        var name = IsBuiltInName(preset.Name) || preset.Name.Length == 0 ? "Custom" : preset.Name;
        Preset = preset with { Name = name, Bands = bands, Preamp = autoPreamp ? EQMath.AutoPreamp(bands) : preset.Preamp };
    }

    public void SetPreamp(double value)
    {
        AutoPreamp = false;
        Preset = preset with { Preamp = value };
    }

    public void Reset() => Select(EQPreset.Flat);

    public void SaveCurrent(string name)
    {
        var saved = preset with { Name = name };
        userPresets.RemoveAll(item => item.Name == name);
        userPresets.Add(saved);
        Save(userPresets, UserPresetsKey);
        OnPropertyChanged(nameof(UserPresets));
        Preset = saved;
    }

    public void DeleteUserPreset(EQPreset target)
    {
        userPresets.RemoveAll(item => item.Name == target.Name);
        Save(userPresets, UserPresetsKey);
        OnPropertyChanged(nameof(UserPresets));
    }

    /// <summary>An AutoEq or Equalizer APO ParametricEQ.txt, kept as a user preset and selected.</summary>
    public void ImportParametricEQ(string path)
    {
        var imported = ParametricEQFile.Parse(File.ReadAllText(path), Path.GetFileNameWithoutExtension(path))
                       ?? throw new InvalidDataException("Not a ParametricEQ file.");
        AutoPreamp = false;
        userPresets.RemoveAll(item => item.Name == imported.Name);
        userPresets.Add(imported);
        Save(userPresets, UserPresetsKey);
        OnPropertyChanged(nameof(UserPresets));
        Preset = imported;
        IsEnabled = true;
    }

    public void ExportParametricEQ(string path) => File.WriteAllText(path, ParametricEQFile.Export(preset));

    private void ApplyAutoPreamp()
    {
        var value = EQMath.AutoPreamp(preset.Bands);
        if (Math.Abs(value - preset.Preamp) > 0.01) Preset = preset with { Preamp = value };
    }

    private static bool IsBuiltInName(string name) => EQPreset.BuiltIns.Any(item => item.Name == name);

    private void Save<T>(T value, string key) => Preferences.Set(key, JsonSerializer.SerializeToUtf8Bytes(value, SwiftJson.Options));

    private T? Load<T>(string key) where T : class => SwiftJson.Decode<T>(Preferences.Data(key));
}
