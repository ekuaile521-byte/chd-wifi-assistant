[CmdletBinding()]
param([string]$OutputDirectory)

$ErrorActionPreference = 'Stop'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot 'dist' }
$source = Join-Path $PSScriptRoot 'src'
$framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $framework)) {
    $framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $framework)) { throw 'Windows .NET Framework C# compiler not found.' }

$staging = Join-Path ([IO.Path]::GetTempPath()) ('ChdWifiBuild-' + [guid]::NewGuid().ToString('N'))
$files = @('Install-ChdWifiAuth.ps1', 'Invoke-ChdWifiAuth.ps1', 'Remove-ChdWifiAuth.ps1', 'SrunCrypto.cs', 'ChdDns.cs')
try {
    $null = [IO.Directory]::CreateDirectory($staging)
    $utf8WithBom = [Text.UTF8Encoding]::new($true)
    foreach ($name in $files) {
        $inputFile = Join-Path $source $name
        $outputFile = Join-Path $staging $name
        if ($name.EndsWith('.ps1')) {
            # Windows PowerShell 5.1 needs a BOM for non-ASCII text.
            [IO.File]::WriteAllText($outputFile, [IO.File]::ReadAllText($inputFile), $utf8WithBom)
        } else {
            [IO.File]::Copy($inputFile, $outputFile)
        }
    }
    $null = [IO.Directory]::CreateDirectory($OutputDirectory)
    $exe = [IO.Path]::GetFullPath((Join-Path $OutputDirectory 'CHD-WiFi-Assistant.exe'))
    $arguments = @('/nologo', '/target:winexe', '/platform:anycpu', '/optimize+', '/codepage:65001',
        '/reference:System.Windows.Forms.dll', '/reference:System.Drawing.dll', '/reference:System.Web.Extensions.dll',
        ('/out:' + $exe))
    foreach ($name in $files) {
        $arguments += '/resource:{0},ChdWifiAssistant.Payload.{1}' -f (Join-Path $staging $name), $name
    }
    $arguments += Join-Path $source 'Launcher.cs'
    & $framework $arguments
    if ($LASTEXITCODE -ne 0) { throw "C# compiler failed with exit code $LASTEXITCODE." }
    $null = [Reflection.AssemblyName]::GetAssemblyName($exe)
    Write-Host "Build complete: $exe"
} finally {
    foreach ($name in $files) {
        $path = Join-Path $staging $name
        if (Test-Path -LiteralPath $path) { [IO.File]::Delete($path) }
    }
    if (Test-Path -LiteralPath $staging) { [IO.Directory]::Delete($staging, $false) }
}
