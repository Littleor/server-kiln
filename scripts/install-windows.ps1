param(
    [string]$SourceDirectory = $PSScriptRoot,
    [switch]$NoDesktopShortcut,
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Programs\ServerKiln'),
    [string]$DesktopDirectory = [Environment]::GetFolderPath('Desktop'),
    [string]$StartMenuDirectory = [Environment]::GetFolderPath('Programs')
)
$ErrorActionPreference = 'Stop'
$source = [System.IO.Path]::GetFullPath($SourceDirectory)
$program = [System.IO.Path]::GetFullPath($InstallDirectory)
if (-not (Test-Path -LiteralPath (Join-Path $source 'ServerKiln.exe'))) {
    throw 'Run install.ps1 from the extracted Windows package.'
}
if ($source.TrimEnd('\') -eq $program.TrimEnd('\') -or
    $program.StartsWith($source.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
    $source.StartsWith($program.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'The source and installation directories must not contain each other.'
}
$running = Get-Process -Name ServerKiln -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq (Join-Path $program 'ServerKiln.exe') }
if ($running) { throw 'Quit ServerKiln from its tray menu before updating.' }
New-Item -ItemType Directory -Path $program -Force | Out-Null
Copy-Item -Path (Join-Path $source '*') -Destination $program -Recurse -Force
if (-not ('ServerKilnSetup.Shortcuts' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'WindowsShortcuts.cs')
}
$shortcutFolders = @($StartMenuDirectory)
if (-not $NoDesktopShortcut) { $shortcutFolders += $DesktopDirectory }
foreach ($folder in $shortcutFolders) {
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
    [ServerKilnSetup.Shortcuts]::Create((Join-Path $folder 'ServerKiln.lnk'), (Join-Path $program 'ServerKiln.exe'), $program)
}
Write-Output "Installed ServerKiln for the current user: $program"
Write-Output 'Open the desktop or Start menu shortcut. Login startup is optional in Settings.'
