using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Threading;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace RimeQ {
    internal static class Program {
        static Application app;
        static SettingsWindow settings;
        static bool exiting;
        internal static void Uninstall() {
            using (var machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
            using (var key = machine.OpenSubKey(@"Software\RimeQ")) {
                var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "RimeQ");
                var installer = Path.Combine(root, "RimeQ.Setup.exe");
                if (key == null || !File.Exists(installer) || FileVersionInfo.GetVersionInfo(installer).ProductName != "Rime Q")
                    throw new IOException("未找到已安装的 Rime Q。开发目录无需卸载。");
                Paths.OpenWithArguments(installer, "--uninstall");
            }
        }
        [STAThread]
        static int Main(string[] arguments) {
            try {
                System.Net.ServicePointManager.SecurityProtocol = System.Net.SecurityProtocolType.Tls12;
                Directory.CreateDirectory(Paths.Root);
                var action = arguments.Length == 0 ? "--settings" : arguments[0];
                if (action == "--data") { Paths.Open(Paths.Root); return 0; }
                if (action == "--help") { Paths.Open(Path.Combine(Paths.App, "help", "index.html")); return 0; }
                if (action == "--uninstall") { Uninstall(); return 0; }
                if (action == "--version") { return 0; }
                string identity = WindowsIdentity.GetCurrent().User.Value;
                string prefix = @"Local\RimeQ.Settings." + identity + ".";
                if (action == "--quit") {
                    try { using (var quit = EventWaitHandle.OpenExisting(prefix + "Quit")) quit.Set(); } catch (WaitHandleCannotBeOpenedException) { }
                    return 0;
                }
                // Startup is registered only by the installed, unelevated user application.
                using (var machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
                using (var installed = machine.OpenSubKey(@"Software\RimeQ")) {
                    var active = installed == null ? null : installed.GetValue("ActiveDirectory") as string;
                    if (active != null && string.Equals(Path.GetFullPath(active).TrimEnd('\\'), Paths.App.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
                        using (var run = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))
                            run.SetValue("RimeQ", "\"" + Path.Combine(Paths.App, "RimeQ.exe") + "\" --background");
                }
                bool created;
                using (var mutex = new Mutex(true, prefix + "Owner", out created)) {
                    if (!created) {
                        if (action != "--background") {
                            Paths.Set("RequestedPage", action == "--updates" ? "3" : "0");
                            using (var show = EventWaitHandle.OpenExisting(prefix + "Show")) show.Set();
                        }
                        return 0;
                    }
                    var security = new EventWaitHandleSecurity();
                    security.AddAccessRule(new EventWaitHandleAccessRule(WindowsIdentity.GetCurrent().User, EventWaitHandleRights.FullControl, AccessControlType.Allow));
                    using (var show = new EventWaitHandle(false, EventResetMode.AutoReset, prefix + "Show", out created, security))
                    using (var quit = new EventWaitHandle(false, EventResetMode.AutoReset, prefix + "Quit", out created, security)) {
                        app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
                        app.DispatcherUnhandledException += (s,e) => { MessageBox.Show("操作未完成：" + e.Exception.Message, "Rime Q", MessageBoxButton.OK, MessageBoxImage.Warning); e.Handled = true; };
                        var updates = new Updates(); var model = new ModelManager();
                        settings = new SettingsWindow(updates, model);
                        settings.Window.Closing += (s,e) => { if (!exiting) { e.Cancel = true; settings.Window.Hide(); } };
                        var tray = new Forms.NotifyIcon { Text = "Rime Q", Icon = System.Drawing.Icon.ExtractAssociatedIcon(Path.Combine(Paths.App, "RimeQ.exe")), Visible = true };
                        var menu = new Forms.ContextMenuStrip();
                        menu.Items.Add("设置", null, (s,e) => Show(0));
                        menu.Items.Add("个人数据文件夹", null, (s,e) => Paths.Open(Paths.Root));
                        menu.Items.Add("使用说明", null, (s,e) => Paths.Open(Path.Combine(Paths.App, "help", "index.html")));
                        menu.Items.Add("检查更新", null, (s,e) => Show(3));
                        menu.Items.Add("卸载 Rime Q", null, (s,e) => { try { Uninstall(); } catch (Exception error) { MessageBox.Show(error.Message, "Rime Q"); } });
                        tray.ContextMenuStrip = menu; tray.DoubleClick += (s,e) => Show(0);
                        updates.Changed += () => { tray.Text = updates.Result.State == "available" ? "Rime Q · 有新版本" : "Rime Q"; };
                        Paths.Start("RimeQ.Broker.exe", "--serve");
                        var launchTime = DateTime.UtcNow;
                        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
                        timer.Tick += async (s,e) => {
                            if (quit.WaitOne(0)) { exiting = true; tray.Dispose(); timer.Stop(); app.Shutdown(); return; }
                            if (show.WaitOne(0)) Show(Paths.Get("RequestedPage") == "3" ? 3 : 0);
                            if (DateTime.UtcNow - launchTime >= TimeSpan.FromSeconds(30)) {
                                try { await updates.Check(false); } catch (System.IO.IOException) { } catch (UnauthorizedAccessException) { }
                            }
                            if (model.Valid && !File.Exists(Paths.Model) && !model.Busy) await model.Restore();
                            model.RefreshEngineStatus();
                        };
                        timer.Start();
                        app.Startup += async (s,e) => { await model.Restore(); };
                        if (action != "--background") Show(action == "--updates" ? 3 : 0);
                        app.Run(); tray.Dispose(); mutex.ReleaseMutex();
                    }
                }
                return 0;
            } catch (Exception error) {
                MessageBox.Show("Rime Q 未能完成操作：" + error.Message, "Rime Q", MessageBoxButton.OK, MessageBoxImage.Warning); return 1;
            }
        }
        static void Show(int page) { settings.ShowPage(page); settings.Window.Show(); settings.Window.WindowState = WindowState.Normal; settings.Window.Activate(); }
    }
}
