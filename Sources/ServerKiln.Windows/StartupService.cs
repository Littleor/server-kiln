using Microsoft.Win32;

namespace ServerKiln.Windows;

internal static class StartupService
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public static bool Enabled
    {
        get { using var key = Registry.CurrentUser.OpenSubKey(RunKey); return key?.GetValue("ServerKiln") is string; }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) key.SetValue("ServerKiln", "\"" + Environment.ProcessPath + "\" --start-in-tray");
            else key.DeleteValue("ServerKiln", throwOnMissingValue: false);
        }
    }
}
