using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Runtime.InteropServices;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace RimeQ {
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    internal class ShellLink { }

    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellLinkW {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int count, IntPtr data, uint flags);
        void GetIDList(out IntPtr idList);
        void SetIDList(IntPtr idList);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder description, int count);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string description);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder directory, int count);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string directory);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder arguments, int count);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string arguments);
        void GetHotkey(out ushort hotkey);
        void SetHotkey(ushort hotkey);
        void GetShowCmd(out int showCommand);
        void SetShowCmd(int showCommand);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder iconPath, int count, out int iconIndex);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string iconPath, int iconIndex);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string relativePath, uint reserved);
        void Resolve(IntPtr window, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
    }

    internal static class Setup {
        static readonly string Root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "RimeQ");
        static readonly string Self = Assembly.GetExecutingAssembly().Location;
        static readonly string RegistryPath = @"Software\RimeQ";
        static readonly string UninstallPath = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\RimeQ";
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool IsWow64Process2(IntPtr process, out ushort processMachine, out ushort nativeMachine);
        static void CheckSystem() {
            ushort process, native;
            if (!Environment.Is64BitOperatingSystem || !IsWow64Process2(Process.GetCurrentProcess().Handle, out process, out native) || native != 0x8664)
                throw new IOException("此安装包适用于 Windows x64。当前未提供 ARM64 原生输入服务。");
        }
        static Version Current { get { return Assembly.GetExecutingAssembly().GetName().Version; } }
        static RegistryKey Machine { get { return RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64); } }
        static string Installed() {
            using (var machine = Machine) using (var key = machine.OpenSubKey(RegistryPath)) {
                var path = key == null ? null : key.GetValue("ActiveDirectory") as string;
                if (path == null) return null;
                SafePath(path);
                var broker = Path.Combine(path, "RimeQ.Broker.exe");
                if (!File.Exists(broker) || FileVersionInfo.GetVersionInfo(broker).ProductName != "Rime Q") throw new IOException("已装应用校验失败，请先检查 Rime Q 安装目录。");
                return path;
            }
        }
        internal static void SafePath(string path) {
            string full = Path.GetFullPath(path), root = Path.GetFullPath(Root).TrimEnd(Path.DirectorySeparatorChar);
            if (!full.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) && !string.Equals(full, root, StringComparison.OrdinalIgnoreCase))
                throw new IOException("安装路径不属于 Rime Q。");
            var directory = new DirectoryInfo(full);
            while (directory != null && directory.FullName.Length >= root.Length) {
                if (directory.Exists && (directory.Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("安装目录不能是链接或重解析点。");
                directory = directory.Parent;
            }
        }
        static Version InstalledVersion(string directory) {
            var info = FileVersionInfo.GetVersionInfo(Path.Combine(directory, "RimeQ.Broker.exe"));
            return new Version(info.FileMajorPart, info.FileMinorPart, info.FileBuildPart, info.FilePrivatePart);
        }
        internal static void RequireUpgrade(Version installed, Version incoming) {
            if (installed > incoming) throw new IOException("已安装的版本或构建更新，不能使用旧安装包覆盖。");
        }
        static string Quote(string text) { return "\"" + text.Replace("\"", "") + "\""; }
        static Process StartPrivate(string file, string arguments, bool diagnostics = false) {
            var info = new ProcessStartInfo(file, arguments) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Path.GetDirectoryName(file),
                RedirectStandardOutput = diagnostics, RedirectStandardError = diagnostics };
            var variables = new Dictionary<string, string>();
            foreach (var key in new[] { "APPDATA", "LOCALAPPDATA", "SystemRoot", "TEMP", "TMP", "USERPROFILE", "WINDIR" }) {
                var value = Environment.GetEnvironmentVariable(key); if (value != null) variables[key] = value;
            }
            info.EnvironmentVariables.Clear(); foreach (var entry in variables) info.EnvironmentVariables[entry.Key] = entry.Value;
            return Process.Start(info);
        }
        static int Run(string file, string arguments, int seconds = 30) {
            using (var process = StartPrivate(file, arguments)) {
                if (!process.WaitForExit(seconds * 1000)) throw new IOException("等待 Rime Q 操作超时。请结束当前输入后重试。");
                return process.ExitCode;
            }
        }
        static void Log(string state) {
            Directory.CreateDirectory(Root);
            File.AppendAllText(Path.Combine(Root, "installation.log"), DateTime.UtcNow.ToString("O") + " build=" + Current + " pid=" + Process.GetCurrentProcess().Id + " state=" + state + "\n");
        }
        static string Regsvr(bool x86) { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), x86 ? "SysWOW64" : "System32", "regsvr32.exe"); }
        static void Register(string directory, bool remove) {
            SafePath(directory);
            foreach (var architecture in new[] { "x64", "x86" }) {
                var file = Path.Combine(directory, architecture, "RimeQ.Tip.dll");
                if (FileVersionInfo.GetVersionInfo(file).ProductName != "Rime Q") throw new IOException("输入服务标识不正确。");
                using (var process = StartPrivate(Regsvr(architecture == "x86"), "/s " + (remove ? "/u " : "") + Quote(file), true)) {
                    var output = process.StandardOutput.ReadToEndAsync(); var errors = process.StandardError.ReadToEndAsync();
                    if (!process.WaitForExit(30000)) throw new IOException("输入服务注册操作超时。");
                    foreach (var line in (output.GetAwaiter().GetResult() + "\n" + errors.GetAwaiter().GetResult()).Split('\n'))
                        if (System.Text.RegularExpressions.Regex.IsMatch(line.Trim(), @"^tsf-[a-z0-9-]+$")) Log(line.Trim());
                    if (process.ExitCode != 0) throw new IOException(remove ? "输入法注销失败，已保留安装文件。" : "输入法注册失败。");
                }
            }
        }
        internal static string EntryPath(string directory, string name) {
            if (string.IsNullOrEmpty(name) || name.IndexOf(':') >= 0 || name.IndexOf('\\') >= 0 || name.StartsWith("/", StringComparison.Ordinal)) throw new IOException("安装包包含无效路径。");
            var full = Path.GetFullPath(Path.Combine(directory, name.Replace('/', Path.DirectorySeparatorChar)));
            if (!full.StartsWith(Path.GetFullPath(directory).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                throw new IOException("安装包路径越界。");
            return full;
        }
        static void Extract(string directory) {
            using (var resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip"))
            using (var archive = new ZipArchive(resource, ZipArchiveMode.Read)) {
                long total = 0; var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (var entry in archive.Entries) {
                    var path = EntryPath(directory, entry.FullName);
                    if (!paths.Add(path) || entry.Length > 256L * 1024 * 1024 || (total += entry.Length) > 1024L * 1024 * 1024) throw new IOException("安装包内容不符合预期。");
                    if (Path.GetExtension(path).Equals(".gram", StringComparison.OrdinalIgnoreCase)) throw new IOException("安装包不应包含可选模型。");
                    Directory.CreateDirectory(Path.GetDirectoryName(path));
                    using (var input = entry.Open()) using (var output = new FileStream(path, FileMode.CreateNew)) input.CopyTo(output);
                }
            }
            var metadata = new JavaScriptSerializer { MaxJsonLength = 16 * 1024 * 1024 }.Deserialize<Dictionary<string, object>>(File.ReadAllText(Path.Combine(directory, "payload.json")));
            var files = (Dictionary<string, object>)metadata["files"];
            foreach (var pair in files) {
                var path = EntryPath(directory, pair.Key);
                using (var file = File.OpenRead(path)) using (var hash = SHA256.Create())
                    if (BitConverter.ToString(hash.ComputeHash(file)).Replace("-", "").ToLowerInvariant() != (string)pair.Value) throw new IOException("安装包文件校验失败。");
            }
            if (Directory.GetFiles(directory, "*", SearchOption.AllDirectories).Length != files.Count + 1) throw new IOException("安装包包含未登记文件。");
            if (InstalledVersion(directory) != Current || !File.Exists(Path.Combine(directory, "licenses", "rime-ice-source.tar.gz"))) throw new IOException("安装包版本或许可资源不完整。");
        }
        static void SaveRegistry(string directory) {
            var version = InstalledVersion(directory);
            using (var machine = Machine) {
                using (var key = machine.CreateSubKey(RegistryPath)) { key.SetValue("ActiveDirectory", directory); key.SetValue("Version", version.ToString()); }
                using (var key = machine.CreateSubKey(UninstallPath)) {
                    key.SetValue("DisplayName", "Rime Q"); key.SetValue("DisplayVersion", version.ToString()); key.SetValue("Publisher", "Rime Q contributors");
                    key.SetValue("DisplayIcon", Path.Combine(directory, "RimeQ.exe")); key.SetValue("InstallLocation", Root);
                    key.SetValue("UninstallString", Quote(Path.Combine(Root, "RimeQ.Setup.exe")) + " --uninstall");
                    key.SetValue("NoModify", 1); key.SetValue("NoRepair", 1); key.SetValue("URLInfoAbout", "https://github.com/asmoyou/rime-Q");
                }
            }
        }
        static void Shortcuts(string directory, bool remove) {
            var folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonPrograms), "Rime Q");
            var shortcut = Path.Combine(folder, "Rime Q 设置.lnk");
            if (remove) { if (File.Exists(shortcut)) File.Delete(shortcut); if (Directory.Exists(folder) && !Directory.EnumerateFileSystemEntries(folder).Any()) Directory.Delete(folder); return; }
            Directory.CreateDirectory(folder);
            CreateSettingsShortcut(shortcut, directory);
        }
        internal static void CreateSettingsShortcut(string shortcut, string directory) {
            var instance = new ShellLink();
            try {
                var link = (IShellLinkW)instance;
                var target = Path.Combine(directory, "RimeQ.exe");
                link.SetPath(target);
                link.SetArguments("--settings");
                link.SetWorkingDirectory(directory);
                link.SetDescription("Rime Q 设置");
                link.SetIconLocation(target, 0);
                ((System.Runtime.InteropServices.ComTypes.IPersistFile)link).Save(shortcut, true);
            } finally { Marshal.FinalReleaseComObject(instance); }
        }
        static IEnumerable<string> VersionDirectories() {
            var versions=Path.Combine(Root,"versions");if(!Directory.Exists(versions))return Enumerable.Empty<string>();
            return Directory.GetDirectories(versions).Where(directory=>{
                try { SafePath(directory);var manifest=Path.Combine(directory,"payload.json");var broker=Path.Combine(directory,"RimeQ.Broker.exe");
                    return File.Exists(manifest)&&File.Exists(broker)&&FileVersionInfo.GetVersionInfo(broker).ProductName=="Rime Q"; }
                catch { return false; }
            }).ToList();
        }
        static void RetireLaunchers(string active) {
            foreach(var directory in VersionDirectories().Where(directory=>!string.Equals(directory,active,StringComparison.OrdinalIgnoreCase))) {
                try {
                    var metadata=new JavaScriptSerializer { MaxJsonLength=16*1024*1024 }.Deserialize<Dictionary<string,object>>(File.ReadAllText(Path.Combine(directory,"payload.json")));
                    var files=(Dictionary<string,object>)metadata["files"];
                    foreach(var name in new[]{"RimeQ.Broker.exe","RimeQ.exe"})if(files.ContainsKey(name)){var file=EntryPath(directory,name);SafePath(file);File.Delete(file);}
                } catch { try { Log("old-launcher-retained"); } catch { } }
            }
        }
        static void Install() {
            SafePath(Root); Directory.CreateDirectory(Root); Log("install-start");
            var old = Installed(); if (old != null) RequireUpgrade(InstalledVersion(old), Current);
            var target = Path.Combine(Root, "versions", Current + "-" + Guid.NewGuid().ToString("N")); SafePath(target);
            bool registered = false; string phase = "payload";
            try {
                Directory.CreateDirectory(target); Extract(target); Log("payload-verified");
                // Recheck immediately before changing registration, after extraction and verification.
                var check = Installed(); if (check != null) RequireUpgrade(InstalledVersion(check), Current);
                phase = "registration"; registered = true; Register(target, false); Log("input-services-registered");
                phase = "uninstaller";
                var setup = Path.Combine(Root, "RimeQ.Setup.exe");
                var temporary = Path.Combine(Root, "RimeQ.Setup.next.exe"); File.Copy(Path.Combine(target, "RimeQ.Uninstall.exe"), temporary, true);
                if (File.Exists(setup)) File.Replace(temporary, setup, null); else File.Move(temporary, setup);
                phase = "registry"; SaveRegistry(target);
                phase = "shortcuts"; Shortcuts(target, false);
                phase = "retirement"; Log("installed-pending-user-activation");RetireLaunchers(target);
                // Loaded DLLs stay in their own old version directories. No overwrite or forced host termination.
                if (old != null && !string.Equals(old, target, StringComparison.OrdinalIgnoreCase)) Log("previous-version-retained-until-uninstall");
            } catch {
                if (registered) { try { Register(target, true); } catch { } }
                if (old != null) { try { Register(old, false); SaveRegistry(old); } catch { Log("rollback-registration-failed"); } }
                Log("install-failed-" + phase); throw;
            }
        }
        internal static void RemoveUserRegistration(RegistryKey user) {
            // EnableLanguageProfile/InstallLayoutOrTip can leave a disabled HKCU
            // profile after Unregister removes the machine registration. Remove
            // only our own CTF identity; personal data and other TIPs are unrelated.
            user.DeleteSubKeyTree(@"Software\Microsoft\CTF\TIP\{C13A9B62-413B-45B8-9EF1-884522319760}", false);
        }
        static void RemoveCurrentUserRegistration() {
            foreach (var view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
                using (var user = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, view)) RemoveUserRegistration(user);
        }
        static void Remove() {
            SafePath(Root); var installed = Installed(); if (installed == null) return; Log("uninstall-start");
            try { Register(installed, true); RemoveCurrentUserRegistration(); Log("user-profile-removed"); }
            catch { try { Register(installed, false); } catch { } throw; }
            Shortcuts(installed, true);
            using (var machine = Machine) { machine.DeleteSubKeyTree(UninstallPath, false); machine.DeleteSubKeyTree(RegistryPath, false); }
            // Only manifest-listed files inside validated Rime Q version directories may be removed.
            var versions = Path.Combine(Root, "versions");
            if (Directory.Exists(versions)) foreach (var directory in Directory.GetDirectories(versions)) {
                SafePath(directory); var manifest = Path.Combine(directory, "payload.json");
                if (!File.Exists(manifest)) continue;
                var metadata = new JavaScriptSerializer { MaxJsonLength = 16 * 1024 * 1024 }.Deserialize<Dictionary<string, object>>(File.ReadAllText(manifest));
                var files = (Dictionary<string, object>)metadata["files"];
                foreach (var name in files.Keys) {
                    var file = EntryPath(directory, name); SafePath(Path.GetDirectoryName(file));
                    try { File.Delete(file); } catch (IOException) { Log("loaded-file-retained"); } catch (UnauthorizedAccessException) { Log("protected-file-retained"); }
                }
                bool retained = Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories).Any(file => !file.Equals(manifest, StringComparison.OrdinalIgnoreCase));
                if (!retained) { File.Delete(manifest); DeleteEmpty(directory); }
            }
            Log("unregistered-personal-data-retained");
        }
        static void DeleteEmpty(string directory) {
            SafePath(directory);
            foreach (var child in Directory.GetDirectories(directory)) DeleteEmpty(child);
            if (!Directory.EnumerateFileSystemEntries(directory).Any()) Directory.Delete(directory);
        }
        static void StopUserService(string installed, bool removing) {
            if (installed == null) return;
            if (Run(Path.Combine(installed, "RimeQ.Control.exe"), "--deactivate") != 0) throw new IOException("未能切换到其他输入法。请先手动切换，再重试。");
            foreach(var directory in VersionDirectories()) {
                int stopped=Run(Path.Combine(directory,"RimeQ.Broker.exe"),"--shutdown",10);
                if(stopped!=0&&stopped!=2)throw new IOException("请先结束正在输入的组合，再重试。");
                Run(Path.Combine(directory,"RimeQ.exe"),"--quit",10);
            }
            if (removing) using (var run = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true))
                if (run != null) run.DeleteValue("RimeQ", false);
        }
        static async Task<bool> StartUserApplication(string directory) {
            using (var engine = StartPrivate(Path.Combine(directory,"RimeQ.Broker.exe"),"--serve")) { }
            using (var settings = StartPrivate(Path.Combine(directory,"RimeQ.exe"),"--background")) { }
            var deadline = Stopwatch.StartNew();
            while (deadline.Elapsed < TimeSpan.FromSeconds(12)) {
                if (await Task.Run(() => Run(Path.Combine(directory,"RimeQ.Broker.exe"),"--ping",4)) == 0) return true;
                await Task.Delay(150);
            }
            return false;
        }
        internal static async Task<int> EnableAfterReady(Func<Task<bool>> start, Func<int> enable) {
            if (!await start()) throw new IOException("新版输入服务未能启动，输入源仍保持停用。请稍后使用同一安装包修复。");
            return await Task.Run(enable);
        }
        [STAThread]
        static int Main(string[] args) {
            if (args.Length == 2 && args[0] == "--verify-payload") {
                try { Extract(Path.GetFullPath(args[1])); return 0; }
                catch (Exception error) {
                    Console.Error.WriteLine("Payload verification failed: " + error.GetType().Name + ": " + error.Message);
                    return 1;
                }
            }
            if (args.Length > 0 && (args[0] == "--install-elevated" || args[0] == "--uninstall-elevated")) {
                try {
                    CheckSystem();
                    if (!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator)) return 5;
                    using (var mutex = new Mutex(false, @"Global\RimeQ.Installation")) {
                        if (!mutex.WaitOne(0)) return 6;
                        try { if (args[0] == "--install-elevated") Install(); else Remove(); } finally { mutex.ReleaseMutex(); }
                    }
                    return 0;
                } catch (Exception error) { try { Log("failed-" + error.GetType().Name); } catch { } if (!args.Contains("--silent")) MessageBox.Show(error.Message, "Rime Q 安装", MessageBoxButton.OK, MessageBoxImage.Error); return 1; }
            }
            var uninstall = (args.Length > 0 && args[0] == "--uninstall") || !Assembly.GetExecutingAssembly().GetManifestResourceNames().Contains("payload.zip");
            var application = new Application();
            var window = new Window { Title = uninstall ? "卸载 Rime Q" : "安装 Rime Q", Width = 580, Height = 600, ResizeMode = ResizeMode.NoResize, WindowStartupLocation = WindowStartupLocation.CenterScreen,
                FontFamily = new FontFamily("Microsoft YaHei UI"), FontSize = 14, Background = new SolidColorBrush(Color.FromRgb(247,248,245)) };
            var panel = new StackPanel { Margin = new Thickness(36,28,36,24) };
            var scroll = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Background = window.Background }; window.Content = scroll;
            panel.Children.Add(new TextBlock { Text = "Q", FontSize = 40, FontWeight = FontWeights.Bold, Foreground = new SolidColorBrush(Color.FromRgb(23,99,77)) });
            var title = new TextBlock { Text = uninstall ? "卸载 Rime Q" : "安装 Rime Q " + Current.ToString(3), FontSize = 26, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0,14,0,18) }; panel.Children.Add(title);
            var description = new TextBlock { Text = uninstall ? "移除 Rime Q 输入服务及程序文件。个人词库、学习记录、设置和已下载模型均会保留。" :
                "引擎和基础词库已包含在安装包中，无需安装其他输入法。\n\nWindows 管理员认证用于写入 Rime Q 程序目录和注册输入服务；取消认证不会完成安装。", TextWrapping = TextWrapping.Wrap, LineHeight = 24, Foreground = Brushes.DarkSlateGray }; panel.Children.Add(description);
            var status = new TextBlock { Margin = new Thickness(0,18,0,18), TextWrapping = TextWrapping.Wrap, LineHeight = 22 }; panel.Children.Add(status);
            string installed = null;
            var primary = new Button { Content = uninstall ? "确认卸载" : "安装", Padding = new Thickness(24,10,24,10), HorizontalAlignment = HorizontalAlignment.Left, IsDefault = !uninstall };
            try {
                CheckSystem();
                installed = Installed();
                if (!uninstall && installed != null) {
                    RequireUpgrade(InstalledVersion(installed), Current);
                    primary.Content = InstalledVersion(installed) == Current ? "修复安装" : "升级";
                    status.Text = "已安装 " + InstalledVersion(installed) + "。此次操作保留个人数据。";
                } else status.Text = uninstall ? "请先结束当前输入，程序会切换到其他输入法。" : "安装后从 Windows 输入法列表选择 Rime Q。";
            } catch (Exception error) { status.Text = error.Message; primary.IsEnabled = false; }
            var buttons = new WrapPanel(); buttons.Children.Add(primary);
            var close = new Button { Content = "取消", Padding = new Thickness(20,10,20,10), Margin = new Thickness(12,0,0,0), IsCancel = true, IsDefault = uninstall }; close.Click += (s,e) => window.Close(); buttons.Children.Add(close); panel.Children.Add(buttons);
            bool busy = false; window.Closing += (s,e) => { if (busy) e.Cancel = true; };
            primary.Click += async (s,e) => {
                if (uninstall && MessageBox.Show(window, "确认卸载 Rime Q？个人词库、学习记录、设置和模型会保留。", "卸载 Rime Q", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) != MessageBoxResult.Yes) return;
                busy = true; primary.IsEnabled = close.IsEnabled = false; status.Text = "正在准备，请稍候…";
                try {
                    await Task.Run(() => StopUserService(installed, uninstall));
                    var info = new ProcessStartInfo(Self, uninstall ? "--uninstall-elevated" : "--install-elevated") { UseShellExecute = true, Verb = "runas" };
                    int result = await Task.Run(() => { using (var process = Process.Start(info)) { process.WaitForExit(); return process.ExitCode; } });
                    if (result != 0) throw new IOException("操作未完成（" + result + "）。程序文件及安装日志位于 Rime Q 安装目录。");
                    if (!uninstall) {
                        var current = Installed();
                        // This process is the original unelevated installer, so startup belongs to the actual desktop user.
                        // Start the new broker before enabling the profile. A host that still has an older
                        // versioned TIP loaded must never win the shared engine lock during this gap.
                        int enabled = await EnableAfterReady(() => StartUserApplication(current), () => Run(Path.Combine(current, "RimeQ.Control.exe"), "--enable"));
                        status.Text = enabled != 0 ? "程序已安装，输入源尚待启用。请在 Windows 语言设置中添加 Rime Q。" : "安装完成。可从 Windows 输入法列表选择 Rime Q。";
                    } else {
                        // UAC can run under a different administrator account. The
                        // original unelevated GUI must also clean its own user profile.
                        RemoveCurrentUserRegistration();
                        status.Text = "Rime Q 已停用并卸载。个人数据保留；宿主仍加载的旧文件会保留至关闭对应应用后清理。";
                    }
                    primary.Visibility = Visibility.Collapsed; close.Content = "完成";
                } catch (Exception error) {
                    status.Text = error is System.ComponentModel.Win32Exception ? "已取消管理员认证，操作未完成。" : error.Message;
                    if (installed != null) { try { await StartUserApplication(installed); Run(Path.Combine(installed, "RimeQ.Control.exe"), "--enable"); } catch { } }
                } finally { busy = false; primary.IsEnabled = close.IsEnabled = true; }
            };
            if (args.Length == 2 && args[0] == "--render") {
                scroll.Measure(new Size(580,560)); scroll.Arrange(new Rect(0,0,580,560)); scroll.UpdateLayout();
                var bitmap = new RenderTargetBitmap(580,560,96,96,PixelFormats.Pbgra32); bitmap.Render(scroll);
                var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
                using (var file = File.Create(Path.GetFullPath(args[1]))) encoder.Save(file); return 0;
            }
            application.Run(window); return 0;
        }
    }
}
