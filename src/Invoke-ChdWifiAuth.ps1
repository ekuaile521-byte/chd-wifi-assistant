[CmdletBinding()]
param([switch]$Probe)

$ErrorActionPreference = 'Stop'
$script:ChdPortalHost = 'beiradius.chd.edu.cn'
$script:ChdAcId = '5'
$script:ChdDataDir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ChdWifiAutoAuth'
$script:ChdEntropy = [Text.Encoding]::UTF8.GetBytes('ChdWifiAutoAuth/v1')

function Get-ChdWifiLink {
    $wifi = Get-NetConnectionProfile |
        Where-Object { $_.Name -in @('CHD-WiFi', 'CHD_WiFi') } |
        Select-Object -First 1
    if (-not $wifi) { return }
    Get-NetIPAddress -InterfaceIndex $wifi.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.AddressState -eq 'Preferred' -and $_.IPAddress -notlike '169.254.*' } |
        Select-Object -First 1 -ExpandProperty IPAddress
}

function Invoke-ChdPortal {
    param(
        [string]$WifiAddress,
        [string]$PortalAddress,
        [ValidateSet('/cgi-bin/rad_user_info', '/cgi-bin/get_challenge', '/cgi-bin/srun_portal')]
        [string]$Path,
        [System.Collections.IDictionary]$Fields = @{}
    )
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    $argsForCurl = '--disable --noproxy "*" --ipv4 --interface {0} --proto "=https" --ssl-revoke-best-effort --silent --fail --connect-timeout 4 --max-time 8 --max-filesize 131072 --write-out "\nCHD_HTTP=%{{http_code}}" --config -' -f $WifiAddress
    if ($PortalAddress) {
        $argsForCurl += ' --resolve "{0}:443:{1}"' -f $script:ChdPortalHost, $PortalAddress
    }
    $query = @('callback=chdWifiResponse', ('_={0}' -f [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()))
    foreach ($field in $Fields.GetEnumerator()) {
        $query += '{0}={1}' -f [Uri]::EscapeDataString($field.Key), [Uri]::EscapeDataString([string]$field.Value)
    }
    $requestUrl = 'https://{0}{1}?{2}' -f $script:ChdPortalHost, $Path, ($query -join '&')

    # Use explicit pipes so the task can run without a console. The URL never goes in argv.
    $process = [Diagnostics.Process]::new()
    $process.StartInfo.FileName = $curl
    $process.StartInfo.Arguments = $argsForCurl
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardInput = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    try {
        if (-not $process.Start()) { throw 'CurlNotStarted' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.WriteLine('url = "' + $requestUrl + '"')
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(12000)) {
            $process.Kill()
            throw 'CurlTimedOut'
        }
        $response = $stdout.GetAwaiter().GetResult()
        $null = $stderr.GetAwaiter().GetResult()
        $http = [regex]::Match($response, '(?m)^CHD_HTTP=(\d{3})\s*$')
        if ($process.ExitCode -ne 0) {
            $httpCode = if ($http.Success) { $http.Groups[1].Value } else { '000' }
            throw ('CurlExit{0}-HTTP{1}' -f $process.ExitCode, $httpCode)
        }
    } finally {
        $process.Dispose()
    }
    $jsonp = [regex]::Match($response, '(?s)^\s*chdWifiResponse\((\{.*\})\)\s*;?\s*CHD_HTTP=200\s*$')
    if (-not $jsonp.Success) { throw 'UnexpectedPortalResponse' }
    ConvertFrom-Json -InputObject $jsonp.Groups[1].Value
}

function Resolve-ChdWifiDns {
    param([string]$WifiAddress, [string]$DnsServer)
    if (-not ('ChdDns' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'ChdDns.cs') }
    [ChdDns]::Query($script:ChdPortalHost, $WifiAddress, $DnsServer)
}

function Get-ChdPortalAddresses {
    param([string]$WifiAddress)
    $addresses = [Collections.Generic.List[string]]::new()
    try {
        $link = Get-NetIPAddress -IPAddress $WifiAddress -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1
        $dns = Get-DnsClientServerAddress -InterfaceIndex $link.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop
        foreach ($server in @($dns.ServerAddresses)) {
            if (-not $server) { continue }
            try {
                $answers = Resolve-ChdWifiDns $WifiAddress $server
                foreach ($answer in @($answers)) {
                    $address = [string]$answer
                    $parsed = $null
                    if ([Net.IPAddress]::TryParse($address, [ref]$parsed) -and
                        $parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and
                        $address -notmatch '^198\.(18|19)\.' -and
                        $address -notmatch '^(0|127|169\.254)\.' -and
                        -not $addresses.Contains($address)) {
                        $addresses.Add($address)
                    }
                }
            } catch { }
        }
    } catch { }
    # Normal system resolution remains a fallback when Wi-Fi DNS is unavailable.
    $addresses.Add('')
    return $addresses.ToArray()
}

function Get-ChdPortalStatus {
    param([string]$WifiAddress)
    $problems = @()
    foreach ($address in @(Get-ChdPortalAddresses $WifiAddress)) {
        try {
            $response = Invoke-ChdPortal $WifiAddress $address '/cgi-bin/rad_user_info'
            if ($response.error -eq 'ok' -and $response.online_ip -eq $WifiAddress) {
                return [pscustomobject]@{ State = 'Online'; Address = $address; Response = $response }
            }
            if ($response.error -eq 'not_online_error' -or $response.error_msg -eq 'not_online_error') {
                return [pscustomobject]@{ State = 'NeedsLogin'; Address = $address; Response = $response }
            }
            $problems += if ($response.error -eq 'ok') { 'OnlineIPMismatch' } else { 'UnexpectedStatus' }
        } catch {
            $reason = $_.Exception.Message
            $problems += if ($reason -match '^(CurlExit[0-9]{1,3}-HTTP[0-9]{3}|CurlTimedOut|CurlNotStarted|UnexpectedPortalResponse)$') {
                $reason
            } else { 'PortalReadFailed' }
        }
    }
    throw ('PortalStatusUnavailable:' + ($problems -join ','))
}

function Read-ChdCredential {
    Add-Type -AssemblyName System.Security
    $file = Join-Path $script:ChdDataDir 'credential.bin'
    $data = [Security.Cryptography.ProtectedData]::Unprotect(
        [IO.File]::ReadAllBytes($file), $script:ChdEntropy, 'LocalMachine')
    try {
        $credential = ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString($data))
        if (-not $credential.Username -or -not $credential.Password) { throw 'CredentialInvalid' }
        return $credential
    } finally {
        [Array]::Clear($data, 0, $data.Length)
    }
}

