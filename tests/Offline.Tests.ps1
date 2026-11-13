[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$source = Join-Path $project 'src'
$worker = Join-Path $source 'Invoke-ChdWifiAuth.ps1'
$exe = Join-Path $project 'dist\CHD-WiFi-Assistant.exe'
$checks = 0

function Assert-Equal($actual, $expected, [string]$name) {
    if ($actual -ne $expected) { throw "FAIL ${name}: expected [$expected], got [$actual]" }
    $script:checks++
    Write-Host "PASS $name"
}
function Assert-True($condition, [string]$name) {
    if (-not $condition) { throw "FAIL $name" }
    $script:checks++
    Write-Host "PASS $name"
}

foreach ($name in @('Install-ChdWifiAuth.ps1', 'Invoke-ChdWifiAuth.ps1', 'Remove-ChdWifiAuth.ps1')) {
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $source $name), [ref]$tokens, [ref]$errors)
    Assert-Equal $errors.Count 0 "PowerShell parser: $name"
}

. $worker

function Get-NetConnectionProfile {
    [pscustomobject]@{ Name = 'CHD-WiFi'; InterfaceAlias = 'Wi-Fi'; InterfaceIndex = 7 }
}
function Get-NetIPAddress {
    [CmdletBinding()]
    param($InterfaceIndex, $AddressFamily, $IPAddress)
    if ($InterfaceIndex -eq 7 -or $IPAddress -eq '10.24.35.46') {
        [pscustomobject]@{ AddressState = 'Preferred'; IPAddress = '10.24.35.46'; InterfaceIndex = 7 }
    }
}
Assert-Equal (Get-ChdWifiLink) '10.24.35.46' 'Wi-Fi works without a fixed interface alias'

function Get-DnsClientServerAddress {
    [CmdletBinding()]
    param($InterfaceIndex, $AddressFamily)
    [pscustomobject]@{ ServerAddresses = @('192.0.2.53') }
}
function Resolve-ChdWifiDns {
    param($WifiAddress, $DnsServer)
    if ($script:dnsUnavailable) { throw 'DNS offline fixture' }
    @(
        '198.18.1.4', '127.0.0.1', '192.0.2.9', '192.0.2.9'
    )
}
$dnsCandidates = @(Get-ChdPortalAddresses '10.24.35.46')
Assert-Equal $dnsCandidates.Count 2 'Wi-Fi DNS filters fake and duplicate answers'
Assert-Equal $dnsCandidates[0] '192.0.2.9' 'Wi-Fi DNS usable answer is first'
Assert-Equal $dnsCandidates[1] '' 'System DNS fallback remains available'
$script:dnsUnavailable = $true
$dnsCandidates = @(Get-ChdPortalAddresses '10.24.35.46')
Assert-Equal $dnsCandidates.Count 1 'DNS failure retains one fallback'
Assert-Equal $dnsCandidates[0] '' 'DNS failure does not invent a fixed IP'
$script:dnsUnavailable = $false

Add-Type -Path (Join-Path $source 'ChdDns.cs')
$dnsPacket = [byte[]]@(
    0x2c,0x42,0x81,0x80,0,1,0,1,0,0,0,0,
    1,0x78,0,0,1,0,1,
    0xc0,0x0c,0,1,0,1,0,0,0,60,0,4,192,0,2,9
)
Assert-Equal ([ChdDns]::ParseAddresses($dnsPacket, [uint16]0x2c42)[0]) '192.0.2.9' 'Bound DNS parser reads an A record'
$badDnsIdRejected = $false
try { $null = [ChdDns]::ParseAddresses($dnsPacket, [uint16]0x2c43) } catch { $badDnsIdRejected = $true }
Assert-True $badDnsIdRejected 'DNS parser rejects mismatched query ID'
$badDnsPacketRejected = $false
try { $null = [ChdDns]::ParseAddresses([byte[]]$dnsPacket[0..20], [uint16]0x2c42) } catch { $badDnsPacketRejected = $true }
Assert-True $badDnsPacketRejected 'DNS parser rejects truncated response'
$badDnsFlags = [byte[]]$dnsPacket.Clone()
$badDnsFlags[2] = 0x83
$truncatedDnsRejected = $false
try { $null = [ChdDns]::ParseAddresses($badDnsFlags, [uint16]0x2c42) } catch { $truncatedDnsRejected = $true }
Assert-True $truncatedDnsRejected 'DNS parser rejects truncated DNS flag'

