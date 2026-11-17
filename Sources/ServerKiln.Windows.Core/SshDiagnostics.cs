namespace ServerKiln.Windows.Core;

public enum SshFailureKind { UnverifiedHost, ChangedHost, MissingKey, KeyPermissions, Authentication, Timeout, Other }

public static class SshDiagnostics
{
    public static SshFailureKind Classify(string? error)
    {
        var message = error ?? "";
        bool Has(string text) => message.Contains(text, StringComparison.OrdinalIgnoreCase);
        if (Has("REMOTE HOST IDENTIFICATION HAS CHANGED") || Has("Offending ") && Has(" key")) return SshFailureKind.ChangedHost;
        if (Has("host key is known") || Has("Host key verification failed") || Has("requested strict checking")) return SshFailureKind.UnverifiedHost;
        if (Has("UNPROTECTED PRIVATE KEY FILE") || Has("bad permissions") || Has("permissions are too open")) return SshFailureKind.KeyPermissions;
        if (Has("找不到指定的 SSH 私钥文件") || Has("SSH key file not found") || Has("identity file") && Has("not accessible")) return SshFailureKind.MissingKey;
        if (Has("Permission denied") || Has("Load key") || Has("invalid format") || Has("passphrase")) return SshFailureKind.Authentication;
        if (Has("timed out") || Has("超时")) return SshFailureKind.Timeout;
        return SshFailureKind.Other;
    }
}
