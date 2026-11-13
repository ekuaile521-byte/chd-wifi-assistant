using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace ChdWifiAssistant
{
    internal static class Program
    {
        private const string ProductName = "长安大学校园网助手";
        private static readonly string[] Payload = {
            "Install-ChdWifiAuth.ps1", "Invoke-ChdWifiAuth.ps1", "SrunCrypto.cs", "ChdDns.cs", "Remove-ChdWifiAuth.ps1"
        };

        [STAThread]
        private static int Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            if (args.Length == 1 && (args[0] == "--install-elevated" || args[0] == "--remove-elevated"))
            {
                if (!IsAdministrator())
                {
                    MessageBox.Show("请从主界面打开配置，并在系统提示时允许管理员权限。", ProductName,
                        MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return 1;
                }
                return RunPayload(args[0] == "--install-elevated" ? "Install-ChdWifiAuth.ps1" : "Remove-ChdWifiAuth.ps1");
            }
            Application.Run(new MainForm());
            return 0;
        }

        private static bool IsAdministrator()
        {
            using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
                return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
        }

        internal static void RequestElevated(string argument)
        {
            try
            {
                ProcessStartInfo info = new ProcessStartInfo(Application.ExecutablePath, argument);
                info.UseShellExecute = true;
                info.Verb = "runas";
                Process.Start(info);
            }
            catch (System.ComponentModel.Win32Exception ex)
            {
                if (ex.NativeErrorCode == 1223)
                    MessageBox.Show("未获得管理员权限，配置没有改变。", ProductName, MessageBoxButtons.OK, MessageBoxIcon.Information);
                else
                    MessageBox.Show("无法启动配置程序，请重试。", ProductName, MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            catch (Exception)
            {
                MessageBox.Show("无法启动配置程序，请重试。", ProductName, MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private static int RunPayload(string script)
        {
            string folder = Path.Combine(Path.GetTempPath(), "ChdWifiAssistant-" + Guid.NewGuid().ToString("N"));
            try
            {
                DirectorySecurity acl = new DirectorySecurity();
                acl.SetAccessRuleProtection(true, false);
                InheritanceFlags inherit = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
                using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
                {
                    SecurityIdentifier[] allowed = {
                        identity.User,
                        new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null),
                        new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null)
                    };
                    foreach (SecurityIdentifier sid in allowed)
                        acl.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, inherit,
                            PropagationFlags.None, AccessControlType.Allow));
                }
                Directory.CreateDirectory(folder, acl);

                Assembly assembly = Assembly.GetExecutingAssembly();
                foreach (string name in Payload)
                {
                    using (Stream source = assembly.GetManifestResourceStream("ChdWifiAssistant.Payload." + name))
                    {
                        if (source == null) throw new InvalidDataException("A program component is missing.");
                        using (FileStream destination = new FileStream(Path.Combine(folder, name), FileMode.CreateNew, FileAccess.Write, FileShare.None))
                            source.CopyTo(destination);
                    }
                }
                string system = Environment.GetFolderPath(Environment.SpecialFolder.System);
                string powershell = Path.Combine(system, @"WindowsPowerShell\v1.0\powershell.exe");
                ProcessStartInfo start = new ProcessStartInfo(powershell,
                    "-NoProfile -STA -ExecutionPolicy RemoteSigned -File \"" + Path.Combine(folder, script) + "\"");
                start.UseShellExecute = false;
                start.CreateNoWindow = true;
                start.WorkingDirectory = folder;
                using (Process process = Process.Start(start))
                {
                    if (process == null) throw new InvalidOperationException("PowerShell did not start.");
                    process.WaitForExit();
                    return process.ExitCode;
                }
            }
            catch (Exception)
            {
                MessageBox.Show("程序无法准备配置组件，请确认 Windows PowerShell 可用后重试。", ProductName,
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
            finally
            {
                foreach (string name in Payload)
                {
                    try { File.Delete(Path.Combine(folder, name)); } catch (Exception) { }
                }
                try { Directory.Delete(folder, false); } catch (Exception) { }
            }
        }
    }

    internal sealed class MainForm : Form
    {
        private readonly Label statusLabel;
        private static readonly Color Ink = Color.FromArgb(28, 42, 62);
        private static readonly Color Accent = Color.FromArgb(31, 106, 190);

        internal MainForm()
        {
            Text = "长安大学校园网助手";
            ClientSize = new Size(680, 460);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.FromArgb(246, 249, 253);
            ForeColor = Ink;
            Font = new Font("Microsoft YaHei UI", 10F);
            AutoScaleMode = AutoScaleMode.Dpi;

            Label eyebrow = MakeLabel("CHD  /  CAMPUS WIFI", 32, 24, 580, 24, 9F, FontStyle.Bold, Accent);
            Label title = MakeLabel("校园网助手", 30, 52, 610, 48, 21F, FontStyle.Bold, Ink);
            Label intro = MakeLabel("保存一次账号，开机后自动认证，并定期检查连接状态。", 32, 108, 610, 38, 10F, FontStyle.Regular, Color.FromArgb(85, 101, 121));
            Label preparation = MakeLabel("开始前：请先在 Windows 中连接过校园 Wi-Fi。", 32, 157, 610, 32, 10F, FontStyle.Regular, Ink);

            Button install = MakeButton("配置并启用", 32, 205, 180, 48, true);
            install.Click += delegate { Program.RequestElevated("--install-elevated"); };
            Button check = MakeButton("查看上次状态", 224, 205, 160, 48, false);
            check.Click += delegate { RefreshStatus(); };
            Button remove = MakeButton("移除配置", 396, 205, 130, 48, false);
            remove.Click += delegate {
                DialogResult result = MessageBox.Show("将移除开机认证任务和本机保存的校园网账号凭据。\n\n确定继续吗？",
                    "移除配置", MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2);
                if (result == DialogResult.Yes) Program.RequestElevated("--remove-elevated");
            };

            Label statusTitle = MakeLabel("最近一次运行", 32, 286, 600, 28, 10F, FontStyle.Bold, Ink);
            statusLabel = MakeLabel("尚未读取状态。", 32, 320, 610, 68, 10F, FontStyle.Regular, Color.FromArgb(85, 101, 121));
            Label footer = MakeLabel("配置时需要管理员授权；认证依赖校园 Wi-Fi 和学校服务器可用。", 32, 413, 610, 28, 9F, FontStyle.Regular, Color.FromArgb(104, 120, 139));
            Controls.AddRange(new Control[] { eyebrow, title, intro, preparation, install, check, remove, statusTitle, statusLabel, footer });
            Shown += delegate { RefreshStatus(); };
        }

        private static Label MakeLabel(string text, int x, int y, int width, int height, float size, FontStyle style, Color color)
        {
            Label label = new Label();
            label.Text = text;
            label.SetBounds(x, y, width, height);
            label.Font = new Font("Microsoft YaHei UI", size, style);
            label.ForeColor = color;
            label.BackColor = Color.Transparent;
            return label;
        }

        private static Button MakeButton(string text, int x, int y, int width, int height, bool primary)
        {
            Button button = new Button();
            button.Text = text;
            button.SetBounds(x, y, width, height);
            button.FlatStyle = FlatStyle.Flat;
            button.FlatAppearance.BorderSize = primary ? 0 : 1;
            button.FlatAppearance.BorderColor = Color.FromArgb(198, 211, 226);
            button.BackColor = primary ? Accent : Color.White;
            button.ForeColor = primary ? Color.White : Ink;
            button.Cursor = Cursors.Hand;
            return button;
        }

        private void RefreshStatus()
        {
            try
            {
                string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                    @"ChdWifiAutoAuth\Status\last-run.json");
                Dictionary<string, object> report = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(path));
                string result = report.ContainsKey("Result") ? Convert.ToString(report["Result"]) : "";
                string time = report.ContainsKey("At") ? Convert.ToString(report["At"]) : "";
                DateTimeOffset parsed;
                string shownTime = DateTimeOffset.TryParse(time, out parsed) ? parsed.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss") : "时间未知";
                statusLabel.Text = Describe(result) + "\n记录时间：" + shownTime + "（可能不是当前实时状态）";
            }
            catch (FileNotFoundException)
            {
                statusLabel.Text = "还没有运行记录。配置后可再次查看。";
            }
            catch (DirectoryNotFoundException)
            {
                statusLabel.Text = "还没有运行记录。配置后可再次查看。";
            }
            catch (UnauthorizedAccessException)
            {
                statusLabel.Text = "当前用户无法读取运行记录。";
            }
            catch (Exception)
            {
                statusLabel.Text = "运行记录暂时不可用。";
            }
        }

        internal static string Describe(string result)
        {
            switch (result)
            {
                case "AlreadyOnline": return "当时校园网已在线。";
                case "Authenticated": return "当时自动认证成功。";
                case "CampusWifiNotConnected": return "当时未连接到校园 Wi-Fi。";
                case "PortalUnavailable": return "当时无法访问校园网认证服务器。";
                case "CredentialUnavailable": return "无法读取保存的认证信息，请重新配置。";
                case "ChallengeRejected": return "认证准备步骤失败，请稍后重试。";
                case "LoginRejected": return "学校服务器拒绝了认证，请检查账号、密码和认证编号。";
                case "LoginRequestFailed": return "认证请求未完成，请检查校园网连接。";
                case "LoginNotConfirmed": return "已尝试认证，但尚未确认成功。";
                case "WifiCheckFailed": return "无法检查校园 Wi-Fi 的状态。";
                default: return "存在运行记录，但状态暂时无法识别。";
            }
        }
    }
}
