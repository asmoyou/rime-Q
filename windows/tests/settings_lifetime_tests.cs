using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Threading;

namespace RimeQ {
    internal static class SettingsLifetimeTests {
        static void Pump(int milliseconds) {
            var frame=new DispatcherFrame();var timer=new DispatcherTimer {Interval=TimeSpan.FromMilliseconds(milliseconds)};
            timer.Tick+=(s,e)=>{timer.Stop();frame.Continue=false;};timer.Start();Dispatcher.PushFrame(frame);
        }
        static void Require(bool value,string error){if(!value)throw new Exception(error);}
        static object Measure(string stage) {
            Pump(1500);using(var process=Process.GetCurrentProcess()) {
                process.Refresh();return new {stage=stage,rss_bytes=process.WorkingSet64,private_bytes=process.PrivateMemorySize64};
            }
        }
        [MethodImpl(MethodImplOptions.NoInlining)]
        static WeakReference OpenClose(Updates updates,ModelManager model,DictionaryResources resources) {
            var window=Program.OpenSettings(updates,model,resources,0);
            Require(ReferenceEquals(window,Program.OpenSettings(updates,model,resources,null)),"Opening settings created duplicate windows");
            var result=new WeakReference(window);window.Window.Close();return result;
        }
        [MethodImpl(MethodImplOptions.NoInlining)]
        static WeakReference CloseWhileLoading(Updates updates,ModelManager model,DictionaryResources resources) {
            var window=Program.OpenSettings(updates,model,resources,0);
            var delayed=new TaskCompletionSource<List<DictionaryRow>>();window.DictionaryLoader=()=>delayed.Task;
            window.ShowPage(1);window.Window.Close();
            delayed.SetResult(new List<DictionaryRow>{new DictionaryRow{Text="Synthetic",Code="ce shi",Weight=1}});
            Pump(100);return new WeakReference(window);
        }
        [STAThread] static int Main(string[] args) {
            try {
                Paths.App=Path.GetFullPath(args[0]);Paths.Root=Path.GetFullPath(args[1]);Directory.CreateDirectory(Paths.Root);
                Paths.Set("AutoUpdate","0");Paths.Set("SyncStarted","0");
                var app=new Application {ShutdownMode=ShutdownMode.OnExplicitShutdown};
                var updates=new Updates();var model=new ModelManager();var resources=new DictionaryResources();
                bool eager=args[2]=="eager";SettingsWindow retained=null;
                if(eager)retained=new SettingsWindow(updates,model,resources);
                Require(eager||app.Windows.Count==0,"Background startup constructed a settings window");
                var samples=new List<object>{Measure("background_before_open")};
                var shown=eager?retained:Program.OpenSettings(updates,model,resources,0);
                shown.Window.Show();samples.Add(Measure("settings_open"));
                var reference=new WeakReference(shown);
                if(eager)shown.Window.Hide();else shown.Window.Close();shown=null;
                samples.Add(Measure("after_close_without_forced_gc"));
                // Collection is only a test for retained references, never a product memory trim.
                Pump(100);GC.Collect();GC.WaitForPendingFinalizers();GC.Collect();
                if(!eager)Require(!reference.IsAlive,"Closed settings retained by background host or event subscriptions");
                samples.Add(Measure("after_test_gc"));
                if(!eager) {
                    var refs=new List<WeakReference>();
                    for(int i=0;i<5;i++){refs.Add(OpenClose(updates,model,resources));Pump(50);}
                    refs.Add(CloseWhileLoading(updates,model,resources));Pump(100);
                    GC.Collect();GC.WaitForPendingFinalizers();GC.Collect();
                    foreach(var item in refs)Require(!item.IsAlive,"Reopened or asynchronously loading window leaked");
                    Require(app.Windows.Count==0,"Closing settings left windows alive");
                } else retained.Window.Close();
                File.WriteAllText(args[3],new JavaScriptSerializer().Serialize(new {mode=args[2],samples=samples}));
                app.Shutdown();Console.WriteLine("PASS settings lifetime: "+args[2]);return 0;
            }catch(Exception error){Console.Error.WriteLine(error);return 1;}
        }
    }
}
