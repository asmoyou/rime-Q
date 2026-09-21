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
using System.Windows.Automation;
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

    internal sealed class InstallerView {
        internal readonly Window Window;
        internal readonly Button Primary, Close;
        internal readonly TextBlock Title, Subtitle, StatusTitle, Status;
        internal readonly ProgressBar Progress;
        internal bool SameVersion { get; private set; }
        readonly Border statusPanel;
        readonly TextBlock[] stepLabels = new TextBlock[3], stepNumbers = new TextBlock[3];
        readonly bool uninstall;

        static TextBlock Text(string value, double size = 13, bool secondary = false) {
            var text = new TextBlock { Text=value, FontSize=size, TextWrapping=TextWrapping.Wrap };
            text.SetResourceReference(TextBlock.ForegroundProperty, secondary ? "SecondaryColor" : "TextColor");
            return text;
        }
        static Border Rule() { var line=new Border {Height=1,Margin=new Thickness(0,13,0,13)};line.SetResourceReference(Border.BackgroundProperty,"BorderColor");return line; }
        static FrameworkElement Info(string glyph,string title,string detail) {
            var row=new Grid();row.ColumnDefinitions.Add(new ColumnDefinition {Width=new GridLength(28)});row.ColumnDefinitions.Add(new ColumnDefinition());
            var icon=Text(glyph,15);icon.FontFamily=new FontFamily("Segoe MDL2 Assets");icon.VerticalAlignment=VerticalAlignment.Top;icon.Margin=new Thickness(0,1,0,0);icon.SetResourceReference(TextBlock.ForegroundProperty,"Accent");
            var labels=new StackPanel();var heading=Text(title,13);heading.FontWeight=FontWeights.SemiBold;var body=Text(detail,12,true);body.Margin=new Thickness(0,4,0,0);body.LineHeight=19;labels.Children.Add(heading);labels.Children.Add(body);
            Grid.SetColumn(labels,1);row.Children.Add(icon);row.Children.Add(labels);return row;
        }
        void Step(StackPanel list,int index,string title) {
            var row=new Grid {Margin=new Thickness(0,0,0,18)};row.ColumnDefinitions.Add(new ColumnDefinition {Width=new GridLength(30)});row.ColumnDefinitions.Add(new ColumnDefinition());
            var circle=new Border {Width=22,Height=22,CornerRadius=new CornerRadius(11),BorderThickness=new Thickness(1),VerticalAlignment=VerticalAlignment.Center};circle.SetResourceReference(Border.BorderBrushProperty,"BorderColor");
            var number=Text((index+1).ToString(CultureInfo.InvariantCulture),11,true);number.HorizontalAlignment=HorizontalAlignment.Center;number.VerticalAlignment=VerticalAlignment.Center;circle.Child=number;stepNumbers[index]=number;
            var label=Text(title,12,true);label.VerticalAlignment=VerticalAlignment.Center;Grid.SetColumn(label,1);stepLabels[index]=label;row.Children.Add(circle);row.Children.Add(label);list.Children.Add(row);
        }
        internal InstallerView(bool uninstall, Version version) {
            this.uninstall=uninstall;
            Window=new Window {Title=uninstall?"卸载 Rime Q":"安装 Rime Q",Width=720,Height=560,ResizeMode=ResizeMode.NoResize,WindowStartupLocation=WindowStartupLocation.CenterScreen,FontFamily=new FontFamily("Segoe UI, Microsoft YaHei UI"),FontSize=13,UseLayoutRounding=true,SnapsToDevicePixels=true};
            var root=new Grid();root.SetResourceReference(Grid.BackgroundProperty,"WindowBackground");root.ColumnDefinitions.Add(new ColumnDefinition {Width=new GridLength(184)});root.ColumnDefinitions.Add(new ColumnDefinition());Window.Content=root;
            var sidebar=new Border {Padding=new Thickness(24,30,20,22),BorderThickness=new Thickness(0,0,1,0)};sidebar.SetResourceReference(Border.BackgroundProperty,"SidebarBackground");sidebar.SetResourceReference(Border.BorderBrushProperty,"BorderColor");root.Children.Add(sidebar);
            var side=new DockPanel();sidebar.Child=side;
            var versionLabel=Text("版本 "+version.ToString(3)+"  ·  构建 "+version.Revision,11,true);versionLabel.VerticalAlignment=VerticalAlignment.Bottom;DockPanel.SetDock(versionLabel,Dock.Bottom);side.Children.Add(versionLabel);
            var sideContent=new StackPanel();side.Children.Add(sideContent);
            var brand=new StackPanel {Orientation=Orientation.Horizontal,Margin=new Thickness(0,0,0,38)};
            try {
                using(var icon=System.Drawing.Icon.ExtractAssociatedIcon(Assembly.GetExecutingAssembly().Location)) {
                    var source=System.Windows.Interop.Imaging.CreateBitmapSourceFromHIcon(icon.Handle,Int32Rect.Empty,BitmapSizeOptions.FromWidthAndHeight(42,42));source.Freeze();brand.Children.Add(new Image {Source=source,Width=42,Height=42,Margin=new Thickness(0,0,11,0)});
                }
            } catch { var mark=Text("Q",30);mark.FontWeight=FontWeights.Bold;mark.SetResourceReference(TextBlock.ForegroundProperty,"Accent");mark.Margin=new Thickness(0,0,11,0);brand.Children.Add(mark); }
            var names=new StackPanel {VerticalAlignment=VerticalAlignment.Center};var product=Text("Rime Q",18);product.FontWeight=FontWeights.SemiBold;names.Children.Add(product);names.Children.Add(Text(uninstall?"卸载程序":"安装程序",11,true));brand.Children.Add(names);sideContent.Children.Add(brand);
            var steps=new StackPanel();Step(steps,0,"准备");Step(steps,1,uninstall?"移除":"安装");Step(steps,2,"完成");sideContent.Children.Add(steps);

            var main=new Grid {Margin=new Thickness(34,28,34,26)};main.RowDefinitions.Add(new RowDefinition {Height=GridLength.Auto});main.RowDefinitions.Add(new RowDefinition {Height=GridLength.Auto});main.RowDefinitions.Add(new RowDefinition {Height=GridLength.Auto});main.RowDefinitions.Add(new RowDefinition());main.RowDefinitions.Add(new RowDefinition {Height=GridLength.Auto});Grid.SetColumn(main,1);root.Children.Add(main);
            var heading=new StackPanel {Margin=new Thickness(0,0,0,20)};Title=Text("",27);Title.FontWeight=FontWeights.SemiBold;Title.TextWrapping=TextWrapping.NoWrap;Subtitle=Text("",13,true);Subtitle.Margin=new Thickness(0,7,0,0);Subtitle.LineHeight=20;heading.Children.Add(Title);heading.Children.Add(Subtitle);main.Children.Add(heading);
            var details=new Border {CornerRadius=new CornerRadius(6),BorderThickness=new Thickness(1),Padding=new Thickness(18,16,18,16),Margin=new Thickness(0,0,0,16)};details.SetResourceReference(Border.BackgroundProperty,"CardBackground");details.SetResourceReference(Border.BorderBrushProperty,"BorderColor");Grid.SetRow(details,1);main.Children.Add(details);
            var information=new StackPanel();
            if(uninstall) {
                information.Children.Add(Info("\uE74D","移除程序和输入服务","卸载 Rime Q 应用文件并取消输入法注册。"));information.Children.Add(Rule());
                information.Children.Add(Info("\uE73E","保留个人数据","个人词库、学习记录、设置和已下载模型不会删除。"));
            } else {
                information.Children.Add(Info("\uE896","完整离线组件","输入引擎和基础词库随包安装，无需另装其他输入法。"));information.Children.Add(Rule());
                information.Children.Add(Info("\uE73E","升级保留个人数据","个人词库、学习记录、设置和已下载模型保持不变。"));information.Children.Add(Rule());
                information.Children.Add(Info("\uE72E","明确的管理员认证","仅在写入 Rime Q 程序目录和注册输入服务时请求。"));
            }
            details.Child=information;
            statusPanel=new Border {CornerRadius=new CornerRadius(6),Padding=new Thickness(16,13,16,13),Margin=new Thickness(0,0,0,16)};statusPanel.SetResourceReference(Border.BackgroundProperty,"StatusBackground");Grid.SetRow(statusPanel,2);main.Children.Add(statusPanel);
            var statusStack=new StackPanel();StatusTitle=Text("",13);StatusTitle.FontWeight=FontWeights.SemiBold;Status=Text("",12,true);Status.Margin=new Thickness(0,4,0,0);Status.LineHeight=19;Progress=new ProgressBar {Height=4,Margin=new Thickness(0,12,0,0),IsIndeterminate=true,Visibility=Visibility.Collapsed};AutomationProperties.SetName(Progress,uninstall?"卸载进度":"安装进度");statusStack.Children.Add(StatusTitle);statusStack.Children.Add(Status);statusStack.Children.Add(Progress);statusPanel.Child=statusStack;
            var buttons=new StackPanel {Orientation=Orientation.Horizontal,HorizontalAlignment=HorizontalAlignment.Right};Primary=new Button {Padding=new Thickness(22,9,22,9),MinWidth=96,IsDefault=!uninstall};Primary.SetResourceReference(Button.BackgroundProperty,"Accent");Primary.Foreground=Brushes.White;Primary.BorderThickness=new Thickness(0);AutomationProperties.SetName(Primary,uninstall?"确认卸载":"开始安装");
            Close=new Button {Content="取消",Padding=new Thickness(20,9,20,9),Margin=new Thickness(10,0,0,0),MinWidth=82,IsCancel=true,IsDefault=uninstall};Close.SetResourceReference(Button.BackgroundProperty,"ControlBackground");Close.SetResourceReference(Button.ForegroundProperty,"TextColor");Close.SetResourceReference(Button.BorderBrushProperty,"BorderColor");buttons.Children.Add(Primary);buttons.Children.Add(Close);Grid.SetRow(buttons,4);main.Children.Add(buttons);
            Close.Click+=(s,e)=>Window.Close();Apply(SystemDark());SetStep(0);
        }
        internal static bool SystemDark() { using(var key=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))return key!=null&&Convert.ToInt32(key.GetValue("AppsUseLightTheme",1))==0; }
        internal void Apply(bool dark) {
            var names=new[]{"WindowBackground","CardBackground","SidebarBackground","BorderColor","TextColor","SecondaryColor","Accent","ControlBackground","StatusBackground","PrimaryTextColor"};
            var light=new[]{"#F6F7F9","#FFFFFF","#ECEFF3","#DDE1E7","#202124","#6F737A","#0078D4","#FFFFFF","#EAF3FB","#FFFFFF"};
            var night=new[]{"#202226","#2A2D32","#27292E","#3C3F46","#F2F2F7","#A5A8B0","#4B9BFF","#34373E","#28394A","#FFFFFF"};
            for(int i=0;i<names.Length;i++)Window.Resources[names[i]]=new SolidColorBrush((Color)ColorConverter.ConvertFromString((dark?night:light)[i]));
            if(SystemParameters.HighContrast){Window.Resources["WindowBackground"]=Window.Resources["CardBackground"]=Window.Resources["ControlBackground"]=SystemColors.WindowBrush;Window.Resources["TextColor"]=Window.Resources["SecondaryColor"]=SystemColors.WindowTextBrush;Window.Resources["SidebarBackground"]=Window.Resources["StatusBackground"]=SystemColors.ControlBrush;Window.Resources["BorderColor"]=SystemColors.WindowTextBrush;Window.Resources["Accent"]=SystemColors.HighlightBrush;Window.Resources["PrimaryTextColor"]=SystemColors.HighlightTextBrush;}
            Primary.SetResourceReference(Button.ForegroundProperty,"PrimaryTextColor");
            Window.SetResourceReference(Window.BackgroundProperty,"WindowBackground");Window.SetResourceReference(Window.ForegroundProperty,"TextColor");
        }
        internal void Configure(Version current,Version installed) {
            SameVersion=!uninstall&&installed!=null&&installed==current;
            if(uninstall){Title.Text="卸载 Rime Q";Subtitle.Text="移除程序和输入服务，同时保留你的个人数据。";Primary.Content="确认卸载";AutomationProperties.SetName(Primary,"确认卸载 Rime Q");StatusTitle.Text="卸载前";Status.Text="请先结束当前输入。卸载时会安全切换到其他输入法。";return;}
            if(installed==null){Title.Text="安装 Rime Q "+current.ToString(3);Subtitle.Text="简洁、流畅、离线的中文输入法。";Primary.Content="安装";AutomationProperties.SetName(Primary,"安装 Rime Q");StatusTitle.Text="准备安装";Status.Text="安装完成后，可从 Windows 输入法列表选择 Rime Q。";return;}
            if(SameVersion){Title.Text="已安装当前版本";Subtitle.Text="Rime Q "+current+" 已在此电脑上。";Primary.Visibility=Visibility.Collapsed;Close.Content="关闭";StatusTitle.Text="无需重复安装";Status.Text="此安装包与已安装版本完全一致。个人数据和当前输入服务没有变化。";return;}
            Title.Text="升级 Rime Q";Subtitle.Text=installed+"  →  "+current;Primary.Content="升级";AutomationProperties.SetName(Primary,"升级 Rime Q");StatusTitle.Text="准备升级";Status.Text="升级会替换程序组件，个人词库、学习记录、设置和模型全部保留。";
        }
        internal void Begin(string action) {SetStep(1);Title.Text="正在"+action+" Rime Q";Subtitle.Text="请保持此窗口打开。";StatusTitle.Text="正在准备";Status.Text="等待管理员认证，然后校验并写入 Rime Q 组件。";Progress.Visibility=Visibility.Visible;Primary.IsEnabled=Close.IsEnabled=false;}
        internal void Complete(string message) {SetStep(2);Title.Text=uninstall?"卸载完成":"安装完成";Subtitle.Text=uninstall?"Rime Q 程序和输入服务已移除。":"Rime Q 已准备好，可从输入法列表选择使用。";StatusTitle.Text=uninstall?"个人数据已保留":"输入服务已启用";Status.Text=message;Progress.Visibility=Visibility.Collapsed;Primary.Visibility=Visibility.Collapsed;Close.Content="完成";Close.IsEnabled=true;}
        internal void Fail(string message) {SetStep(1);Title.Text=uninstall?"卸载未完成":"安装未完成";Subtitle.Text="请查看下方原因后重试。";StatusTitle.Text="操作未完成";Status.Text=message;Progress.Visibility=Visibility.Collapsed;Primary.IsEnabled=Close.IsEnabled=true;}
        internal void SetStep(int active) {
            for(int i=0;i<stepLabels.Length;i++){bool current=i==active,done=i<active;stepLabels[i].FontWeight=current?FontWeights.SemiBold:FontWeights.Normal;stepLabels[i].SetResourceReference(TextBlock.ForegroundProperty,current||done?"TextColor":"SecondaryColor");stepNumbers[i].Text=done?"\uE73E":(i+1).ToString(CultureInfo.InvariantCulture);stepNumbers[i].FontFamily=done?new FontFamily("Segoe MDL2 Assets"):Window.FontFamily;stepNumbers[i].SetResourceReference(TextBlock.ForegroundProperty,current||done?"Accent":"SecondaryColor");}
        }
        internal void ValidateLayout() {
            var root=(FrameworkElement)Window.Content;root.Measure(new Size(Window.Width,Window.Height));root.Arrange(new Rect(0,0,Window.Width,Window.Height));root.UpdateLayout();
            if(Title.ActualWidth<=0||Status.ActualHeight<=0||Close.ActualWidth<80||statusPanel.ActualWidth<300)throw new IOException("安装器布局校验失败。");
        }
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
            if(args.Length>0&&args[0]=="--render")AppDomain.CurrentDomain.UnhandledException+=(sender,eventArgs)=>{
                var error=eventArgs.ExceptionObject as Exception;if(error!=null)Console.Error.WriteLine(error.GetType().FullName+": "+error.Message+"\n"+error.StackTrace);
            };
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
            var renderMode=args.Length>=2&&args[0]=="--render"?(args.Length>=3?args[2]:"install-light"):null;
            var uninstall = renderMode!=null?renderMode.StartsWith("uninstall",StringComparison.OrdinalIgnoreCase):(args.Length > 0 && args[0] == "--uninstall") || !Assembly.GetExecutingAssembly().GetManifestResourceNames().Contains("payload.zip");
            var application = new Application();
            var view=new InstallerView(uninstall,Current);var window=view.Window;
            bool installerClosed=false;
            UserPreferenceChangedEventHandler appearanceChanged=(sender,eventArgs)=>{
                if(window.Dispatcher.HasShutdownStarted)return;
                window.Dispatcher.BeginInvoke(new Action(()=>{if(!installerClosed)view.Apply(InstallerView.SystemDark());}));
            };
            SystemEvents.UserPreferenceChanged+=appearanceChanged;
            window.Closed+=(sender,eventArgs)=>{installerClosed=true;SystemEvents.UserPreferenceChanged-=appearanceChanged;};
            string installed = null;
            try {
                CheckSystem();
                if(renderMode==null)installed=Installed();
                var installedVersion=installed==null?null:InstalledVersion(installed);
                if(renderMode!=null&&renderMode.StartsWith("upgrade",StringComparison.OrdinalIgnoreCase))installedVersion=new Version(Current.Major,Current.Minor,Math.Max(0,Current.Build-1),Math.Max(0,Current.Revision-1));
                else if(renderMode!=null&&renderMode.StartsWith("current",StringComparison.OrdinalIgnoreCase))installedVersion=Current;
                view.Configure(Current,installedVersion);
            } catch (Exception error) { view.Fail(error.Message); view.Primary.IsEnabled = false; }
            if(renderMode!=null&&renderMode.StartsWith("complete",StringComparison.OrdinalIgnoreCase))view.Complete("安装完成。个人数据已保留。");
            if(renderMode!=null&&renderMode.StartsWith("error",StringComparison.OrdinalIgnoreCase))view.Fail("管理员认证已取消，尚未更改此电脑上的 Rime Q。");
            if(renderMode!=null)view.Apply(renderMode.EndsWith("dark",StringComparison.OrdinalIgnoreCase));
            bool busy = false; window.Closing += (s,e) => { if (busy) e.Cancel = true; };
            view.Primary.Click += async (s,e) => {
                if (uninstall && MessageBox.Show(window, "确认卸载 Rime Q？个人词库、学习记录、设置和模型会保留。", "卸载 Rime Q", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) != MessageBoxResult.Yes) return;
                busy = true;view.Begin(uninstall?"卸载":"安装");
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
                        view.Complete(enabled != 0 ? "程序已安装，输入源尚待启用。请在 Windows 语言设置中添加 Rime Q。" : "输入引擎和基础词库已就绪，个人数据已保留。");
                    } else {
                        // UAC can run under a different administrator account. The
                        // original unelevated GUI must also clean its own user profile.
                        RemoveCurrentUserRegistration();
                        view.Complete("个人数据已保留；宿主仍加载的旧文件会在关闭对应应用后清理。");
                    }
                } catch (Exception error) {
                    view.Fail(error is System.ComponentModel.Win32Exception ? "已取消管理员认证，操作未完成。" : error.Message);
                    if (installed != null) { try { await StartUserApplication(installed); Run(Path.Combine(installed, "RimeQ.Control.exe"), "--enable"); } catch { } }
                } finally { busy = false; }
            };
            if (renderMode != null) {
                view.ValidateLayout();var root=(FrameworkElement)window.Content;
                var bitmap = new RenderTargetBitmap((int)window.Width,(int)window.Height,96,96,PixelFormats.Pbgra32); bitmap.Render(root);
                var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
                using (var file = File.Create(Path.GetFullPath(args[1]))) encoder.Save(file); return 0;
            }
            application.Run(window); return 0;
        }
    }
}
