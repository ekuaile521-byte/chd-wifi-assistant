[CmdletBinding()]
param([switch]$Repair)

$ErrorActionPreference = 'Stop'
$windowsPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argsForAdmin = '-NoProfile -STA -ExecutionPolicy RemoteSigned -File "' + $PSCommandPath + '"'
    if ($Repair) { $argsForAdmin += ' -Repair' }
    try {
        $adminProcess = Start-Process -FilePath $windowsPs -ArgumentList $argsForAdmin -Verb RunAs -WindowStyle Normal -Wait -PassThru
        exit $adminProcess.ExitCode
    } catch {
        Write-Output '未取得 Windows 管理员权限。'
        exit 1
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'Invoke-ChdWifiAuth.ps1')

function Show-ChdMessage([string]$Text, [Windows.Forms.MessageBoxIcon]$Icon) {
    [void][Windows.Forms.MessageBox]::Show($Text, '长安大学校园网助手', 'OK', $Icon)
}

function Read-ChdSetupInput([string]$AccountHint) {
    $form = [Windows.Forms.Form]::new()
    $form.Text = '长安大学校园网助手'
    $form.ClientSize = [Drawing.Size]::new(496, 294)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.AutoScaleMode = 'Dpi'
    $form.Font = [Drawing.Font]::new('Microsoft YaHei UI', 10)

    $intro = [Windows.Forms.Label]::new()
    $intro.Text = '输入一次校园网账号和密码，点击启用。密码由 Windows 加密保存在本机；已有配置会被更新。'
    $intro.SetBounds(18, 14, 460, 49)

    $userLabel = [Windows.Forms.Label]::new()
    $userLabel.Text = '校园网账号'
    $userLabel.SetBounds(18, 75, 104, 26)
    $accountBox = [Windows.Forms.TextBox]::new()
    $accountBox.SetBounds(125, 73, 350, 28)
    $accountBox.Text = $AccountHint
    $accountBox.MaxLength = 120

    $passwordLabel = [Windows.Forms.Label]::new()
    $passwordLabel.Text = '校园网密码'
    $passwordLabel.SetBounds(18, 115, 104, 26)
    $passwordBox = [Windows.Forms.TextBox]::new()
    $passwordBox.SetBounds(125, 113, 350, 28)
    $passwordBox.UseSystemPasswordChar = $true
    $passwordBox.MaxLength = 256

    $acIdLabel = [Windows.Forms.Label]::new()
    $acIdLabel.Text = '认证编号'
    $acIdLabel.SetBounds(18, 155, 104, 26)
    $acIdBox = [Windows.Forms.TextBox]::new()
    $acIdBox.SetBounds(125, 153, 82, 28)
    $acIdBox.Text = '5'
    $acIdBox.MaxLength = 6
    $acIdHelp = [Windows.Forms.Label]::new()
    $acIdHelp.Text = '认证网址中的 ac_id；不同区域可能不同。'
    $acIdHelp.SetBounds(214, 155, 260, 42)

    $install = [Windows.Forms.Button]::new()
    $install.Text = '启用开机认证'
    $install.SetBounds(249, 236, 135, 36)
    $install.Add_Click({
        if ([string]::IsNullOrWhiteSpace($accountBox.Text) -or -not $passwordBox.TextLength) {
            Show-ChdMessage '请填入校园网账号和密码。' 'Warning'
            return
        }
        if ($acIdBox.Text -notmatch '^[0-9]{1,6}$') {
            Show-ChdMessage '认证编号应为 1 至 6 位数字。' 'Warning'
            return
        }
        $form.DialogResult = [Windows.Forms.DialogResult]::OK
    })

    $cancel = [Windows.Forms.Button]::new()
    $cancel.Text = '取消'
    $cancel.SetBounds(393, 236, 82, 36)
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $form.AcceptButton = $install
    $form.CancelButton = $cancel
    $form.Controls.AddRange(@($intro, $userLabel, $accountBox, $passwordLabel, $passwordBox, $acIdLabel, $acIdBox, $acIdHelp, $install, $cancel))
    $form.Add_Shown({
        $form.BringToFront()
        [void]$form.Activate()
        if ($accountBox.TextLength) { [void]$passwordBox.Focus() }
        else { [void]$accountBox.Focus() }
    })

    $timer = [Windows.Forms.Timer]::new()
    $timer.Interval = 300000
    $timer.Add_Tick({ $form.DialogResult = [Windows.Forms.DialogResult]::Cancel })
    $timer.Start()
    try {
        if ($form.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
            [pscustomobject]@{ Username = $accountBox.Text.Trim(); Password = $passwordBox.Text; AcId = $acIdBox.Text.Trim() }
        }
    } finally {
        $timer.Stop()
        $timer.Dispose()
        $passwordBox.Clear()
        $form.Dispose()
    }
}

