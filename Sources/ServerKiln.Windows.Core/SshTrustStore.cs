namespace ServerKiln.Windows.Core;

public static class SshTrustStore
{
    /// <summary>Only replace a completely discarded user store. Valid paths, including CA stores,
    /// multiple files and paths with spaces, remain under OpenSSH's control.</summary>
    public static bool NeedsPersistentFallback(string effectiveConfiguration)
    {
        var line = effectiveConfiguration.Replace("\r", "").Split('\n')
            .FirstOrDefault(l => l.StartsWith("userknownhostsfile ", StringComparison.OrdinalIgnoreCase));
        if (line is null) throw new IOException("OpenSSH did not resolve UserKnownHostsFile. / 无法解析 SSH 指纹存储配置。");
        var values = line["userknownhostsfile ".Length..].Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        // ssh -G prints paths without quoting. Do not reconstruct or split valid paths:
        // words not recognized as discard devices cause the entire configuration to be inherited.
        return values.Length > 0 && values.All(value => value.Trim('"').Replace('\\', '/').ToLowerInvariant()
            is "none" or "nul" or "/dev/null" or "//./nul");
    }
}
