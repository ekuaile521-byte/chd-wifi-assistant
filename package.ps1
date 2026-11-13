[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$project = $PSScriptRoot
$dist = Join-Path $project 'dist'
& (Join-Path $project 'build.ps1') -OutputDirectory $dist

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-ChdArchive([string]$Destination, [System.Collections.IDictionary]$Files) {
    $stream = [IO.File]::Open($Destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            foreach ($entry in $Files.GetEnumerator()) {
                $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $archive, [string]$entry.Value, [string]$entry.Key, [IO.Compression.CompressionLevel]::Optimal)
            }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }
}

$sourceFiles = [ordered]@{}
foreach ($relative in @(
    'README.md', 'LICENSE', '.gitignore', 'build.ps1', 'package.ps1',
    'src/Launcher.cs', 'src/Install-ChdWifiAuth.ps1', 'src/Invoke-ChdWifiAuth.ps1',
    'src/Remove-ChdWifiAuth.ps1', 'src/SrunCrypto.cs', 'src/ChdDns.cs', 'tests/Offline.Tests.ps1', 'tests/manual_dns_probe.py'
)) {
    $sourceFiles[$relative] = Join-Path $project $relative
}
$sourceZip = Join-Path $dist 'CHD-WiFi-Assistant-source.zip'
New-ChdArchive $sourceZip $sourceFiles

$appFiles = [ordered]@{
    'CHD-WiFi-Assistant.exe' = (Join-Path $dist 'CHD-WiFi-Assistant.exe')
    'README.md' = (Join-Path $project 'README.md')
    'LICENSE' = (Join-Path $project 'LICENSE')
}
$appZip = Join-Path $dist 'CHD-WiFi-Assistant-Windows.zip'
New-ChdArchive $appZip $appFiles

$hashes = foreach ($name in @('CHD-WiFi-Assistant.exe', 'CHD-WiFi-Assistant-Windows.zip', 'CHD-WiFi-Assistant-source.zip')) {
    $hash = (Get-FileHash -LiteralPath (Join-Path $dist $name) -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $name"
}
[IO.File]::WriteAllLines((Join-Path $dist 'SHA256SUMS.txt'), [string[]]$hashes, [Text.Encoding]::ASCII)
Write-Host "Packages ready: $dist"
