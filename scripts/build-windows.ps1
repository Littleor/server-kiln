param(
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Release',
    [ValidateSet('win-x64', 'win-arm64')][string]$Runtime = 'win-x64',
    [switch]$Package,
    [switch]$Snapshots,
    [switch]$SkipTests
)
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $repositoryRoot
try {
    python scripts/export-windows-collector.py --check
    if ($LASTEXITCODE -ne 0) { throw 'Collector contract check failed.' }
    if (-not $SkipTests) {
        dotnet run --project Tests/ServerKiln.Windows.Tests -c $Configuration
        if ($LASTEXITCODE -ne 0) { throw 'Windows tests failed.' }
    }
    dotnet build Sources/ServerKiln.Windows -c $Configuration
    if ($LASTEXITCODE -ne 0) { throw 'Windows build failed.' }
    if (-not $SkipTests) {
        $smokeApplication = Join-Path $repositoryRoot "Sources\ServerKiln.Windows\bin\$Configuration\net10.0-windows\ServerKiln.dll"
        dotnet $smokeApplication --smoke-test
        if ($LASTEXITCODE -ne 0) { throw 'WPF template and layout smoke test failed.' }
    }
    if ($Snapshots) {
        $application = Join-Path $repositoryRoot "Sources\ServerKiln.Windows\bin\$Configuration\net10.0-windows\ServerKiln.dll"
        foreach ($language in @('en', 'zh')) {
            $screenshots = Join-Path $repositoryRoot "build\windows\screenshots\$language"
            dotnet $application --snapshot $screenshots --language $language
            if ($LASTEXITCODE -ne 0) { throw "Snapshot generation failed for $language" }
        }
    }
    if ($Package) {
        $version = (Get-Content -LiteralPath VERSION -Raw).Trim()
        $output = Join-Path $repositoryRoot "dist\windows\$Runtime"
        dotnet publish Sources/ServerKiln.Windows -c $Configuration -r $Runtime --self-contained true -p:DebugType=None -o $output
        if ($LASTEXITCODE -ne 0) { throw 'Windows publish failed.' }
        if (-not (Test-Path -LiteralPath (Join-Path $output 'Licenses\dotnet-LICENSE.txt')) -or
            -not (Test-Path -LiteralPath (Join-Path $output 'Licenses\dotnet-ThirdPartyNotices.txt'))) {
            throw 'The .NET distribution license and notices must be present before packaging.'
        }
        $packageRoot = (dotnet msbuild Sources/ServerKiln.Windows -nologo -getProperty:NuGetPackageRoot).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Could not locate Microsoft runtime pack notices.' }
        $frameworks = (Get-Content -LiteralPath (Join-Path $output 'ServerKiln.runtimeconfig.json') -Raw | ConvertFrom-Json).runtimeOptions.includedFrameworks
        $packNames = @{ 'Microsoft.NETCore.App' = 'microsoft.netcore.app.runtime'; 'Microsoft.WindowsDesktop.App' = 'microsoft.windowsdesktop.app.runtime' }
        foreach ($framework in $frameworks) {
            $packName = $packNames[$framework.name] + '.' + $Runtime
            $packDirectory = Join-Path $packageRoot "$packName\$($framework.version)"
            $notices = @(Get-ChildItem -LiteralPath $packDirectory -File | Where-Object { $_.Name -match '^(LICENSE|THIRD-PARTY-NOTICES)(\..*)?$' })
            if (-not ($notices | Where-Object { $_.Name -match '^LICENSE' })) { throw "Missing license for $packName" }
            foreach ($notice in $notices) {
                Copy-Item -LiteralPath $notice.FullName -Destination (Join-Path $output "Licenses\$packName-$($notice.Name)")
            }
        }
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'scripts\install-windows.ps1') -Destination (Join-Path $output 'install.ps1')
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'scripts\WindowsShortcuts.cs') -Destination (Join-Path $output 'WindowsShortcuts.cs')
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'docs\windows.md') -Destination (Join-Path $output 'WINDOWS.md')
        $archive = Join-Path $repositoryRoot "dist\ServerKiln-$version-$Runtime.zip"
        Compress-Archive -Path (Join-Path $output '*') -DestinationPath $archive -Force
        $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $([System.IO.Path]::GetFileName($archive))" | Set-Content -LiteralPath "$archive.sha256" -Encoding ascii
        python scripts/check-windows-package.py --directory (Join-Path $repositoryRoot 'dist') --version $version
        if ($LASTEXITCODE -ne 0) { throw 'Packaged Windows artifact verification failed.' }
        Write-Output "Packaged $archive"
    }
} finally { Pop-Location }