$script:scenario = ''
$script:portalCalls = 0
function Invoke-ChdPortal {
    param($WifiAddress, $PortalAddress, $Path, $Fields)
    $script:portalCalls++
    switch ($script:scenario) {
        'online' { return [pscustomobject]@{ error = 'ok'; online_ip = $WifiAddress } }
        'offline' { return [pscustomobject]@{ error = 'not_online_error' } }
        'mismatch' { return [pscustomobject]@{ error = 'ok'; online_ip = '10.99.99.99' } }
        'fallback' {
            if ($PortalAddress) { throw 'CurlTimedOut' }
            return [pscustomobject]@{ error = 'ok'; online_ip = $WifiAddress }
        }
        default { throw 'CurlTimedOut' }
    }
}
function Get-ChdPortalAddresses {
    param([string]$WifiAddress)
    return @('192.0.2.2', '')
}
foreach ($pair in @(@('online', 'Online'), @('offline', 'NeedsLogin'), @('fallback', 'Online'))) {
    $script:scenario = $pair[0]; $script:portalCalls = 0
    $status = Get-ChdPortalStatus '10.24.35.46'
    Assert-Equal $status.State $pair[1] "Portal status: $($pair[0])"
    if ($pair[0] -eq 'fallback') { Assert-Equal $script:portalCalls 2 'Portal fallback is attempted' }
}
foreach ($case in @('mismatch', 'unavailable')) {
    $script:scenario = $case; $failed = $false
    try { $null = Get-ChdPortalStatus '10.24.35.46' } catch { $failed = $true }
    Assert-True $failed "Does not report $case as online"
}

Assert-Equal (Get-ChdAcIdFromCredential ([pscustomobject]@{ Username = 'example' })) '5' 'Legacy credential AC ID'
Assert-Equal (Get-ChdAcIdFromCredential ([pscustomobject]@{ AcId = '12' })) '12' 'Configured AC ID'
$badAcIdRejected = $false
try { $null = Get-ChdAcIdFromCredential ([pscustomobject]@{ AcId = '../' }) } catch { $badAcIdRejected = $true }
Assert-True $badAcIdRejected 'Invalid AC ID is rejected'

Add-Type -Path (Join-Path $source 'SrunCrypto.cs')
Assert-Equal ([ChdSrunCrypto]::PasswordDigest('test-password', 'challenge-123')) '3e9edb4ea6ef85473139d199c1a58cb3' 'HMAC-MD5 known vector'
Assert-Equal ([ChdSrunCrypto]::Checksum('token', @('username', 'digest', '5'))) '9e63d9d770f3f75b857789ef1ad7ffa764e3421b' 'SHA-1 known vector'

$testDir = Join-Path ([IO.Path]::GetTempPath()) ('ChdWifiTest-' + [guid]::NewGuid().ToString('N'))
$statusDir = Join-Path $testDir 'Status'
$credentialFile = Join-Path $testDir 'credential.bin'
$reportFile = Join-Path $statusDir 'last-run.json'
try {
    $null = [IO.Directory]::CreateDirectory($statusDir)
    [IO.File]::WriteAllText($credentialFile, 'dummy fixture')
    [IO.File]::SetLastWriteTimeUtc($credentialFile, [DateTime]::UtcNow.AddHours(-1))
    $script:ChdDataDir = $testDir
    $lastAttempt = [DateTimeOffset]::UtcNow.AddMinutes(-1)
    foreach ($case in @(@(1, 5), @(2, 15), @(3, 60))) {
        $record = @{ Result = 'LoginRejected'; AuthFailures = $case[0]; AuthLastAttempt = $lastAttempt.ToString('o') }
        [IO.File]::WriteAllText($reportFile, ($record | ConvertTo-Json -Compress))
        $retry = Get-ChdRetryState
        Assert-Equal ([int]($retry.RetryAfterUtc - $lastAttempt.UtcDateTime).TotalMinutes) $case[1] "Retry delay after $($case[0]) failures"
    }
    [IO.File]::SetLastWriteTimeUtc($credentialFile, [DateTime]::UtcNow)
    Assert-True ($null -eq (Get-ChdRetryState)) 'New credential clears stale retry delay'
} finally {
    if (Test-Path -LiteralPath $reportFile) { [IO.File]::Delete($reportFile) }
    if (Test-Path -LiteralPath $credentialFile) { [IO.File]::Delete($credentialFile) }
    if (Test-Path -LiteralPath $statusDir) { [IO.Directory]::Delete($statusDir, $false) }
    if (Test-Path -LiteralPath $testDir) { [IO.Directory]::Delete($testDir, $false) }
}

Assert-True (Test-Path -LiteralPath $exe) 'Desktop executable exists'
$assembly = [Reflection.Assembly]::LoadFile($exe)
$expectedResources = @('Install-ChdWifiAuth.ps1', 'Invoke-ChdWifiAuth.ps1', 'Remove-ChdWifiAuth.ps1', 'SrunCrypto.cs', 'ChdDns.cs')
$resources = @($assembly.GetManifestResourceNames())
Assert-Equal $resources.Count $expectedResources.Count 'Only approved components are embedded'
foreach ($name in $expectedResources) {
    $resourceName = 'ChdWifiAssistant.Payload.' + $name
    Assert-True ($resourceName -in $resources) "Embedded component: $name"
    $stream = $assembly.GetManifestResourceStream($resourceName)
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
        try { $embeddedText = $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
    Assert-Equal $embeddedText ([IO.File]::ReadAllText((Join-Path $source $name))) "Embedded source matches: $name"
}
Write-Host "Offline checks completed: $checks"
