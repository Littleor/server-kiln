using System.Text;
using System.Text.RegularExpressions;

namespace ServerKiln.Windows.Core;

public sealed record SshHostEntry(string Alias, string? HostName, string? User, int? Port, string SourceFile)
{
    public string Summary => (User is null ? "" : User + "@") + (HostName ?? Alias) + (Port is null or 22 ? "" : $":{Port}");
}

/// <summary>Lists explicit aliases only. OpenSSH, rather than this importer, resolves connection settings.</summary>
public static class SshConfigParser
{
    public static string DefaultPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ssh", "config");
    private static readonly HashSet<string> IgnoredHosts = new(StringComparer.OrdinalIgnoreCase)
        { "github.com", "gitlab.com", "bitbucket.org", "ssh.github.com", "gitee.com", "codeup.aliyun.com" };

    public static SshHostEntry[] Load(string? path = null)
    {
        path = string.IsNullOrWhiteSpace(path) ? DefaultPath : Path.GetFullPath(path);
        return LoadInternal(path, Path.GetDirectoryName(DefaultPath)!, 0, new HashSet<string>(StringComparer.OrdinalIgnoreCase))
            .DistinctBy(h => h.Alias, StringComparer.OrdinalIgnoreCase).ToArray();
    }

    private static List<SshHostEntry> LoadInternal(string path, string sshDirectory, int depth, HashSet<string> active)
    {
        if (depth >= 5 || !File.Exists(path) || !active.Add(Path.GetFullPath(path))) return [];
        try { return ParseInternal(File.ReadAllText(path), path, sshDirectory, depth, active); }
        finally { active.Remove(Path.GetFullPath(path)); }
    }

    public static SshHostEntry[] Parse(string text, string sourceFile = "") => ParseInternal(text, sourceFile,
        Path.GetDirectoryName(DefaultPath)!,
        0, new HashSet<string>(StringComparer.OrdinalIgnoreCase)).DistinctBy(h => h.Alias, StringComparer.OrdinalIgnoreCase).ToArray();

    private static List<SshHostEntry> ParseInternal(string text, string file, string sshDirectory, int depth, HashSet<string> active)
    {
        List<SshHostEntry> entries = [], current = [];
        bool inConditionalBlock = false;
        foreach (var raw in text.Split('\n'))
        {
            var tokens = Tokenize(raw);
            if (tokens.Count < 2) continue;
            var key = tokens[0].ToLowerInvariant();
            var values = tokens.Skip(1).ToArray();
            if (key is "host" or "match")
            {
                entries.AddRange(current); current.Clear();
                inConditionalBlock = true;
                if (key == "host") current.AddRange(values.Where(v => !v.Contains('*') && !v.Contains('?') && !v.StartsWith('!')
                    && !IgnoredHosts.Contains(v)).Select(v => new SshHostEntry(v, null, null, null, file)));
            }
            else if (key == "include" && !inConditionalBlock)
            {
                foreach (var pattern in values)
                    foreach (var include in ExpandInclude(pattern, sshDirectory))
                        entries.AddRange(LoadInternal(include, sshDirectory, depth + 1, active));
            }
            else
            {
                for (var i = 0; i < current.Count; i++) current[i] = key switch
                {
                    "hostname" when current[i].HostName is null => current[i] with { HostName = values[0] },
                    "user" when current[i].User is null => current[i] with { User = values[0] },
                    "port" when current[i].Port is null && int.TryParse(values[0], out var port) => current[i] with { Port = port },
                    _ => current[i]
                };
            }
        }
        entries.AddRange(current);
        return entries;
    }

    internal static List<string> Tokenize(string line)
    {
        List<string> words = [];
        var token = new StringBuilder();
        bool quoted = false;
        foreach (var ch in line.Trim())
        {
            if (ch == '"') { quoted = !quoted; continue; }
            if (ch == '#' && !quoted) break;
            if (!quoted && ch == '=' && words.Count == 1 && token.Length == 0) continue;
            if (!quoted && (char.IsWhiteSpace(ch) || (ch == '=' && words.Count == 0)))
            {
                if (token.Length > 0) { words.Add(token.ToString()); token.Clear(); }
            }
            else token.Append(ch);
        }
        if (token.Length > 0) words.Add(token.ToString());
        return words;
    }

    private static IEnumerable<string> ExpandInclude(string pattern, string sshDirectory)
    {
        if (pattern.StartsWith("~/", StringComparison.Ordinal) || pattern.StartsWith("~\\", StringComparison.Ordinal))
            pattern = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), pattern[2..]);
        if (!Path.IsPathRooted(pattern)) pattern = Path.Combine(sshDirectory, pattern);
        var full = Path.GetFullPath(pattern);
        if (!full.Contains('*') && !full.Contains('?')) return [full];
        var root = Path.GetPathRoot(full)!;
        IEnumerable<string> candidates = [root];
        foreach (var component in full[root.Length..].Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar))
        {
            if (component.Length == 0) continue;
            var matcher = new Regex("^" + Regex.Escape(component).Replace("\\*", ".*").Replace("\\?", ".") + "$",
                RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
            candidates = candidates.Where(Directory.Exists).SelectMany(Directory.EnumerateFileSystemEntries)
                .Where(p => matcher.IsMatch(Path.GetFileName(p))).Order(StringComparer.OrdinalIgnoreCase).ToArray();
        }
        return candidates.Where(File.Exists);
    }
}
