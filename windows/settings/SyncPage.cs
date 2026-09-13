using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

namespace RimeQ {
    internal sealed partial class SettingsWindow {
        void ShowDeviceSync(){var window=new DeviceSyncWindow(Window);window.Window.Show();}
    }
    internal sealed class DeviceSyncWindow {
        internal readonly Window Window;
        readonly StackPanel content;
        readonly TextBlock status;
        readonly DispatcherTimer timer;
        bool refreshing,working;
        SyncStatus current;
        readonly TextBox groupName=new TextBox {Text="我的电脑"},deviceName=new TextBox {Text=Environment.MachineName};
        readonly TextBox address=new TextBox(),invitation=new TextBox(),code=new TextBox {MaxLength=6};
        readonly ListBox nearby=new ListBox {Height=110,DisplayMemberPath="name"};
        readonly TextBlock inviteDetails=new TextBlock {TextWrapping=TextWrapping.Wrap};
        readonly StackPanel members=new StackPanel(),requests=new StackPanel();
        string shownGroup;
        static TextBlock Label(string text){return new TextBlock {Text=text,TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,0,0,8)};}
        static FrameworkElement Field(string label,TextBox input){var panel=new StackPanel {Margin=new Thickness(0,0,0,12)};panel.Children.Add(Label(label));input.MinHeight=30;panel.Children.Add(input);return panel;}
        Button Button(string text,Func<Task> action){var b=new Button {Content=text,Padding=new Thickness(12,6,12,6),Margin=new Thickness(0,0,8,8)};b.Click+=async(s,e)=>{if(working)return;working=true;b.IsEnabled=false;try{await action();await Refresh();}catch(Exception error){status.Text=error.Message;}finally{working=false;b.IsEnabled=true;}};return b;}
        public DeviceSyncWindow(Window owner){
            Window=new Window {Title="附近设备同步",Owner=owner,Width=660,Height=740,MinWidth=560,MinHeight=560,WindowStartupLocation=WindowStartupLocation.CenterOwner};
            Appearance.Apply(Window,Appearance.SystemDark);
            var panel=new StackPanel {Margin=new Thickness(24)};Window.Content=new ScrollViewer {Content=panel,VerticalScrollBarVisibility=ScrollBarVisibility.Auto};
            var title=Label("附近设备同步");title.FontSize=23;title.FontWeight=FontWeights.SemiBold;panel.Children.Add(title);
            panel.Children.Add(Label("每台电脑加入一次，组内自动同步已有及后续个人词条和学习权重。仅在你信任的局域网开启；本地网络或防火墙授权用于设备连接，拒绝后仍可正常打字。"));
            status=Label("正在读取设备状态…");panel.Children.Add(status);content=new StackPanel();panel.Children.Add(content);
            timer=new DispatcherTimer {Interval=TimeSpan.FromSeconds(2)};timer.Tick+=async(s,e)=>await Refresh();
            Window.Loaded+=async(s,e)=>{try{await DeviceSync.EnsureStarted();await Refresh();timer.Start();}catch(Exception error){status.Text=error.Message;}};
            Window.Closed+=(s,e)=>timer.Stop();
        }
        async Task Refresh(){
            if(refreshing)return;refreshing=true;
            try{
                await DeviceSync.EnsureStarted();current=await DeviceSync.Call<SyncStatus>(new {action="status"});
                if(shownGroup!=current.group?.id || content.Children.Count==0){shownGroup=current.group?.id;Build();}
                if(current.group==null){status.Text="尚未加入同步组。你可以创建，或加入现有设备的同步组。";nearby.ItemsSource=current.discovered.Where(d=>!string.IsNullOrEmpty(d.invite)).ToList();return;}
                var valid=current.members.Where(m=>!m.removed).ToList();status.Text=current.group.name+" · "+valid.Count+" 台设备 · "+valid.Count(m=>m.online)+" 台在线"+(current.enabled?"":" · 已暂停");
                if(!string.IsNullOrEmpty(DeviceSync.LastError))status.Text+="\n"+DeviceSync.LastError;
                if(!string.IsNullOrEmpty(current.network_error))status.Text+="\n"+current.network_error;
                members.Children.Clear();
                foreach(var member in valid){var row=new DockPanel {Margin=new Thickness(0,0,0,6)};
                    if(!member.self&&current.can_remove){var target=member;var remove=Button("移除",async()=>{if(MessageBox.Show(Window,"将“"+target.name+"”移出同步组？本机立即停止与其同步，其他设备收到移除记录后生效。已复制的词条无法远程收回。","移除设备",MessageBoxButton.YesNo,MessageBoxImage.Warning,MessageBoxResult.No)==MessageBoxResult.Yes)await DeviceSync.Call<object>(new {action="remove",id=target.id});});DockPanel.SetDock(remove,Dock.Right);row.Children.Add(remove);}
                    var text=Label(member.name+(member.self?"（本机）":"")+"\n"+(member.online?(member.applied?"已应用当前已知变更":"正在同步或等待当前输入结束"):"等待上线"));row.Children.Add(text);members.Children.Add(row);
                }
                requests.Children.Clear();foreach(var pending in current.pending){var target=pending;var row=new StackPanel {Orientation=Orientation.Horizontal};row.Children.Add(Label(target.name+" 请求加入"));row.Children.Add(Button("确认加入",async()=>{await DeviceSync.Call<object>(new {action="approve",id=target.id});}));row.Children.Add(Button("拒绝",async()=>{await DeviceSync.Call<object>(new {action="reject",id=target.id});}));requests.Children.Add(row);}
            }catch(Exception error){status.Text=error.Message;}finally{refreshing=false;}
        }
        void Build(){
            content.Children.Clear();
            if(current.group==null){
                content.Children.Add(Field("这台电脑的名称",deviceName));content.Children.Add(Field("新同步组名称",groupName));
                content.Children.Add(Button("创建同步组",async()=>{await DeviceSync.Call<object>(new {action="create",group=groupName.Text.Trim(),name=deviceName.Text.Trim()});Paths.Set("SyncStarted","1");await DeviceSync.Tick();}));
                content.Children.Add(Label("加入已有同步组"));content.Children.Add(Button("查找附近正在邀请的设备",async()=>{await DeviceSync.Call<object>(new {action="discover"});}));
                nearby.SelectionChanged+=(s,e)=>{var selected=nearby.SelectedItem as SyncNearby;if(selected!=null){address.Text=selected.address;invitation.Text=selected.invite;}};content.Children.Add(nearby);
                content.Children.Add(Field("连接地址（找不到设备时，由原设备复制）",address));content.Children.Add(Field("邀请标识（选择附近设备后自动填写）",invitation));content.Children.Add(Field("原设备显示的六位配对码",code));
                content.Children.Add(Button("加入同步组",async()=>{status.Text="正在配对，请在原设备确认加入…";await DeviceSync.Call<object>(new {action="join",address=address.Text.Trim(),invite=invitation.Text.Trim(),code=code.Text.Trim(),name=deviceName.Text.Trim()});Paths.Set("SyncStarted","1");code.Clear();await DeviceSync.Tick();}));
            }else{
                content.Children.Add(Label("已授权设备均可邀请新电脑；移除设备请在创建同步组的电脑操作。日常同步无需创建者在线。"));content.Children.Add(members);content.Children.Add(requests);
                content.Children.Add(Button("添加设备",async()=>{
                    var invite=await DeviceSync.Call<SyncInvitation>(new {action="invite"});
                    for(int i=0;invite.port==0&&i<20;i++){await Task.Delay(100);invite.port=(await DeviceSync.Call<SyncStatus>(new {action="status"})).port;}
                    var addresses=Dns.GetHostAddresses(Dns.GetHostName()).Where(a=>a.AddressFamily==AddressFamily.InterNetwork&&!IPAddress.IsLoopback(a)).Select(a=>a+":"+invite.port);
                    inviteDetails.Text="在新电脑选择此设备，输入配对码："+invite.code+"\n邀请五分钟内有效，输入正确后还需在此电脑确认。\n连接地址："+string.Join("、",addresses)+"\n邀请标识："+invite.invite;
                }));content.Children.Add(inviteDetails);
                content.Children.Add(Button("取消邀请",async()=>{await DeviceSync.Call<object>(new {action="cancel_invite"});inviteDetails.Text="";}));
                content.Children.Add(Button("立即同步",async()=>{await DeviceSync.Call<object>(new {action="sync_now"});await DeviceSync.Tick();}));
                content.Children.Add(Button("暂停 / 恢复同步",async()=>{await DeviceSync.Call<object>(new {action=current.enabled?"pause":"resume"});}));
                content.Children.Add(Button("处理未完成的同步",async()=>{if(MessageBox.Show(Window,"采用本机当前词库继续？这会覆盖本轮待应用的同步结果，并向其他设备同步本机的新增、修改与删除。两份快照会先备份。","恢复同步",MessageBoxButton.YesNo,MessageBoxImage.Warning,MessageBoxResult.No)==MessageBoxResult.Yes)await DeviceSync.RecoverLocal();}));
                content.Children.Add(Button("退出这台电脑",async()=>{if(MessageBox.Show(Window,"退出后保留本机个人词库，并归档同步记录。其他设备上的旧身份需由创建者移除；如果本机就是创建者，退出后原组将无法再移除成员。重新加入会生成新身份。","退出同步组",MessageBoxButton.YesNo,MessageBoxImage.Warning,MessageBoxResult.No)==MessageBoxResult.Yes)await DeviceSync.Leave();}));
                content.Children.Add(Button("查看同步恢复快照",()=>{System.IO.Directory.CreateDirectory(System.IO.Path.Combine(DeviceSync.Root,"backups"));Paths.Open(System.IO.Path.Combine(DeviceSync.Root,"backups"));return Task.CompletedTask;}));
            }
        }
    }
}
