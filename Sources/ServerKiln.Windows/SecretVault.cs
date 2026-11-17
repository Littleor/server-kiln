using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace ServerKiln.Windows;

/// <summary>DPAPI, bound to this Windows user. The device key never enters settings.json.</summary>
internal sealed class SecretVault(string directory)
{
    private string PathName => Path.Combine(directory, "bark-key.dat");
    public string Load()
    {
        if (!File.Exists(PathName)) return "";
        var encrypted = File.ReadAllBytes(PathName);
        var plain = Transform(encrypted, protect: false);
        try { return Encoding.UTF8.GetString(plain); }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }

    public void Save(string secret)
    {
        if (string.IsNullOrWhiteSpace(secret)) { if (File.Exists(PathName)) File.Delete(PathName); return; }
        Directory.CreateDirectory(directory);
        var plain = Encoding.UTF8.GetBytes(secret);
        try
        {
            var encrypted = Transform(plain, protect: true);
            var temporary = PathName + ".tmp";
            try { File.WriteAllBytes(temporary, encrypted); File.Move(temporary, PathName, overwrite: true); }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }

    private static byte[] Transform(byte[] data, bool protect)
    {
        var input = new Blob { Size = data.Length, Data = Marshal.AllocHGlobal(data.Length) };
        var output = new Blob();
        try
        {
            Marshal.Copy(data, 0, input.Data, data.Length);
            var ok = protect ? CryptProtectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output)
                : CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output);
            if (!ok) throw new CryptographicException(Marshal.GetLastWin32Error());
            var result = new byte[output.Size];
            Marshal.Copy(output.Data, result, 0, result.Length);
            return result;
        }
        finally
        {
            for (var i = 0; i < input.Size; i++) Marshal.WriteByte(input.Data, i, 0);
            Marshal.FreeHGlobal(input.Data);
            if (output.Data != IntPtr.Zero)
            {
                for (var i = 0; i < output.Size; i++) Marshal.WriteByte(output.Data, i, 0);
                LocalFree(output.Data);
            }
        }
    }
    [StructLayout(LayoutKind.Sequential)] private struct Blob { public int Size; public IntPtr Data; }
    [DllImport("crypt32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(ref Blob input, IntPtr description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, out Blob output);
    [DllImport("crypt32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(ref Blob input, IntPtr description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, out Blob output);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr pointer);
}
