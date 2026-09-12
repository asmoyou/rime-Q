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
using System.Collections.Generic;

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
        static void Reject(Action action) { bool rejected = false; try { action(); } catch { rejected = true; } Require(rejected, "Expected rejection"); }
        static async Task RejectAsync(Func<Task> action) { bool rejected = false; try { await action(); } catch { rejected = true; } Require(rejected, "Expected async rejection"); }
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
            handler.Response = new TaskCompletionSource<HttpResponseMessage>(); var manual = restarted.Check(true); handler.Response.SetResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(Release()) }); await manual;
            Require(handler.Requests == 2 && restarted.Result.State == "available", "Manual update bypass");
            var text = "测试词\tce shi ci\t3\n"; Require(DictionaryData.Parse(text).Single().Text == "测试词", "TSV import");
            Require(DictionaryData.Parse(DictionaryData.Format(DictionaryData.Parse(text))).Single().Weight == 3, "TSV roundtrip");
            foreach (var invalid in new[] { "词\t../../../x\t1", "词\tABC\t1", "词\tci\t999999999", "词\tci\tbad", "词\tci\t2\textra" }) Reject(() => DictionaryData.Parse(invalid));
            Reject(() => Setup.RequireUpgrade(new Version("0.4.1.1"), new Version("0.4.0.999")));
            Reject(() => Setup.RequireUpgrade(new Version("0.4.0.5"), new Version("0.4.0.4")));
            Setup.RequireUpgrade(new Version("0.4.0.5"), new Version("0.4.0.5"));
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
            if (args.Length != 3) return 2;
            try {
                Paths.App = Path.GetFullPath(args[0]); Paths.Root = Path.GetFullPath(args[1]); Directory.CreateDirectory(Paths.Root);
                Verify().GetAwaiter().GetResult();
                var output = Path.GetFullPath(args[2]); Directory.CreateDirectory(output);
                var app = new Application(); var model = new ModelManager();
                var settings = new SettingsWindow(new Updates(), model);
                settings.Window.WindowStartupLocation = WindowStartupLocation.Manual; settings.Window.Left = -20000; settings.Window.Top = -20000; settings.Window.ShowActivated = false; settings.Window.Show();
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
                settings.Window.SizeToContent = SizeToContent.WidthAndHeight;
                foreach (bool dark in new[] { false,true }) foreach (var dimensions in new[] { new Size(840,600),new Size(1000,740),new Size(1240,860) }) {
                    int width=(int)dimensions.Width, height=(int)dimensions.Height;
                    settings.SetAppearance(dark);
                    for (int page = 0; page < 5; ++page) {
                        settings.ShowPage(page);
                        var root = (FrameworkElement)settings.Window.Content; root.Width = width; root.Height = height;
                        settings.Window.UpdateLayout(); root.Measure(dimensions); root.Arrange(new Rect(0,0,width,height)); root.UpdateLayout();
                        Require(Math.Abs(root.ActualWidth-width)<1 && Math.Abs(root.ActualHeight-height)<1,"Render does not match the requested client size");
                        Require(((FrameworkElement)settings.Window.FindName("Page")).ActualWidth>500,"Sidebar squeezed the content");
                        var bitmap = new RenderTargetBitmap(width, height, 96,96,PixelFormats.Pbgra32); bitmap.Render(root);
                        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
                        using (var file = File.Create(Path.Combine(output, "settings-" + page + "-" + width + (dark?"-dark":"-light") + ".png"))) encoder.Save(file);
                    }
                }
                settings.Window.Close();
                Console.WriteLine("PASS: updates, TSV, installer policies, downloads, skin/font controls, shared native preview and animation, 30 WPF renders"); return 0;
            } catch (Exception error) { Console.Error.WriteLine(error); return 1; }
        }
    }
}
