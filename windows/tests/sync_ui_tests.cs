using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Reflection;
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
        static void SetPrivate(object target,string name,object value){
            target.GetType().GetField(name,BindingFlags.Instance|BindingFlags.NonPublic).SetValue(target,value);
        }
        static object GetPrivate(object target,string name){
            return target.GetType().GetField(name,BindingFlags.Instance|BindingFlags.NonPublic).GetValue(target);
        }
        static void InvokePrivate(object target,string name){
            target.GetType().GetMethod(name,BindingFlags.Instance|BindingFlags.NonPublic).Invoke(target,null);
        }
        static void Require(bool condition,string message){if(!condition)throw new Exception(message);}
        [STAThread] static int Main(string[] args) {
            if(args.Length!=4)return 2;
            try {
                Paths.App=Path.GetFullPath(args[0]);Paths.Root=Path.GetFullPath(args[1]);
                Require(File.Exists(Path.Combine(Paths.Root,"sync","isolated-test-only")),"Only synthetic service roots may be used");
                Require(Paths.Get("SyncStarted","0")=="0","Native engine synchronization must remain disabled in the UI-only test");
                string parsedAddress,parsedInvite;
                var macInfo="Rime Q 连接信息\n连接地址：192.168.1.8:12345\n邀请标识：synthetic-invite";
                Require(SyncConnectionInfo.TryParse(macInfo,out parsedAddress,out parsedInvite)&&parsedAddress=="192.168.1.8:12345"&&parsedInvite=="synthetic-invite","macOS connection information could not be pasted on Windows");
                Require(SyncConnectionInfo.Format(parsedAddress,parsedInvite)==macInfo,"Windows connection information does not match macOS");
                Require(SyncConnectionInfo.TryParse(macInfo.Replace("\n","\r\n"),out parsedAddress,out parsedInvite),"CRLF connection information rejected");
                Require(!SyncConnectionInfo.TryParse("192.168.1.8:12345\nsynthetic-invite",out parsedAddress,out parsedInvite)&&
                        !SyncConnectionInfo.TryParse("连接地址： \n邀请标识：synthetic-invite",out parsedAddress,out parsedInvite)&&
                        !SyncConnectionInfo.TryParse(new string('a',4097),out parsedAddress,out parsedInvite),"Malformed or oversized clipboard information accepted");
                bool errorCase=args[3]=="error",upgradeCase=args[3]=="upgrade";
                if(errorCase){Require(!File.Exists(Path.Combine(Paths.App,"RimeQ.Sync.exe")),"Error fixture unexpectedly contains a helper");Paths.Set("SyncStarted","1");}
                RenderOptions.ProcessRenderMode=System.Windows.Interop.RenderMode.SoftwareOnly;
                var app=new Application {ShutdownMode=ShutdownMode.OnExplicitShutdown};
                System.Threading.SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(Dispatcher.CurrentDispatcher));
                var view=new DeviceSyncWindow(null);view.Window.ShowActivated=false;view.Window.Show();Pump(3200);
                Window rendered=view.Window;
                SyncWizard wizard=null;
                bool invite=args[3]=="invite",joined=args[3].StartsWith("group")||invite,off=args[3]=="off"||args[3]=="off-dark",darkCase=args[3]=="off-dark"||args[3]=="group-dark";
                if(upgradeCase){
                    ((DispatcherTimer)GetPrivate(view,"timer")).Stop();
                    var fixture=new SyncStatus {
                        id="windows",group=new SyncGroup {id="fixture",name="我的电脑"},enabled=true,last_sync_at=0,
                        network_error="设备的同步协议版本不一致，请将两端 Rime Q 都升级到支持完整学习记录同步的版本；无需重新配对，本机词库保留。",
                        members=new List<SyncMember>{
                            new SyncMember {id="windows",name="Windows 电脑",self=true,online=true,applied=true},
                            new SyncMember {id="mac",name="MacBook",online=false,applied=false,needs_upgrade=true}
                        },
                        progress=new SyncProgress {stage="等待设备升级",confirmed=1,total=2,elapsed_seconds=45}
                    };
                    SetPrivate(view,"current",fixture);SetPrivate(view,"joined",true);
                    InvokePrivate(view,"Build");InvokePrivate(view,"UpdateProgress");InvokePrivate(view,"ShowMembers");Pump(200);
                    ((TextBlock)GetPrivate(view,"status")).Text=fixture.group.name+" · 2 台设备 · 1 台在线\n"+fixture.network_error;
                    Require(Find<TextBlock>(view.Window).Any(t=>t.Text.Contains("请先升级组内其他设备")),"Upgrade reason missing beside last sync time");
                    Require(Find<TextBlock>(view.Window).Any(t=>t.Text.Contains("最近成功：尚无记录 · 需要升级")),"Upgrade reason missing from peer row");
                    Require(Find<TextBlock>(view.Window).Any(t=>t.Text=="需要升级"),"Peer upgrade state missing");
                }
                if(errorCase){
                    var retry=Find<Button>(view.Window).Single(b=>Convert.ToString(b.Content)=="重试连接");
                    Require(retry.Visibility==Visibility.Visible&&Find<TextBlock>(view.Window).Any(t=>t.Text.Contains("同步组件缺失")),"Failed service did not show retry and error");
                    retry.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Pump(200);
                    Require(retry.Visibility==Visibility.Visible,"Retry disappeared after another failure");
                }
                if(joined){
                    Require(Find<TextBlock>(view.Window).Any(t=>t.Text.StartsWith("最近成功同步：")),"Last success time missing");
                    Require(Find<TextBlock>(view.Window).Any(t=>t.Text.StartsWith("最近成功同步：")&&!t.Text.EndsWith("尚无成功记录")),"Persisted success time not displayed");
                    Require(Find<TextBlock>(view.Window).Any(t=>t.Text.Contains("台设备已确认"))&&Find<ProgressBar>(view.Window).Any(),"Confirmation count/progress bar missing");
                    Require(Find<TextBlock>(view.Window).Any(t=>t.Text.Contains("6 台设备")),"Six-device summary missing");
                    Require(Find<TextBlock>(view.Window).Count(t=>t.Text.StartsWith("Test device "))==6,"Device rows missing");
                    // Leaving and rejoining must not reparent a list still
                    // owned by an obsolete card from the previous group.
                    SetPrivate(view,"joined",false);InvokePrivate(view,"Build");
                    SetPrivate(view,"joined",true);InvokePrivate(view,"Build");InvokePrivate(view,"ShowMembers");InvokePrivate(view,"UpdateProgress");view.Window.UpdateLayout();
                    var shown=(SyncStatus)GetPrivate(view,"current");
                    var progress=(TextBlock)GetPrivate(view,"syncProgress");
                    var searchPosition=((TextBox)GetPrivate(view,"search")).TransformToAncestor(view.Window).Transform(new Point(0,0));
                    var stable=progress.Text;
                    for(int cycle=0;cycle<6;cycle++){
                        shown.progress.transfer=cycle%2==0?"正在连接其他设备":null;shown.progress.transfer_seconds=cycle;
                        InvokePrivate(view,"UpdateProgress");view.Window.UpdateLayout();
                        Require(progress.Text==stable,"Idle transport leaked into user-visible progress");
                        var position=((TextBox)GetPrivate(view,"search")).TransformToAncestor(view.Window).Transform(new Point(0,0));
                        Require(Math.Abs(position.Y-searchPosition.Y)<0.1,"Connection status moved the device list");
                    }
                    var toggle=Find<Button>(view.Window).Single(b=>Convert.ToString(b.Content)=="暂停同步");
                    toggle.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Pump(2400);
                    Require(Find<TextBlock>(view.Window).Any(t=>t.Text.Contains("已暂停")),"Pause state did not update");
                    toggle.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Pump(2400);
                    Require(!Find<TextBlock>(view.Window).Any(t=>t.Text.Contains("已暂停")),"Resume state did not update");
                    var search=Find<TextBox>(view.Window).Single();search.Text="not present";Pump(300);
                    Require(Find<TextBlock>(view.Window).Any(t=>t.Text=="没有匹配的设备。"),"Search empty result missing");
                    search.Clear();Pump(300);
                    Require(Find<TextBlock>(view.Window).Count(t=>t.Text.StartsWith("Test device "))==6,"Device rows did not return after search");
                    if(invite){
                        wizard=new SyncWizard(view.Window,SyncWizard.Mode.Invite,()=>System.Threading.Tasks.Task.CompletedTask);
                        wizard.Window.ShowActivated=false;wizard.Window.Show();Pump(1500);
                        Require(Find<TextBlock>(wizard.Window).Any(t=>t.Text.StartsWith("邀请剩余")),"Invitation countdown missing");
                        Require(Find<Button>(wizard.Window).Any(b=>Convert.ToString(b.Content)=="复制配对码"&&b.IsEnabled),"Invitation copy state missing");
                        Find<TextBlock>(wizard.Window).Single(t=>t.FontSize==34).Text="••••••";
                        rendered=wizard.Window;
                    }
                } else if(!errorCase&&!upgradeCase) {
                    Require(Find<Button>(view.Window).Any(b=>Convert.ToString(b.Content)=="创建同步组")&&Find<Button>(view.Window).Any(b=>Convert.ToString(b.Content)=="加入已有同步组"),"Distinct create/join entry points missing");
                    if(off)Require(!File.Exists(Path.Combine(Paths.Root,"sync","identity.key"))&&!File.Exists(Path.Combine(Paths.Root,"sync","control.json")),"Viewing disabled sync created an identity or helper");
                    else {
                        wizard=new SyncWizard(view.Window,SyncWizard.Mode.Join,()=>System.Threading.Tasks.Task.CompletedTask);
                        wizard.Window.ShowActivated=false;wizard.Window.Show();Pump(1200);
                        Require(Find<TextBox>(wizard.Window).Count()>=2&&Find<CheckBox>(wizard.Window).Any(),"Join wizard missing code or manual connection fields");
                        Require(Find<Button>(wizard.Window).Any(b=>Convert.ToString(b.Content)=="重新查找"),"Join discovery refresh missing");
                        var join=Find<Button>(wizard.Window).Single(b=>Convert.ToString(b.Content)=="加入同步组");
                        Require(!join.IsEnabled,"Incomplete join form accepted");
                        var manual=Find<CheckBox>(wizard.Window).Single();manual.IsChecked=true;Pump(150);
                        var fields=Find<TextBox>(wizard.Window).ToList();
                        fields[0].Text="测试电脑";
                        var code=fields.Single(f=>f.FontSize==22);code.Text="１２３４５６";
                        Require(code.Text=="123456"&&!join.IsEnabled,"Six-digit normalization or connection validation failed");
                        fields[fields.Count-2].Text="127.0.0.1:12345";fields[fields.Count-1].Text="synthetic-invite";Pump(150);
                        Require(join.IsEnabled,"Valid manual join form stayed disabled");
                        code.Clear();manual.IsChecked=false;rendered=wizard.Window;
                    }
                }
                foreach(var window in wizard==null?new[]{view.Window}:new[]{view.Window,wizard.Window}){
                    SyncStyle.Update(window,true);
                    if(!SystemParameters.HighContrast)Require(((SolidColorBrush)window.Background).Color==(Color)ColorConverter.ConvertFromString("#202226")&&
                            ((SolidColorBrush)window.Foreground).Color==(Color)ColorConverter.ConvertFromString("#F2F2F7"),"Sync window did not adopt dark app mode");
                    SyncStyle.Update(window,false);
                    if(!SystemParameters.HighContrast)Require(((SolidColorBrush)window.Background).Color==(Color)ColorConverter.ConvertFromString("#F6F7F9")&&
                            ((SolidColorBrush)window.Foreground).Color==(Color)ColorConverter.ConvertFromString("#202124"),"Sync window did not return to light app mode");
                    SyncStyle.Update(window,Appearance.SystemDark);
                }
                if(darkCase)SyncStyle.Update(rendered,true);
                var width=rendered==view.Window?640:560;var height=rendered==view.Window?(args[3]=="group-compact"?560:780):invite?480:650;
                var root=(FrameworkElement)rendered.Content;root.Width=width;root.Height=height;rendered.MinWidth=0;rendered.MinHeight=0;rendered.SizeToContent=SizeToContent.WidthAndHeight;rendered.UpdateLayout();Pump(100);
                root.Measure(new Size(width,height));root.Arrange(new Rect(0,0,width,height));root.UpdateLayout();
                var bitmap=new RenderTargetBitmap(width,height,96,96,PixelFormats.Pbgra32);var background=new DrawingVisual();using(var drawing=background.RenderOpen()){drawing.DrawRectangle(rendered.Background??Brushes.White,null,new Rect(0,0,width,height));drawing.DrawRectangle(new VisualBrush(root) {ViewboxUnits=BrushMappingMode.Absolute,Viewbox=new Rect(0,0,width,height),Stretch=Stretch.Fill},null,new Rect(0,0,width,height));}bitmap.Render(background);
                var pixels=new byte[width*height*4];bitmap.CopyPixels(pixels,width*4,0);
                Require(Enumerable.Range(0,width*height).Any(i=>pixels[i*4+3]!=0),"WPF render unavailable");
                var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(args[2])));
                using(var stream=File.Create(args[2]))encoder.Save(stream);
                if(invite){Find<Button>(wizard.Window).Single(b=>Convert.ToString(b.Content)=="关闭邀请").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Pump(500);}
                wizard?.Window.Close();view.Window.Close();app.Shutdown();
                Console.WriteLine("PASS native sync window: "+(upgradeCase?"missing success time explains peer upgrade":invite?"invitation countdown and copy state":joined?"six real services, device rows, pause, resume and search":errorCase?"persistent failure retry":off?"disabled view without helper or identity":"create/join wizard")+", macOS/Windows connection format, app light/dark resources, WPF render");return 0;
            }catch(Exception error){Console.Error.WriteLine(error.ToString());return 1;}
        }
    }
}