function Get-ChdAcIdFromCredential {
    param([psobject]$Credential)
    # Older installations did not save an AC ID; keep their existing default.
    if (-not $Credential.PSObject.Properties['AcId']) { return '5' }
    $savedAcId = [string]$Credential.AcId
    if ($savedAcId -notmatch '^[0-9]{1,6}$') { throw 'InvalidAcId' }
    return $savedAcId
}

function New-ChdLoginFields {
    param([string]$Username, [string]$Password, [string]$WifiAddress, [string]$Challenge)
    if (-not ('ChdSrunCrypto' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'SrunCrypto.cs')
    }
    $data = [ordered]@{
        username = $Username
        password = $Password
        ip = $WifiAddress
        acid = $script:ChdAcId
        enc_ver = 'srun_bx1'
    } | ConvertTo-Json -Compress
    $info = [ChdSrunCrypto]::EncodeInfo($data, $Challenge)
    $digest = [ChdSrunCrypto]::PasswordDigest($Password, $Challenge)
    $checksum = [ChdSrunCrypto]::Checksum($Challenge, @(
        $Username, $digest, $script:ChdAcId, $WifiAddress, '200', '1', $info))
    @{
        action = 'login'
        username = $Username
        password = '{MD5}' + $digest
        info = $info
        chksum = $checksum
        ac_id = $script:ChdAcId
        ip = $WifiAddress
        n = '200'
        type = '1'
        os = 'Windows'
        name = 'Windows'
        double_stack = '0'
    }
}

function Get-ChdRetryState {
    $report = Join-Path $script:ChdDataDir 'Status\last-run.json'
    $credentialFile = Join-Path $script:ChdDataDir 'credential.bin'
    if (-not [IO.File]::Exists($report) -or -not [IO.File]::Exists($credentialFile)) { return }
    try {
        $previous = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($report))
        $failureAt = [string]$previous.AuthLastAttempt
        if (-not $failureAt -and $previous.Result -in @('ChallengeRejected', 'LoginRejected', 'LoginRequestFailed', 'LoginNotConfirmed')) {
            $failureAt = [string]$previous.At
        }
        if (-not $failureAt) { return }
        $lastAttempt = [DateTimeOffset]::Parse($failureAt).UtcDateTime
        if ([IO.File]::GetLastWriteTimeUtc($credentialFile) -gt $lastAttempt) { return }
        $failures = 1
        if ($previous.AuthFailures -ge 1) {
            $failures = [Math]::Min([int]$previous.AuthFailures, 3)
        }
        $minutes = @(5, 15, 60)[$failures - 1]
        return [pscustomobject]@{
            AuthFailures = $failures
            AuthLastAttempt = $failureAt
            RetryAfterUtc = $lastAttempt.AddMinutes($minutes)
        }
    } catch {
        # A missing or malformed status file must not prevent reconnecting.
    }
}

