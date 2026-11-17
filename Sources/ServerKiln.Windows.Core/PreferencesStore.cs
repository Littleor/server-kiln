using System.Text.Json;

namespace ServerKiln.Windows.Core;

public sealed class PreferencesStore(string directory)
{
    public static string DefaultDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ServerKiln");
    public string FilePath => Path.Combine(directory, "settings.json");

    public AppPreferences Load()
    {
        if (!File.Exists(FilePath)) return new();
        var settings = JsonSerializer.Deserialize<AppPreferences>(File.ReadAllText(FilePath), JsonDefaults.Options)
            ?? throw new InvalidDataException("Settings are empty.");
        settings.Validate();
        return settings;
    }

    public void Save(AppPreferences preferences)
    {
        preferences.Validate();
        Directory.CreateDirectory(directory);
        var temporary = FilePath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temporary, JsonSerializer.Serialize(preferences, JsonDefaults.Options));
            File.Move(temporary, FilePath, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
