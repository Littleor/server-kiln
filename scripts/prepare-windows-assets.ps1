$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$assetDirectory = Join-Path $repositoryRoot 'build\windows'
New-Item -ItemType Directory -Force -Path $assetDirectory | Out-Null
$source = [System.Drawing.Image]::FromFile((Join-Path $repositoryRoot 'docs\screenshots\app-icon.png'))
$bitmap = New-Object System.Drawing.Bitmap($source, (New-Object System.Drawing.Size(64, 64)))
$handle = $bitmap.GetHicon()
$icon = [System.Drawing.Icon]::FromHandle($handle)
$output = [System.IO.File]::Create((Join-Path $assetDirectory 'AppIcon.ico'))
try { $icon.Save($output) }
finally { $output.Dispose(); $icon.Dispose(); $bitmap.Dispose(); $source.Dispose() }
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class ServerKilnIcon { [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr icon); }'
[ServerKilnIcon]::DestroyIcon($handle) | Out-Null
