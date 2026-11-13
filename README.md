# 长安大学校园网助手

一个用于 Windows 的校园网自动认证工具。用户在图形界面中填写一次校园网账号、密码和认证编号，授权后由 Windows 在后台执行认证与定期检查。

> **测试版：** 当前已完成离线逻辑检查和界面构建，并在一台已联网的校园网电脑上通过只读在线状态探测。尚未在未认证冷启动、手机一键下线后的恢复、后台服务账户、不同校区及不同账号类型下完成真实环境验证，请勿将它作为远程访问的唯一保障。

这不是长安大学官方软件。首版只针对长安大学 `CHD-WiFi` / `CHD_WiFi` 与 `beiradius.chd.edu.cn` 深澜认证设计，不承诺兼容其他学校或今后的认证系统变更。

## 能做什么

- 尝试把已保存的校园 Wi-Fi 配置设为自动连接。
- 注册 Windows 开机任务：开机后和连接校园网时触发，并每两分钟检查一次认证状态。
- 发现校园网未认证时尝试登录；遇到认证失败会退避重试，延迟依次为 5、15、60 分钟。
- 优先通过当前校园网网卡查询 DNS 服务器，过滤常见代理虚拟地址，必要时回退到系统 DNS。
- 查看最近一次后台运行结果；通过“移除配置”删除本工具的计划任务和本地凭据。

上述是程序的设计行为，不保证 Wi-Fi 信号、校园网服务或认证一定可用。Windows 必须先连上校园 Wi-Fi 才能进行认证；如果系统连上的是其他网络、网卡未就绪或 Wi-Fi 配置仅对当前用户可用，登录 Windows 前可能无法联网。

## 使用

1. 在 Windows 10 或 11 中先手动连接一次 `CHD-WiFi` 或 `CHD_WiFi`，并勾选“自动连接”。如需登录 Windows 前运行，确认该 Wi-Fi 配置允许所有用户使用。
2. 双击 `CHD-WiFi-Assistant.exe`，点击“配置并启用”，在 Windows 管理员权限提示中选择允许。
3. 输入校园网上网账号和密码。认证编号是认证成功网址中 `ac_id=` 后面的数字，例如 `?ac_id=5` 对应 `5`；不同校区、网络或位置可能使用其他值。完成后点击“启用开机认证”。
4. 程序会显示计划任务是否登记及本次运行结果。可以返回主界面点击“查看上次状态”；状态有记录时间，不能代表此刻的实时联网状况。

如果电脑已有同名校园网自动认证任务和配置，重新配置会更新该任务、运行文件和保存的凭据；移除配置也会删除这套同名任务及凭据。

配置时需要管理员权限，因为创建开机触发任务需要该权限。账号密码只在本机界面输入，请勿在 Issue、聊天、截图或公开日志中发送。

## 凭据与系统改动

- 保存位置：`%ProgramData%\ChdWifiAutoAuth\credential.bin`。凭据使用 Windows DPAPI 的机器范围加密，目录 ACL 限制访问；后台使用 Windows `LocalService` 运行。
- 机器范围加密不是对本机管理员的保护：管理员或能以高权限运行的恶意程序仍可能读取或解密凭据；认证时凭据也会短暂出现在进程内存中。
- 程序与校园网认证服务器通信；不会将密码作为命令行参数，也不需要第三方账号服务。
- 创建的任务名为 `CHD Wi-Fi Auto Authentication`。工具尝试将已保存的两个校园 Wi-Fi 配置设为自动连接，不会创建未知安全类型的 Wi-Fi 配置。
- 点击“移除配置”并确认后，删除该任务及本工具保存的凭据和相关文件，不删除 Windows 保存的 Wi-Fi 配置。
- EXE 为本地构建的未签名程序。仅在信任源码和构建来源时运行；本项目不会要求关闭杀毒软件或绕过组织策略。

## 从源码构建与验证

需要 Windows、Windows PowerShell 5.1、系统自带的 .NET Framework C# 编译器及 `curl.exe`。无需安装 Python、浏览器或 .NET SDK。PowerShell 执行策略或学校管理策略可能限制运行。

在项目目录中运行：

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File .\tests\Offline.Tests.ps1
```

产物为 `dist\CHD-WiFi-Assistant.exe`。离线测试使用模拟网络数据，不连接或注销校园网、不注册计划任务；通过测试不等于真实网络认证成功。

运行 `package.ps1` 可生成包含软件的 Windows ZIP、仅含源码的 ZIP，以及用于核对文件完整性的 SHA-256 列表。校验值本身不能证明文件来源可信。

## 文件

- `src/Launcher.cs`：Windows 图形入口及程序组件打包。
- `src/Install-ChdWifiAuth.ps1`：输入凭据、保护本地文件和设置任务。
- `src/Invoke-ChdWifiAuth.ps1`：校园网状态检测、认证与重试。
- `src/SrunCrypto.cs`：深澜认证协议相关计算。
- `src/ChdDns.cs`：通过校园网卡查询 DNS 的网络辅助代码。
- `src/Remove-ChdWifiAuth.ps1`：移除任务和已保存凭据。

提交 Issue 时，请先删除账号、密码、校内 IP、Cookie、令牌和其他个人信息。

## 许可证

[MIT License](LICENSE)。
