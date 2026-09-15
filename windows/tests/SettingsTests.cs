using System;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Controls;
using System.Windows.Automation;
using System.Windows.Threading;
using System.Windows.Interop;
using System.Collections.Generic;
using System.Diagnostics;

namespace RimeQ {
    internal static class SettingsTests {
        static IEnumerable<T> Descendants<T>(DependencyObject node) where T : DependencyObject {
            if(node is T match) yield return match;
            for(int i=0;i<VisualTreeHelper.GetChildrenCount(node);++i) foreach(var child in Descendants<T>(VisualTreeHelper.GetChild(node,i))) yield return child;
        }
        static void Pump(int milliseconds) {
            var frame = new DispatcherFrame(); var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(milliseconds) };
            timer.Tick += (s,e) => { timer.Stop(); frame.Continue = false; }; timer.Start(); Dispatcher.PushFrame(frame);
        }
        static void Require(bool ok, string message) { if (!ok) throw new Exception(message); }
        static Rect Bounds(FrameworkElement element,FrameworkElement ancestor) {
            return element.TransformToAncestor(ancestor).TransformBounds(new Rect(element.RenderSize));
        }
        static void Reject(Action action) { bool rejected = false; try { action(); } catch { rejected = true; } Require(rejected, "Expected rejection"); }
        static async Task RejectAsync(Func<Task> action) { bool rejected = false; try { await action(); } catch { rejected = true; } Require(rejected, "Expected async rejection"); }
        static bool CanRender() {
            var drawing=new DrawingVisual();using(var context=drawing.RenderOpen())context.DrawRectangle(Brushes.Red,null,new Rect(0,0,20,20));
            var bitmap=new RenderTargetBitmap(20,20,96,96,PixelFormats.Pbgra32);bitmap.Render(drawing);var pixel=new byte[4];bitmap.CopyPixels(new Int32Rect(0,0,1,1),pixel,4,0);return pixel[3]!=0;
        }
        static bool HasVisiblePixel(RenderTargetBitmap bitmap,int width,int height) {
            var pixels=new byte[width*height*4];bitmap.CopyPixels(pixels,width*4,0);
            for(int i=3;i<pixels.Length;i+=4)if(pixels[i]!=0)return true;
            return false;
        }
        static void DictionarySmoke(string app,string user,string code,string expected,bool present) {
            var arguments="--dictionary-smoke \""+app+"\" \""+user+"\" "+code+" \""+expected+"\" "+(present?"present":"absent");
            var info=new ProcessStartInfo(Path.Combine(app,"RimeQ.Broker.exe"),arguments) { UseShellExecute=false,CreateNoWindow=true,WorkingDirectory=app };
            var values=new Dictionary<string,string>();foreach(var key in new[]{"APPDATA","LOCALAPPDATA","SystemRoot","TEMP","TMP","USERPROFILE","WINDIR"}){var value=Environment.GetEnvironmentVariable(key);if(value!=null)values[key]=value;}
            info.EnvironmentVariables.Clear();foreach(var pair in values)info.EnvironmentVariables[pair.Key]=pair.Value;
            using(var process=Process.Start(info)){Require(process.WaitForExit(30000)&&process.ExitCode==0,"Managed dictionary engine smoke");}
        }
        static string Release(string version = "v0.4.1") { return "{\"tag_name\":\"" + version + "\",\"draft\":false,\"prerelease\":false,\"assets\":[{\"name\":\"RimeQ-0.4.1-windows-x64.exe\"}]}"; }
        sealed class Handler : HttpMessageHandler {
            internal int Requests;
            internal TaskCompletionSource<HttpResponseMessage> Response = new TaskCompletionSource<HttpResponseMessage>();
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage message, CancellationToken token) {
                ++Requests; Require(message.Method == HttpMethod.Get && message.Content == null && message.RequestUri.Query == "", "Request contains unexpected data");
                Require(message.RequestUri.AbsoluteUri == "https://api.github.com/repos/asmoyou/rime-Q/releases/latest", "Unexpected endpoint");
                return Response.Task;
            }
        }
        static async Task Verify() {
            Require(Updates.Parse(HttpStatusCode.OK, Release(), "0.4.0").State == "available", "New release");
            Require(Updates.Parse(HttpStatusCode.OK, Release("v0.4.0"), "0.4.0").State == "current", "Same release");
            Require(Updates.Parse(HttpStatusCode.OK, Release("v0.3.9"), "0.4.0").State == "current", "Older release");
            Require(Updates.Parse(HttpStatusCode.OK, Release("v0.10.0"), "0.9.0").State == "available", "Numeric version ordering");
            Require(Updates.Parse(HttpStatusCode.NotFound, "", "0.4.0").State == "unpublished", "No releases");
            foreach (var status in new[] { 403, 429, 500, 503 }) Require(Updates.Parse((HttpStatusCode)status, "", "0.4.0").State == "failed", "HTTP failures");
            Require(Updates.Parse(HttpStatusCode.OK, Release().Replace("\"prerelease\":false", "\"prerelease\":true"), "0.4.0").State == "unpublished", "Prerelease");
            Reject(() => Updates.Parse(HttpStatusCode.OK, "{}", "0.4.0"));
            var now = DateTime.UtcNow;
            Require(!Updates.Due(now, now.AddHours(-23.99).ToString("O"), true), "Daily boundary");
            Require(Updates.Due(now, now.AddHours(-24).ToString("O"), true), "24 hour boundary");
            Require(!Updates.Due(now, "", false), "Disabled updates");
            Require(Updates.Due(now, now.AddHours(1).ToString("O"), true), "Clock rollback");
            var handler = new Handler(); var updates = new Updates(new HttpClient(handler));
            var first = updates.Check(true); var duplicate = updates.Check(true); Require(object.ReferenceEquals(first, duplicate), "Coalesce requests");
            handler.Response.SetResult(new HttpResponseMessage(HttpStatusCode.ServiceUnavailable)); await first;
            Require(updates.Result.State == "failed", "Network error state");
            var restarted = new Updates(new HttpClient(handler)); await restarted.Check(false); Require(handler.Requests == 1, "Failure limit survives restart");
            Paths.Set("AutoUpdate", "0"); await restarted.Check(false); Require(handler.Requests == 1, "Disabled scheduler");
            // This transport test uses the actual installed fixture version.
            // Keep its advertised release newer when the product version moves.
            var installedVersion = new Version(Paths.Version);
            var futureTag = "v" + new Version(installedVersion.Major, installedVersion.Minor, installedVersion.Build + 1).ToString();
            handler.Response = new TaskCompletionSource<HttpResponseMessage>(); var manual = restarted.Check(true); handler.Response.SetResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(Release(futureTag)) }); await manual;
            Require(handler.Requests == 2 && restarted.Result.State == "available", "Manual update bypass");
            var text = "测试词\tce shi ci\t3\n"; Require(DictionaryData.Parse(text).Single().Text == "测试词", "TSV import");
            Require(DictionaryData.Parse(DictionaryData.Format(DictionaryData.Parse(text))).Single().Weight == 3, "TSV roundtrip");
            foreach (var invalid in new[] { "词\t../../../x\t1", "词\tabc1\t1", "词\tci\t2147483647", "词\tci\tbad", "词\tci\t2\textra" }) Reject(() => DictionaryData.Parse(invalid));
            Reject(() => DictionaryData.ParsePersonal("词\tnotapinyin\t1"));
            var memory=new List<DictionaryRow>{new DictionaryRow{Text="原词",Code="yuan ci",Weight=4}};
            DictionaryData.TestLoad=()=>Task.FromResult(memory.Select(row=>row.Copy()).ToList());
            DictionaryData.TestImport=updates=>{
                foreach(var update in updates) {
                    var existing=memory.FirstOrDefault(row=>row.Id==update.Id);
                    if(update.Weight<0) { if(existing!=null) memory.Remove(existing); }
                    else if(existing==null) memory.Add(update.Copy());
                    else if(update.Weight>existing.Weight) existing.Weight=update.Weight;
                }
                return Task.CompletedTask;
            };
            try {
                var added=await DictionaryData.Save(new DictionaryRow{Text="星河词库",Code="xing he ci ku",Weight=1},null);
                Require(added.Any(row=>row.Text=="星河词库")&&File.Exists(DictionaryData.BackupPath),"Personal dictionary add and backup");
                var target=added.Single(row=>row.Text=="星河词库");var deleted=await DictionaryData.Delete(new[]{target});
                Require(!deleted.Any(row=>row.Text=="星河词库"),"Personal dictionary delete");
                var restored=await DictionaryData.Undo();Require(restored.Any(row=>row.Text=="星河词库")&&DictionaryData.LastChange==null,"Personal dictionary undo");
                var stale=restored.Single(row=>row.Text=="原词").Copy();memory.Single(row=>row.Id==stale.Id).Weight++;
                await RejectAsync(()=>DictionaryData.Delete(new[]{stale}));
            } finally { DictionaryData.TestLoad=null;DictionaryData.TestImport=null; }
            var oversized=Path.Combine(Paths.Root,"oversized-personal.tsv");using(var file=File.Create(oversized))file.SetLength(32L*1024*1024+1);
            Reject(()=>DictionaryData.ReadPersonal(oversized));File.Delete(oversized);
            Reject(() => Setup.RequireUpgrade(new Version("0.4.1.1"), new Version("0.4.0.999")));
            Reject(() => Setup.RequireUpgrade(new Version("0.4.0.5"), new Version("0.4.0.4")));
            Setup.RequireUpgrade(new Version("0.4.0.5"), new Version("0.4.0.5"));
            var shortcut=Path.Combine(Paths.Root,"Rime Q settings.lnk");
            Setup.CreateSettingsShortcut(shortcut,Paths.App);
            Require(File.Exists(shortcut),"Native settings shortcut");
            var startupOrder=new List<string>();
            var enableResult=await Setup.EnableAfterReady(()=>{startupOrder.Add("broker");return Task.FromResult(true);},()=>{startupOrder.Add("profile");return 0;});
            Require(enableResult==0&&startupOrder.SequenceEqual(new[]{"broker","profile"}),"Installer did not start the broker before enabling the profile");
            var enabledOnFailure=false;await RejectAsync(()=>Setup.EnableAfterReady(()=>Task.FromResult(false),()=>{enabledOnFailure=true;return 0;}));
            Require(!enabledOnFailure,"Installer enabled the profile without a ready broker");
            foreach (var entry in new[] { "../outside", "C:/outside", "/absolute", "a/../../outside", "a\\..\\outside", "file:stream" }) Reject(() => Setup.EntryPath(Paths.Root, entry));
            Require(Setup.EntryPath(Paths.Root, "data/a.yaml").StartsWith(Paths.Root), "Safe package entry");
            var bytes = Encoding.UTF8.GetBytes("Rime Q fixture\n"); string hash;
            using (var sha = SHA256.Create()) hash = BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
            var model = Path.Combine(Paths.Root, "fixture.download"); long progress = 0;
            await ModelManager.Receive(new MemoryStream(bytes), model, bytes.Length, hash, count => progress = count, CancellationToken.None);
            Require(ModelManager.Verify(model, bytes.Length, hash) && progress == bytes.Length, "Verified download and progress");
            await RejectAsync(() => ModelManager.Receive(new MemoryStream(bytes), model, bytes.Length, hash, null, CancellationToken.None));
            Require(File.Exists(model), "Never overwrite or delete an existing file"); File.Delete(model);
            await RejectAsync(() => ModelManager.Receive(new MemoryStream(bytes), model, bytes.Length - 1, hash, null, CancellationToken.None)); Require(!File.Exists(model), "Oversize cleanup");
            await RejectAsync(() => ModelManager.Receive(new MemoryStream(bytes), model, bytes.Length, new string('0',64), null, CancellationToken.None)); Require(!File.Exists(model), "Checksum failure cleanup");
            var cancellation = new CancellationTokenSource(); cancellation.Cancel();
            await RejectAsync(() => ModelManager.Receive(new MemoryStream(bytes), model, bytes.Length, hash, null, cancellation.Token)); Require(!File.Exists(model), "Cancelled download cleanup");
            Require(!ModelManager.Verify(model), "Missing optional model fallback");
        }
        [STAThread]
        static int Main(string[] args) {
            if (args.Length < 3 || args.Length > 4) return 2;
            try {
                var logicOnly=args.Length==4&&args[3]=="logic";
                AppContext.SetSwitch("Switch.System.IO.UseLegacyPathHandling",false);
                AppContext.SetSwitch("Switch.System.IO.BlockLongPaths",false);
                RenderOptions.ProcessRenderMode=RenderMode.SoftwareOnly;
                Paths.App = Path.GetFullPath(args[0]); Paths.Root = Path.GetFullPath(args[1]); Directory.CreateDirectory(Paths.Root);
                Verify().GetAwaiter().GetResult();
                var output = Path.GetFullPath(args[2]); Directory.CreateDirectory(output);
                var resourceManager=new DictionaryResources();
                resourceManager.RestartBroker=()=>{var active=Path.Combine(Paths.Root,"dictionaries","active.txt");Paths.Set("ActiveGeneration",File.Exists(active)?File.ReadAllText(active).Trim():"");return Task.CompletedTask;};
                if(args.Length==3) {
                    var fixture=Path.Combine(Paths.Root,"third-party.dict.yaml");
                    File.WriteAllText(fixture,"---\nname: 集成测试词库\nversion: '1.0'\ncolumns: [code, text, weight]\n...\nxing he ci ku\t星河词库甲乙\t900\n",new UTF8Encoding(false));
                    var draft=DictionaryImport.Read(fixture);var configured=resourceManager.Adding(draft,"集成测试词库","synthetic fixture","test only");
                    resourceManager.Apply(configured,message=>{}).GetAwaiter().GetResult();
                    Require(resourceManager.Configuration.imported.Count==1&&resourceManager.Configuration.generation!=null,"Third-party dictionary configuration");
                    DictionarySmoke(Paths.App,Paths.Root,"xingheciku","星河词库甲乙",true);
                    var disabled=resourceManager.CopyConfiguration();disabled.imported[0].enabled=false;resourceManager.Apply(disabled,message=>{}).GetAwaiter().GetResult();
                    DictionarySmoke(Paths.App,Paths.Root,"xingheciku","星河词库甲乙",false);
                    File.Delete(resourceManager.ManifestPath);Directory.CreateDirectory(resourceManager.ManifestPath);
                    var failed=resourceManager.CopyConfiguration();failed.imported[0].enabled=true;
                    Reject(()=>resourceManager.Apply(failed,message=>{}).GetAwaiter().GetResult());
                    var active=Path.Combine(Paths.Root,"dictionaries","active.txt");Require(!File.Exists(active),"Failed configuration write did not restore bundled resources");
                    Directory.Delete(resourceManager.ManifestPath);
                }
                var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown }; var model = new ModelManager();
                var canRender=!logicOnly&&CanRender();
                var settings = new SettingsWindow(new Updates(), model, resourceManager);
                int dictionaryLoads = 0;
                settings.DictionaryLoader = () => {
                    ++dictionaryLoads;
                    return Task.FromResult(new List<DictionaryRow> {
                        new DictionaryRow { Text = "测试词一", Code = "ce shi ci yi", Weight = 3 },
                        new DictionaryRow { Text = "测试词二", Code = "ce shi ci er", Weight = 5 }
                    });
                };
                settings.Window.WindowStartupLocation = WindowStartupLocation.Manual; settings.Window.Left = SystemParameters.VirtualScreenLeft; settings.Window.Top = SystemParameters.VirtualScreenTop; settings.Window.ShowActivated = false; settings.Window.Show();
                settings.ShowPage(1); Pump(20); settings.Window.UpdateLayout();
                var dictionary = Descendants<DataGrid>(settings.Window).Single();
                Require(dictionaryLoads == 1 && dictionary.Items.Count == 2, "Personal dictionary did not load when the page opened");
                Require(dictionary.Columns[0].ActualWidth > 200 && dictionary.Columns[1].ActualWidth > 250, "Personal dictionary columns are compressed");
                Require(Descendants<TextBlock>(settings.Window).Single(value=>AutomationProperties.GetName(value)=="个人词库状态").Text == "共 2 条 · 当前显示 2 条", "Personal dictionary load status");
                settings.ActivateCurrent();Pump(20);Require(dictionaryLoads==2,"Reopening settings did not refresh the current personal dictionary page");
                Descendants<Button>(settings.Window).Single(b => AutomationProperties.GetName(b)=="刷新").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                Pump(20); Require(dictionaryLoads == 3 && dictionary.Items.Count == 2, "Personal dictionary manual reload");
                settings.ShowPage(2);settings.Window.UpdateLayout();
                Require(Descendants<DataGrid>(settings.Window).Single().Items.Count==resourceManager.Catalog.Count+(args.Length==3?1:0),"Dictionary resources page did not show the catalog");
                settings.ShowPage(4); settings.Window.UpdateLayout();
                Descendants<Button>(settings.Window).Single(b => AutomationProperties.GetName(b)=="使用敲敲猫").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                Require(Appearance.Skin==6 && Paths.Get("Cat")=="1","Skin UI did not persist cat selection");
                var catPreview = Descendants<NativePreview>(settings.Window).First(p => p.Skin==6);
                Descendants<Button>(settings.Window).Single(b => AutomationProperties.GetName(b)=="试敲一下").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                if(SystemParameters.ClientAreaAnimation) { Require(catPreview.Pose!=0 && catPreview.Animating,"Preview does not animate"); Pump(210); Require(catPreview.Pose==0 && !catPreview.Animating,"Preview timer did not return to rest"); }
                settings.ShowPage(0); settings.Window.UpdateLayout();
                Descendants<ComboBox>(settings.Window).Single().SelectedItem=22;
                Require(Appearance.FontSize==22 && Descendants<NativePreview>(settings.Window).Single().CandidateSize==22,"Font UI did not update native preview");
                Require(Descendants<NativePreview>(settings.Window).Single().Height>=188,"Large cat preview is clipped");
                Appearance.Select(0); Paths.Set("FontSize","18"); Paths.Set("UpdateMessage","尚未检查更新。");
                if(!logicOnly)foreach (bool dark in new[] { false,true }) foreach (var dimensions in new[] { new Size(840,600),new Size(1000,740),new Size(1240,860) }) {
                    int width=(int)dimensions.Width, height=(int)dimensions.Height;
                    settings.SetAppearance(dark);
                    for (int page = 0; page < 5; ++page) {
                        settings.ShowPage(page);
                        var root = (FrameworkElement)settings.Window.Content; root.Width = width; root.Height = height;
                        settings.Window.UpdateLayout();root.Measure(dimensions); root.Arrange(new Rect(0,0,width,height)); root.UpdateLayout();
                        Require(Math.Abs(root.ActualWidth-width)<1 && Math.Abs(root.ActualHeight-height)<1,"Render does not match the requested client size");
                        Require(((FrameworkElement)settings.Window.FindName("Page")).ActualWidth>500,"Sidebar squeezed the content");
                        if(page==1) {
                            var header=(StackPanel)settings.Window.FindName("PageAction");
                            var add=Descendants<Button>(header).Single(button=>AutomationProperties.GetName(button)=="新增…");
                            Require(header.Children.Count==1,"Personal dictionary header should contain only Add");
                            var contents=(StackPanel)settings.Window.FindName("Page");
                            var tools=contents.Children.OfType<Grid>().Single(grid=>AutomationProperties.GetName(grid)=="个人词库工具栏");
                            var search=Descendants<TextBox>(tools).Single();var sort=Descendants<ComboBox>(tools).Single();
                            var refresh=Descendants<Button>(tools).Single(button=>AutomationProperties.GetName(button)=="刷新");
                            var sync=Descendants<Button>(tools).Single(button=>AutomationProperties.GetName(button)=="附近设备同步…");
                            var a=Bounds(add,root);var s=Bounds(search,root);var o=Bounds(sort,root);
                            var r=Bounds(refresh,root);var y=Bounds(sync,root);var row=Bounds(tools,root);
                            Require(a.Bottom<s.Top && s.Width>=160 && s.Right<=o.Left+1 && o.Right<=r.Left+1 && r.Right<=y.Left+1 && y.Right<=row.Right+1,
                                "Personal dictionary actions overlap or escape the toolbar: "+width+" "+(dark?"dark":"light"));
                            Require(Math.Abs(s.Top-y.Top)<=6,"Personal dictionary toolbar controls are not aligned");
                        }
                        if(canRender) {
                            var bitmap = new RenderTargetBitmap(width, height, 96,96,PixelFormats.Pbgra32);bitmap.Render(root);
                            Require(HasVisiblePixel(bitmap,width,height),"WPF render is transparent: page="+page+" size="+width+"x"+height);
                            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
                            using (var file = File.Create(Path.Combine(output, "settings-" + page + "-" + width + (dark?"-dark":"-light") + ".png"))) encoder.Save(file);
                        }
                    }
                }
                settings.Window.Close();app.Shutdown();
                Console.WriteLine("PASS: updates, TSV, personal dictionary parity"+(args.Length==3?", managed dictionary compile/activate/deactivate":"")+", installer policies, downloads, skin/font controls, shared native preview and animation"+
                    (logicOnly?", WPF render not requested":canRender?", 30 WPF renders":", WPF render unavailable in this desktop session")); return 0;
            } catch (Exception error) { Console.Error.WriteLine(error); return 1; }
        }
    }
}
