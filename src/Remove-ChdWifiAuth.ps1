[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$title = '长安大学校园网助手'
$taskName = 'CHD Wi-Fi Auto Authentication'
$dataDir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ChdWifiAutoAuth'
$expectedWorker = Join-Path $dataDir 'Invoke-ChdWifiAuth.ps1'

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'AdministratorRequired' }

    if (Test-Path -LiteralPath $dataDir) {
        $dir = Get-Item -LiteralPath $dataDir -Force
        if (-not $dir.PSIsContainer -or ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'UnexpectedDirectory' }
        $statusDir = Join-Path $dataDir 'Status'
        if (Test-Path -LiteralPath $statusDir) {
            $statusItem = Get-Item -LiteralPath $statusDir -Force
            if (-not $statusItem.PSIsContainer -or ($statusItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'UnexpectedStatusDirectory' }
        }
        foreach ($relative in @('credential.bin', 'credential.bin.new', 'Invoke-ChdWifiAuth.ps1', 'Invoke-ChdWifiAuth.ps1.new', 'SrunCrypto.cs', 'SrunCrypto.cs.new', 'ChdDns.cs', 'ChdDns.cs.new', 'Status\last-run.json', 'Status\last-run.json.new')) {
            $path = Join-Path $dataDir $relative
            if (Test-Path -LiteralPath $path) {
                $item = Get-Item -LiteralPath $path -Force
                if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'UnexpectedFile' }
            }
        }
    }

    $scheduler = New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    $root = $scheduler.GetFolder('\')
    $task = $null
    try { $task = $root.GetTask($taskName) }
    catch {
        # An absent task is harmless; permission and scheduler errors are not.
        if ($_.Exception.GetBaseException().HResult -notin @(-2147024894, -2147024893)) { throw }
    }
    if ($task) {
        $matchesWorker = $false
        foreach ($action in $task.Definition.Actions) {
            if ($action.Arguments -match [regex]::Escape($expectedWorker)) { $matchesWorker = $true }
        }
        if (-not $matchesWorker) { throw 'UnexpectedTask' }
        if ($task.State -eq 4) {
            $task.Stop(0)
            for ($attempt = 0; $attempt -lt 10 -and $task.State -eq 4; $attempt++) { Start-Sleep -Milliseconds 500 }
            if ($task.State -eq 4) { throw 'TaskStillRunning' }
        }
        $root.DeleteTask($taskName, 0)
    }
    foreach ($relative in @('credential.bin', 'credential.bin.new', 'Invoke-ChdWifiAuth.ps1', 'Invoke-ChdWifiAuth.ps1.new', 'SrunCrypto.cs', 'SrunCrypto.cs.new', 'ChdDns.cs', 'ChdDns.cs.new', 'Status\last-run.json', 'Status\last-run.json.new')) {
        $path = Join-Path $dataDir $relative
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    foreach ($path in @((Join-Path $dataDir 'Status'), $dataDir)) {
        if (Test-Path -LiteralPath $path) {
            try { [IO.Directory]::Delete($path, $false) } catch { }
        }
    }
    [void][Windows.Forms.MessageBox]::Show('已移除自动认证任务和保存的校园网账号凭据。Wi-Fi 配置保留在 Windows 中。', $title, 'OK', 'Information')
    exit 0
} catch {
    [void][Windows.Forms.MessageBox]::Show('未能完全移除配置。请确认使用管理员权限，并检查校园网助手的文件与任务。', $title, 'OK', 'Error')
    exit 1
}
