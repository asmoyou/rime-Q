using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace RimeQ {
    // This entry point never starts Program, Broker, or the input method.
    // Python supplies six real helper processes on loopback with synthetic data.
    internal static class SyncUiTests {
        static IEnumerable<T> Find<T>(DependencyObject value) where T:DependencyObject {
            if(value is T)yield return (T)value;
            for(int i=0;i<VisualTreeHelper.GetChildrenCount(value);i++)foreach(var child in Find<T>(VisualTreeHelper.GetChild(value,i)))yield return child;
        }
        static void Pump(int ms) {
            var frame=new DispatcherFrame();var timer=new DispatcherTimer {Interval=TimeSpan.FromMilliseconds(ms)};
            timer.Tick+=(s,e)=>{timer.Stop();frame.Continue=false;};timer.Start();Dispatcher.PushFrame(frame);
        }
        static void Require(bool condition,string message){if(!condition)throw new Exception(message);}
        [STAThread] static int Main(string[] args) {
            if(args.Length!=4)return 2;
            try {
                Paths.App=Path.GetFullPath(args[0]);Paths.Root=Path.GetFullPath(args[1]);
                Require(File.Exists(Path.Combine(Paths.Root,"sync","isolated-test-only")),"Only synthetic service roots may be used");
                Require(Paths.Get("SyncStarted","0")=="0","Native engine synchronization must remain disabled in the UI-only test");
                RenderOptions.ProcessRenderMode=System.Windows.Interop.RenderMode.SoftwareOnly;
                var app=new Application {ShutdownMode=ShutdownMode.OnExplicitShutdown};
                System.Threading.SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(Dispatcher.CurrentDispatcher));
                var view=new DeviceSyncWindow(null);view.Window.ShowActivated=false;view.Window.Show();Pump(3200);
                var joined=args[3]=="group";
                if(joined){
                    Require(Find<TextBlock>(view.Window).Any(t=>t.Text.Contains("6 台设备")),"Six-device summary missing");
                    Require(Find<TextBlock>(view.Window).Count(t=>t.Text.StartsWith("Test device "))==6,"Device rows missing");
                    var toggle=Find<Button>(view.Window).Single(b=>Convert.ToString(b.Content)=="暂停同步");
                    toggle.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Pump(2400);
                    Require(Find<TextBlock>(view.Window).Any(t=>t.Text.Contains("已暂停")),"Pause state did not update");
                    toggle.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Pump(2400);
                    Require(!Find<TextBlock>(view.Window).Any(t=>t.Text.Contains("已暂停")),"Resume state did not update");
                } else Require(Find<TextBox>(view.Window).Count()==5,"Create/join form missing fields");
                var root=(FrameworkElement)view.Window.Content;root.Width=640;root.Height=700;
                root.Measure(new Size(640,700));root.Arrange(new Rect(0,0,640,700));root.UpdateLayout();
                var bitmap=new RenderTargetBitmap(640,700,96,96,PixelFormats.Pbgra32);var background=new DrawingVisual();using(var drawing=background.RenderOpen())drawing.DrawRectangle(view.Window.Background??Brushes.White,null,new Rect(0,0,640,700));bitmap.Render(background);bitmap.Render(root);
                var pixels=new byte[640*700*4];bitmap.CopyPixels(pixels,640*4,0);
                Require(Enumerable.Range(0,640*700).Any(i=>pixels[i*4+3]!=0),"WPF render unavailable");
                var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(args[2])));
                using(var stream=File.Create(args[2]))encoder.Save(stream);
                view.Window.Close();app.Shutdown();
                Console.WriteLine("PASS native sync window: "+(joined?"six real services, device rows, pause and resume":"create/join form")+", WPF render");return 0;
            }catch(Exception error){Console.Error.WriteLine(error.Message);return 1;}
        }
    }
}
