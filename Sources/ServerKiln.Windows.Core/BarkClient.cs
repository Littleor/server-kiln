using System.Net.Http.Json;
using System.Text.Json;

namespace ServerKiln.Windows.Core;

public sealed class BarkClient(HttpClient client)
{
    public static Uri ValidateServer(string server)
    {
        if (!Uri.TryCreate(server.TrimEnd('/') + "/", UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps
            || !string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment))
            throw new ArgumentException("Bark requires an HTTPS server URL without credentials or query parameters. / Bark 服务地址必须为 HTTPS，且不包含密钥或查询参数。");
        return uri;
    }

    public async Task SendAsync(string server, string deviceKey, string title, string body, CancellationToken token = default)
    {
        var uri = new Uri(ValidateServer(server), "push");
        if (string.IsNullOrWhiteSpace(deviceKey)) throw new ArgumentException("Enter the Bark device key. / 请填写 Bark 设备密钥。");
        using var response = await client.PostAsJsonAsync(uri,
            new { device_key = deviceKey.Trim(), title, body, group = "ServerKiln" }, token).ConfigureAwait(false);
        // Do not include a response body or URL in errors: a relay can echo the device key.
        if (!response.IsSuccessStatusCode) throw new IOException($"Bark HTTP {(int)response.StatusCode}.");
        using var json = await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync(token).ConfigureAwait(false), cancellationToken: token).ConfigureAwait(false);
        if (!json.RootElement.TryGetProperty("code", out var code) || !code.TryGetInt32(out var value) || value != 200)
            throw new IOException("Bark rejected the notification. / Bark 未接受通知。");
    }
}