function Complete-ChdRun {
    param([string]$Result, [int]$ExitCode = 0, [string]$PortalCode = '')
    $record = [ordered]@{
        Result = $Result
        PortalCode = $PortalCode
        At = [DateTimeOffset]::Now.ToString('o')
        RunAsSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
    $previousFailure = Get-ChdRetryState
    if ($Result -in @('ChallengeRejected', 'LoginRejected', 'LoginRequestFailed', 'LoginNotConfirmed')) {
        $record['AuthFailures'] = if ($previousFailure) { [Math]::Min($previousFailure.AuthFailures + 1, 3) } else { 1 }
        $record['AuthLastAttempt'] = $record['At']
    } elseif ($Result -notin @('AlreadyOnline', 'Authenticated') -and $previousFailure) {
        $record['AuthFailures'] = $previousFailure.AuthFailures
        $record['AuthLastAttempt'] = $previousFailure.AuthLastAttempt
    }
    $record = $record | ConvertTo-Json -Compress
    if (-not $Probe) {
        $report = Join-Path $script:ChdDataDir 'Status\last-run.json'
        $staging = $report + '.new'
        try {
            [IO.File]::WriteAllText($staging, $record)
            if ([IO.File]::Exists($report)) {
                [IO.File]::Replace($staging, $report, [NullString]::Value)
            } else {
                [IO.File]::Move($staging, $report)
            }
        } catch {
            # The task result remains available if a status file could not be written.
        }
    }
    Write-Output $record
    exit $ExitCode
}

if ($MyInvocation.InvocationName -eq '.') { return }

try {
    $deadline = [DateTime]::UtcNow.AddSeconds(80)
    do {
        $wifi = Get-ChdWifiLink
        if ($wifi -or $Probe -or [DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Seconds 5
    } while ($true)
    if (-not $wifi) { Complete-ChdRun 'CampusWifiNotConnected' }

    $portal = $null
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            $portal = Get-ChdPortalStatus $wifi
            break
        } catch {
            if ($Probe -or $attempt -eq 2) {
                $diagnostic = [regex]::Match($_.Exception.Message, '^PortalStatusUnavailable:([a-zA-Z0-9,-]+)$').Groups[1].Value
                Complete-ChdRun 'PortalUnavailable' 10 $diagnostic
            }
            Start-Sleep -Seconds 5
        }
    }
    if ($Probe) { Complete-ChdRun $portal.State }

    if ($portal.State -eq 'Online') { Complete-ChdRun 'AlreadyOnline' }

    $retry = Get-ChdRetryState
    if ($retry -and [DateTime]::UtcNow -lt $retry.RetryAfterUtc) {
        # Keep the previous failure timestamp so the delay eventually expires.
        Write-Output '{"Result":"LoginRetryDeferred"}'
        exit 0
    }
    try { $credential = Read-ChdCredential }
    catch { Complete-ChdRun 'CredentialUnavailable' 11 }

    try { $script:ChdAcId = Get-ChdAcIdFromCredential $credential }
    catch { Complete-ChdRun 'CredentialUnavailable' 11 }

    try {
        $token = Invoke-ChdPortal $wifi $portal.Address '/cgi-bin/get_challenge' @{
            username = $credential.Username
            ip = $wifi
        }
        if ($token.error -ne 'ok' -or $token.challenge -notmatch '^[\x21-\x7e]{8,128}$') {
            Complete-ChdRun 'ChallengeRejected' 12
        }
        $login = New-ChdLoginFields $credential.Username $credential.Password $wifi $token.challenge
        $reply = Invoke-ChdPortal $wifi $portal.Address '/cgi-bin/srun_portal' $login
        if ($reply.error -ne 'ok' -and $reply.error_msg -ne 'ip_already_online_error') {
            $portalCode = if ($reply.ecode -match '^E[0-9]{3,6}$') { $reply.ecode } else { '' }
            Complete-ChdRun 'LoginRejected' 13 $portalCode
        }
    } catch {
        Complete-ChdRun 'LoginRequestFailed' 14
    } finally {
        Remove-Variable credential,login,token -ErrorAction SilentlyContinue
    }
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        Start-Sleep -Seconds 2
        try {
            if ((Get-ChdPortalStatus $wifi).State -eq 'Online') { Complete-ChdRun 'Authenticated' }
        } catch {}
    }
    Complete-ChdRun 'LoginNotConfirmed' 15
} catch {
    Complete-ChdRun 'WifiCheckFailed' 16
}