function Enable-ChdWifiAutoConnect {
    $netsh = Join-Path $env:SystemRoot 'System32\netsh.exe'
    $enabled = 0
    foreach ($name in @('CHD-WiFi', 'CHD_WiFi')) {
        $process = [Diagnostics.Process]::new()
        $process.StartInfo.FileName = $netsh
        $process.StartInfo.Arguments = 'wlan set profileparameter name="{0}" connectionmode=auto' -f $name
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        try {
            if ($process.Start()) {
                $stdout = $process.StandardOutput.ReadToEndAsync()
                $stderr = $process.StandardError.ReadToEndAsync()
                if ($process.WaitForExit(10000)) {
                    $null = $stdout.GetAwaiter().GetResult()
                    $null = $stderr.GetAwaiter().GetResult()
                    if ($process.ExitCode -eq 0) { $enabled++ }
                } else { $process.Kill() }
            }
        } catch {
            # The setup message tells users when no saved campus profile was changed.
        } finally { $process.Dispose() }
    }
    return $enabled -gt 0
}

function Initialize-ChdDirectory {
    param([string]$Path, [Security.AccessControl.FileSystemRights]$ServiceRights, [switch]$ReadStatus)

    $admins = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $localService = [Security.Principal.SecurityIdentifier]::new('S-1-5-19')
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($admins)
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    foreach ($entry in @(
        @{ Sid = $admins; Rights = 'FullControl' },
        @{ Sid = $system; Rights = 'FullControl' },
        @{ Sid = $localService; Rights = $ServiceRights }
    )) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $entry.Sid, $entry.Rights, $inherit, 'None', 'Allow'))
    }
    if ($ReadStatus) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $identity.User, 'ReadAndExecute', $inherit, 'None', 'Allow'))
    }

    if (Test-Path -LiteralPath $Path) {
        $existing = Get-Item -LiteralPath $Path -Force
        if (-not $existing.PSIsContainer -or $existing.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'UnexpectedInstallDirectory'
        }
        $existingAcl = Get-Acl -LiteralPath $Path
        if ($existingAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @($admins.Value, $system.Value)) {
            throw 'UnexpectedInstallDirectoryOwner'
        }
        Set-Acl -LiteralPath $Path -AclObject $acl
    } else {
        $null = [IO.Directory]::CreateDirectory($Path, $acl)
    }
}

function Register-ChdTask([string]$WorkerPath) {
    $scheduler = New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    $root = $scheduler.GetFolder('\')
    $task = $scheduler.NewTask(0)
    $task.RegistrationInfo.Description = 'Connect this computer to the CHD-WiFi access portal before Windows sign-in.'
    $localService = [Security.Principal.SecurityIdentifier]::new('S-1-5-19').Translate([Security.Principal.NTAccount]).Value
    $task.Principal.UserId = $localService
    $task.Principal.LogonType = 5
    $task.Principal.RunLevel = 0
    $task.Settings.DisallowStartIfOnBatteries = $false
    $task.Settings.StopIfGoingOnBatteries = $false
    $task.Settings.RunOnlyIfNetworkAvailable = $false
    $task.Settings.StartWhenAvailable = $true
    $task.Settings.MultipleInstances = 2
    $task.Settings.ExecutionTimeLimit = 'PT4M'

    $boot = $task.Triggers.Create(8)
    $boot.Id = 'WindowsBoot'
    $boot.Delay = 'PT12S'
    $network = $task.Triggers.Create(0)
    $network.Id = 'CampusWifiConnected'
    $network.Delay = 'PT5S'
    $network.Subscription = @'
<QueryList><Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational">
<Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[EventID=10000]] and *[EventData[Data[@Name='Name']='CHD-WiFi' or Data[@Name='Name']='CHD_WiFi']]</Select>
</Query></QueryList>
'@
    $check = $task.Triggers.Create(2)
    $check.Id = 'CampusAuthenticationCheck'
    $check.StartBoundary = (Get-Date).AddMinutes(2).ToString('yyyy-MM-ddTHH:mm:ss')
    $check.DaysInterval = 1
    $check.Repetition.Interval = 'PT2M'
    $check.Repetition.Duration = 'P1D'
    $check.Repetition.StopAtDurationEnd = $false
    $action = $task.Actions.Create(0)
    $action.Path = $windowsPs
    $action.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "' + $WorkerPath + '"'
    $action.WorkingDirectory = $script:ChdDataDir
    $root.RegisterTaskDefinition('CHD Wi-Fi Auto Authentication', $task, 6, $localService, $null, 5, $null)
}

$stage = '检查现有配置'
$worker = Join-Path $script:ChdDataDir 'Invoke-ChdWifiAuth.ps1'
$credentialFile = Join-Path $script:ChdDataDir 'credential.bin'
$createdTask = $false
$wroteCredential = $false
$previous = Get-ScheduledTask -TaskName 'CHD Wi-Fi Auto Authentication' -TaskPath '\' -ErrorAction SilentlyContinue
if ($Repair) {
    if (-not $previous -or -not (Test-Path -LiteralPath $credentialFile)) {
        Show-ChdMessage '没有找到已安装的开机任务或加密配置。' 'Warning'
        exit 1
    }
} else {
    $accountHint = ''
    try {
        $link = Get-ChdWifiLink
        if ($link) {
            $status = Get-ChdPortalStatus $link
            if ($status.State -eq 'Online') {
                $accountHint = [string]$status.Response.user_name
                if ($status.Response.domain -and $accountHint -notmatch '@') {
                    $accountHint += '@' + ([string]$status.Response.domain).TrimStart('@')
                }
            }
        }
    } catch {
        # Enrollment can be done away from campus, with the account entered manually.
    }
    $entered = Read-ChdSetupInput $accountHint
    if (-not $entered) { exit 2 }
}

try {
    if ($previous -and -not ($previous.Actions.Arguments -match [regex]::Escape($worker))) {
        throw 'UnexpectedExistingTask'
    }

    $stage = '设置安装目录权限'
    Initialize-ChdDirectory $script:ChdDataDir 'ReadAndExecute'
    Initialize-ChdDirectory (Join-Path $script:ChdDataDir 'Status') 'Modify' -ReadStatus
    foreach ($file in @('Invoke-ChdWifiAuth.ps1', 'Invoke-ChdWifiAuth.ps1.new', 'SrunCrypto.cs', 'SrunCrypto.cs.new', 'ChdDns.cs', 'ChdDns.cs.new', 'credential.bin', 'credential.bin.new')) {
        $dest = Join-Path $script:ChdDataDir $file
        if (Test-Path -LiteralPath $dest) {
            $existingFile = Get-Item -LiteralPath $dest -Force
            if ($existingFile.PSIsContainer -or ($existingFile.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'UnexpectedInstallFile'
            }
        }
    }
    # Copy dependencies first and atomically replace each file, leaving an existing
    # worker intact until the files it needs are available.
    foreach ($file in @('ChdDns.cs', 'SrunCrypto.cs', 'Invoke-ChdWifiAuth.ps1')) {
        $dest = Join-Path $script:ChdDataDir $file
        $staging = $dest + '.new'
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $staging -Force
        if ([IO.File]::Exists($dest)) {
            [IO.File]::Replace($staging, $dest, [NullString]::Value)
        } else {
            [IO.File]::Move($staging, $dest)
        }
    }

    if (-not $Repair) {
        $stage = '加密保存校园网凭据'
        Add-Type -AssemblyName System.Security
        $plain = [Text.Encoding]::UTF8.GetBytes(($entered | ConvertTo-Json -Compress))
        try {
            $protected = [Security.Cryptography.ProtectedData]::Protect($plain, $script:ChdEntropy, 'LocalMachine')
            $staging = $credentialFile + '.new'
            [IO.File]::WriteAllBytes($staging, $protected)
            if ([IO.File]::Exists($credentialFile)) {
                [IO.File]::Replace($staging, $credentialFile, [NullString]::Value)
            } else {
                [IO.File]::Move($staging, $credentialFile)
            }
            $wroteCredential = $true
        } finally {
            [Array]::Clear($plain, 0, $plain.Length)
            Remove-Variable entered -ErrorAction SilentlyContinue
        }
    }

    $stage = '设置校园 Wi-Fi 自动连接'
    $null = Enable-ChdWifiAutoConnect
    $stage = '登记开机任务'
    $task = Register-ChdTask $worker
    $createdTask = $true
    $stage = '启动验证'
    $started = [DateTime]::UtcNow
    $null = $task.Run($null)
    $report = Join-Path $script:ChdDataDir 'Status\last-run.json'
    $checked = $null
    $waitLimit = if ($Repair) { 65 } else { 18 }
    for ($wait = 0; $wait -lt $waitLimit; $wait++) {
        if (Test-Path -LiteralPath $report) {
            if ((Get-Item -LiteralPath $report).LastWriteTimeUtc -ge $started.AddSeconds(-1)) {
                $checked = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
                break
            }
        }
        Start-Sleep -Seconds 1
    }
    $wifiHint = "`n`n请确保已在 Windows 中连接过校园 Wi-Fi，并勾选自动连接。"
    if ($checked.Result -in @('AlreadyOnline', 'Authenticated')) {
        Show-ChdMessage ('开机认证已启用。后台任务已运行，校园网当前在线。' + $wifiHint) 'Information'
    } elseif ($checked -and $checked.Result -ne 'CampusWifiNotConnected') {
        Show-ChdMessage ('开机任务已保存，本次运行需要检查：' + $checked.Result + $wifiHint) 'Warning'
    } else {
        Show-ChdMessage ('开机认证任务已启用。电脑连接校园 Wi-Fi 后会运行认证。' + $wifiHint) 'Information'
    }
    exit 0
} catch {
    if (-not $createdTask -and -not $previous -and $wroteCredential) {
        Remove-Item -LiteralPath $credentialFile -ErrorAction SilentlyContinue
    }
    if ($createdTask) {
        Show-ChdMessage '开机任务已保存，但未完成本次运行验证。' 'Warning'
    } else {
        Show-ChdMessage ('配置未完成，当前步骤：' + $stage) 'Error'
    }
    exit 1
}
