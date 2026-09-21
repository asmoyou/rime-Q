using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;

namespace RimeQ {
    internal static class SyncStyle {
        internal static void Update(Window window,bool dark){Appearance.Apply(window,dark);}
        internal static void Apply(Window window) {
            using(var stream=Assembly.GetExecutingAssembly().GetManifestResourceStream("Shell.xaml")) {
                var shell=(Window)XamlReader.Load(stream);window.Resources=shell.Resources;
            }
            window.FontFamily=new FontFamily("Segoe UI, Microsoft YaHei UI");
            window.FontSize=13;window.UseLayoutRounding=true;
            window.SetResourceReference(Window.BackgroundProperty,"WindowBackground");
            window.SetResourceReference(Window.ForegroundProperty,"TextColor");
            Update(window,Appearance.SystemDark);
            bool closed=false;
            UserPreferenceChangedEventHandler changed=(sender,args)=>{
                if(window.Dispatcher.HasShutdownStarted)return;
                window.Dispatcher.BeginInvoke(new Action(()=>{if(!closed)Update(window,Appearance.SystemDark);}));
            };
            SystemEvents.UserPreferenceChanged+=changed;
            window.Closed+=(sender,args)=>{closed=true;SystemEvents.UserPreferenceChanged-=changed;};
        }
    }
    internal static class SyncConnectionInfo {
        internal static string Format(string address,string invite){
            return "Rime Q 连接信息\n连接地址："+address+"\n邀请标识："+invite;
        }
        internal static bool TryParse(string text,out string address,out string invite){
            address=null;invite=null;
            if(text==null||Encoding.UTF8.GetByteCount(text)>4096)return false;
            foreach(var line in text.Split(new[]{'\r','\n'},StringSplitOptions.RemoveEmptyEntries)){
                if(address==null&&line.StartsWith("连接地址：",StringComparison.Ordinal))address=line.Substring("连接地址：".Length).Trim();
                if(invite==null&&line.StartsWith("邀请标识：",StringComparison.Ordinal))invite=line.Substring("邀请标识：".Length).Trim();
            }
            return !string.IsNullOrWhiteSpace(address)&&!string.IsNullOrWhiteSpace(invite);
        }
    }
    internal sealed partial class SettingsWindow {
        void ShowDeviceSync(){var window=new DeviceSyncWindow(Window);window.Window.Show();}
    }
    internal sealed class DeviceSyncWindow {
        internal readonly Window Window;
        readonly StackPanel content=new StackPanel(),members=new StackPanel(),requests=new StackPanel();
        readonly TextBlock status=Label("正在读取设备状态…"),empty=Label("");
        readonly TextBlock syncTime=Label(""),syncProgress=Label("");
        readonly ProgressBar confirmation=new ProgressBar {Height=4,Margin=new Thickness(0,0,0,16),Visibility=Visibility.Collapsed};
        readonly Button retryButton;
        readonly TextBox search=new TextBox {MinHeight=30,Margin=new Thickness(0,0,0,12)};
        readonly DispatcherTimer timer=new DispatcherTimer {Interval=TimeSpan.FromSeconds(1)};
        readonly Dictionary<string,DeviceRow> rows=new Dictionary<string,DeviceRow>();
        SyncStatus current;
        bool refreshing,working,joined;
        Button pauseButton;
        internal static TextBlock Label(string text){return new TextBlock {Text=text,TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,0,0,8)};}
        internal static Button Action(string text,Action click){
            var button=new Button {Content=text,HorizontalAlignment=HorizontalAlignment.Left,Padding=new Thickness(12,6,12,6),Margin=new Thickness(0,0,8,8)};
            button.Click+=(s,e)=>click();return button;
        }
        Button Command(string text,Func<Task> action){
            Button button=null;button=Action(text,async()=>{
                if(working)return;working=true;button.IsEnabled=false;
                try{await action();while(refreshing)await Task.Delay(30);await Refresh();}
                catch(Exception error){status.Text=error.Message;retryButton.Visibility=Visibility.Visible;}
                finally{working=false;button.IsEnabled=true;}
            });return button;
        }
        public DeviceSyncWindow(Window owner){
            Window=new Window {Title="附近设备同步",Owner=owner,Width=700,Height=700,MinWidth=560,MinHeight=500,WindowStartupLocation=owner==null?WindowStartupLocation.CenterScreen:WindowStartupLocation.CenterOwner};
            SyncStyle.Apply(Window);
            var panel=new StackPanel {Margin=new Thickness(24)};
            Window.Content=new ScrollViewer {Content=panel,VerticalScrollBarVisibility=ScrollBarVisibility.Auto};
            var title=Label("附近设备同步");title.FontSize=23;title.FontWeight=FontWeights.SemiBold;panel.Children.Add(title);
            panel.Children.Add(Label("只在你信任的局域网开启。同步个人词条和学习权重；本地网络或防火墙授权被拒绝时，输入与本机学习不受影响。"));
            panel.Children.Add(status);
            panel.Children.Add(syncTime);panel.Children.Add(syncProgress);panel.Children.Add(confirmation);
            syncTime.ToolTip="本机观察到双方已应用同一已知版本的时间；无新变更的检查不会更新时间。离线设备仍可能有未传出的变更。";
            retryButton=Command("重试连接",()=>DeviceSync.EnsureStarted(true));
            retryButton.Visibility=Visibility.Collapsed;panel.Children.Add(retryButton);panel.Children.Add(content);
            timer.Tick+=async(s,e)=>{UpdateProgress();await Refresh();};
            DeviceSync.Changed+=UpdateProgress;
            Window.Loaded+=async(s,e)=>{await Refresh();timer.Start();};
            Window.Closed+=(s,e)=>{timer.Stop();DeviceSync.Changed-=UpdateProgress;};
            search.TextChanged+=(s,e)=>ShowMembers();
            AutomationProperties.SetName(search,"搜索设备");
        }
        async Task Refresh(){
            if(refreshing)return;refreshing=true;
            try{
                current=await DeviceSync.DisplayStatus();
                retryButton.Visibility=Visibility.Collapsed;
                bool isJoined=current.group!=null;
                UpdateProgress();
                if(content.Children.Count==0||joined!=isJoined){joined=isJoined;Build();}
                if(!isJoined){status.Text="尚未加入同步组。你可以创建，或加入已有设备的同步组。";return;}
                var valid=(current.members??new List<SyncMember>()).Where(m=>!m.removed).ToList();
                status.Text=current.group.name+" · "+valid.Count+" 台设备 · "+valid.Count(m=>m.online)+" 台在线"+(current.enabled?"":" · 已暂停");
                if(!string.IsNullOrEmpty(DeviceSync.LastError))status.Text+="\n"+DeviceSync.LastError;
                if(!string.IsNullOrEmpty(current.network_error))status.Text+="\n"+current.network_error;
                pauseButton.Content=current.enabled?"暂停同步":"恢复同步";
                ShowMembers();
                requests.Children.Clear();
                foreach(var pending in current.pending??new List<SyncPending>()){
                    var target=pending;var row=new StackPanel {Orientation=Orientation.Horizontal,Margin=new Thickness(0,0,0,8)};
                    row.Children.Add(Label(target.name+" 请求加入"));
                    row.Children.Add(Command("确认加入",()=>DeviceSync.Call<object>(new {action="approve",id=target.id})));
                    row.Children.Add(Command("拒绝",()=>DeviceSync.Call<object>(new {action="reject",id=target.id})));
                    requests.Children.Add(row);
                }
            }catch(Exception error){
                status.Text=error.Message;
                syncProgress.Text="服务暂不可用，请点重试连接";
                retryButton.Visibility=Visibility.Visible;
                if(content.Children.Count==0){joined=false;Build();}
            }finally{refreshing=false;}
        }
        void UpdateProgress(){
            bool visible=current!=null&&current.group!=null;
            syncTime.Visibility=syncProgress.Visibility=confirmation.Visibility=visible?Visibility.Visible:Visibility.Collapsed;
            if(!visible)return;
            syncTime.Text="最近成功同步："+DeviceSync.SuccessSummary(current);
            syncProgress.Text=DeviceSync.ProgressText(current);
            confirmation.Maximum=Math.Max(1,current.progress==null?0:current.progress.total);
            confirmation.Value=current.progress==null?0:current.progress.confirmed;
            AutomationProperties.SetName(confirmation,"当前已知变更的设备确认进度");
        }
        void ShowMembers(){
            if(current==null||current.group==null)return;
            var valid=(current.members??new List<SyncMember>()).Where(m=>!m.removed)
                .OrderByDescending(m=>m.self).ThenByDescending(m=>m.online).ThenBy(m=>m.name,StringComparer.CurrentCultureIgnoreCase).ToList();
            var keep=new HashSet<string>(valid.Select(m=>m.id));
            foreach(var id in rows.Keys.Where(id=>!keep.Contains(id)).ToList())rows.Remove(id);
            var visible=new List<UIElement>();
            var term=search.Text.Trim();
            foreach(var member in valid){
                if(term.Length>0&&(member.name??"").IndexOf(term,StringComparison.CurrentCultureIgnoreCase)<0)continue;
                DeviceRow row;
                if(!rows.TryGetValue(member.id,out row)){
                    row=new DeviceRow(member.id);rows.Add(member.id,row);
                }
                row.Update(member,!current.enabled,current.can_remove,()=>Remove(member));
                visible.Add(row.Panel);
            }
            if(members.Children.Count!=visible.Count||!members.Children.Cast<UIElement>().SequenceEqual(visible)){
                members.Children.Clear();foreach(var row in visible)members.Children.Add(row);
            }
            empty.Text=visible.Count==0?(term.Length>0?"没有匹配的设备。":"尚无已授权设备。"):"";
        }
        async Task Remove(SyncMember member){
            if(MessageBox.Show(Window,"将“"+member.name+"”移出同步组？\n\n其他设备收到移除记录后停止与其同步。已复制的词条无法远程收回。","移除设备",MessageBoxButton.YesNo,MessageBoxImage.Warning,MessageBoxResult.No)!=MessageBoxResult.Yes)return;
            await DeviceSync.Call<object>(new {action="remove",id=member.id});
            while(refreshing)await Task.Delay(30);await Refresh();
        }
        void OpenWizard(SyncWizard.Mode mode){
            var wizard=new SyncWizard(Window,mode,async()=>{while(refreshing)await Task.Delay(30);await Refresh();});
            wizard.Window.ShowDialog();
        }
        void Build(){
            content.Children.Clear();rows.Clear();
            if(!joined){
                var choices=new Grid {Margin=new Thickness(0,12,0,16)};
                choices.ColumnDefinitions.Add(new ColumnDefinition());choices.ColumnDefinitions.Add(new ColumnDefinition());
                void Choice(int column,string title,string detail,string command,SyncWizard.Mode mode){
                    var panel=new StackPanel();
                    var heading=Label(title);heading.FontSize=16;heading.FontWeight=FontWeights.SemiBold;panel.Children.Add(heading);
                    var description=Label(detail);description.SetResourceReference(TextBlock.ForegroundProperty,"SecondaryColor");panel.Children.Add(description);
                    panel.Children.Add(Action(command,()=>OpenWizard(mode)));
                    var border=new Border {CornerRadius=new CornerRadius(6),BorderThickness=new Thickness(1),Padding=new Thickness(16),Margin=new Thickness(column==0?0:7,0,column==0?7:0,0),Child=panel};
                    border.SetResourceReference(Border.BackgroundProperty,"CardBackground");border.SetResourceReference(Border.BorderBrushProperty,"BorderColor");
                    Grid.SetColumn(border,column);choices.Children.Add(border);
                }
                Choice(0,"从这台电脑开始","创建同步组，再邀请你的其他电脑。","创建同步组",SyncWizard.Mode.Create);
                Choice(1,"连接已有的电脑","输入另一台电脑邀请窗口的配对码。","加入已有同步组",SyncWizard.Mode.Join);
                content.Children.Add(choices);
                content.Children.Add(Label("每台电脑只需加入一次；创建者不必持续在线。"));
                return;
            }
            content.Children.Add(Label("所有已授权设备都可邀请新电脑；只有创建同步组的电脑可移除设备。"));
            content.Children.Add(Label("搜索设备"));content.Children.Add(search);content.Children.Add(empty);content.Children.Add(members);
            content.Children.Add(requests);
            var actions=new StackPanel {Orientation=Orientation.Horizontal,Margin=new Thickness(0,10,0,0)};
            actions.Children.Add(Action("添加设备",()=>OpenWizard(SyncWizard.Mode.Invite)));
            actions.Children.Add(Command("立即同步",async()=>{await DeviceSync.Call<object>(new {action="sync_now"});await DeviceSync.Tick(true);}));
            pauseButton=Command(current.enabled?"暂停同步":"恢复同步",()=>DeviceSync.Call<object>(new {action=current.enabled?"pause":"resume"}));
            actions.Children.Add(pauseButton);
            var more=Action("更多",()=>{});var menu=new ContextMenu();
            void Option(string title,Action action){var item=new MenuItem {Header=title};item.Click+=(s,e)=>action();menu.Items.Add(item);}
            Option("查看同步恢复快照",()=>{
                var folder=System.IO.Path.Combine(DeviceSync.Root,"backups");
                System.IO.Directory.CreateDirectory(folder);Paths.Open(folder);
            });
            Option("处理未完成的同步…",async()=>{
                if(MessageBox.Show(Window,"采用本机当前词库继续？两份快照会先备份，再传播本机的新增、修改和删除。","恢复同步",MessageBoxButton.YesNo,MessageBoxImage.Warning,MessageBoxResult.No)==MessageBoxResult.Yes)
                    try{await DeviceSync.RecoverLocal();await Refresh();}catch(Exception error){status.Text=error.Message;}
            });
            Option("退出这台电脑…",async()=>{
                if(MessageBox.Show(Window,"退出后保留本机个人词库并归档同步记录。其他设备上的旧身份需要创建者移除；创建者退出后原组无法再移除成员。","退出同步组",MessageBoxButton.YesNo,MessageBoxImage.Warning,MessageBoxResult.No)==MessageBoxResult.Yes)
                    try{await DeviceSync.Leave();await Refresh();}catch(Exception error){status.Text=error.Message;}
            });
            more.ContextMenu=menu;more.Click+=(s,e)=>{menu.PlacementTarget=more;menu.IsOpen=true;};
            actions.Children.Add(more);content.Children.Add(actions);
        }
        sealed class DeviceRow {
            internal readonly DockPanel Panel=new DockPanel {Margin=new Thickness(0,0,0,8),MinHeight=50};
            readonly TextBlock text=Label(""),state=Label("");
            readonly Button options=Action("⋯",()=>{});
            Action remove;
            internal DeviceRow(string id){
                options.ToolTip="设备选项";options.Width=34;options.MinWidth=34;
                options.Content=new TextBlock {Text="\uE10C",FontFamily=new FontFamily("Segoe MDL2 Assets"),FontSize=15,TextAlignment=TextAlignment.Center};
                options.Click+=(s,e)=>{
                    var menu=new ContextMenu();var item=new MenuItem {Header="移除这台设备…"};
                    item.Click+=(sender,args)=>remove?.Invoke();menu.Items.Add(item);menu.PlacementTarget=options;menu.IsOpen=true;
                };
                DockPanel.SetDock(options,Dock.Right);Panel.Children.Add(options);
                DockPanel.SetDock(state,Dock.Right);state.Margin=new Thickness(10,4,12,0);Panel.Children.Add(state);
                text.Margin=new Thickness(0,4,0,0);text.MaxWidth=350;text.HorizontalAlignment=HorizontalAlignment.Left;text.TextWrapping=TextWrapping.NoWrap;
                text.TextTrimming=TextTrimming.CharacterEllipsis;Panel.Children.Add(text);
            }
            internal void Update(SyncMember member,bool paused,bool canRemove,Func<Task> action){
                text.Text=member.name+(member.self?"（本机）":"\n最近成功："+DeviceSync.MemberSuccessSummary(member));
                text.ToolTip=member.name;remove=async()=>{try{await action();}catch(Exception error){MessageBox.Show(error.Message,"同步操作未完成",MessageBoxButton.OK,MessageBoxImage.Warning);}};
                state.Text=paused&&member.self?"已暂停":member.needs_upgrade?"需要升级":member.online?(member.applied?"已同步":"等待应用"):"等待连接";
                state.ToolTip=member.needs_upgrade?"请将两端 Rime Q 升级到支持完整学习记录同步的版本；无需重新配对。":member.online&&member.applied?"已应用当前已知变更；离线设备可能还有未传出的词条。":"连接后自动同步；有组合输入时等待输入结束。";
                options.Visibility=!member.self&&canRemove?Visibility.Visible:Visibility.Collapsed;
                options.ToolTip="管理“"+member.name+"”";
            }
        }
    }
    internal sealed class SyncWizard {
        internal enum Mode {Create,Join,Invite}
        internal readonly Window Window;
        readonly Mode mode;
        readonly Func<Task> changed;
        readonly StackPanel content=new StackPanel(),pending=new StackPanel(),manualFields=new StackPanel();
        readonly TextBlock status=DeviceSyncWindow.Label(""),pairingCode=DeviceSyncWindow.Label(""),countdown=DeviceSyncWindow.Label("");
        readonly TextBox name=new TextBox {Text=Environment.MachineName,MinHeight=30},group=new TextBox {Text="我的设备",MinHeight=30};
        readonly TextBox address=new TextBox {MinHeight=30},invitation=new TextBox {MinHeight=30},code=new TextBox {MaxLength=6,MinHeight=38,FontSize=22,TextAlignment=TextAlignment.Center};
        readonly ListBox nearby=new ListBox {MinHeight=120,DisplayMemberPath="name"};
        readonly CheckBox manual=new CheckBox {Content="找不到设备？手动连接",Margin=new Thickness(0,8,0,8)};
        readonly DispatcherTimer timer=new DispatcherTimer {Interval=TimeSpan.FromSeconds(1)};
        Button primary,copyCode,copyConnection;
        SyncInvitation active;
        DateTime? expires;
        bool working,cancelling,closing,consumed;
        internal SyncWizard(Window owner,Mode mode,Func<Task> changed){
            this.mode=mode;this.changed=changed;
            Window=new Window {Title=mode==Mode.Create?"创建同步组":mode==Mode.Join?"加入同步组":"添加设备",Owner=owner,Width=560,Height=mode==Mode.Join?650:480,MinWidth=460,MinHeight=400,WindowStartupLocation=WindowStartupLocation.CenterOwner};
            SyncStyle.Apply(Window);
            var panel=new StackPanel {Margin=new Thickness(24)};Window.Content=new ScrollViewer {Content=panel,VerticalScrollBarVisibility=ScrollBarVisibility.Auto};
            var title=DeviceSyncWindow.Label(Window.Title);title.FontSize=21;title.FontWeight=FontWeights.SemiBold;panel.Children.Add(title);
            panel.Children.Add(content);panel.Children.Add(status);
            var buttons=new StackPanel {Orientation=Orientation.Horizontal,HorizontalAlignment=HorizontalAlignment.Right};panel.Children.Add(buttons);
            buttons.Children.Add(DeviceSyncWindow.Action(mode==Mode.Invite?"关闭邀请":"取消",()=>{_ = Dismiss();}));
            primary=DeviceSyncWindow.Action(mode==Mode.Create?"创建并开启":mode==Mode.Join?"加入同步组":"重新生成",()=>{_ = Submit();});
            buttons.Children.Add(primary);
            timer.Tick+=async(s,e)=>await Poll();
            Window.Loaded+=async(s,e)=>{
                if(mode==Mode.Join){try{await Discover();timer.Start();}catch(Exception error){status.Text=error.Message;}}
                if(mode==Mode.Invite){await Generate();timer.Start();}
            };
            Window.Closed+=(s,e)=>{timer.Stop();if(!closing){if(mode==Mode.Invite&&active!=null)_ = DeviceSync.Call<object>(new {action="cancel_invite"});if(mode==Mode.Join&&working)_ = DeviceSync.Call<object>(new {action="cancel_join"});}};
            if(mode==Mode.Create)Create();else if(mode==Mode.Join)Join();else Invite();
            foreach(var field in new[]{name,group,code,address,invitation})field.TextChanged+=(s,e)=>Validate();
            Validate();
        }
        static void Field(StackPanel container,string title,TextBox value){
            container.Children.Add(DeviceSyncWindow.Label(title));value.Margin=new Thickness(0,0,0,14);container.Children.Add(value);
        }
        void Create(){
            content.Children.Add(DeviceSyncWindow.Label("从这台电脑开始，再邀请其他电脑加入。"));
            Field(content,"这台电脑的名称",name);Field(content,"同步组名称",group);
            content.Children.Add(DeviceSyncWindow.Label("创建后才开启本地网络发现。拒绝网络授权仍可正常输入和学习。"));
        }
        void Join(){
            content.Children.Add(DeviceSyncWindow.Label("先在另一台电脑打开“添加设备”，选择它并输入配对码。"));
            Field(content,"这台电脑的名称",name);
            content.Children.Add(DeviceSyncWindow.Label("附近正在邀请的设备"));
            content.Children.Add(nearby);content.Children.Add(DeviceSyncWindow.Action("重新查找",()=>{_ = Discover();}));
            nearby.SelectionChanged+=(s,e)=>Validate();
            Field(content,"另一台电脑上的六位配对码",code);
            manualFields.Visibility=Visibility.Collapsed;manual.Checked+=(s,e)=>{manualFields.Visibility=Visibility.Visible;Validate();};
            manual.Unchecked+=(s,e)=>{manualFields.Visibility=Visibility.Collapsed;Validate();};
            content.Children.Add(manual);
            Field(manualFields,"连接地址",address);Field(manualFields,"邀请标识",invitation);
            manualFields.Children.Add(DeviceSyncWindow.Action("粘贴连接信息",()=>{
                try{
                    string parsedAddress,parsedInvite;
                    if(!SyncConnectionInfo.TryParse(Clipboard.GetText(),out parsedAddress,out parsedInvite)){
                        status.Text="剪贴板中没有 Rime Q 连接信息，请从原设备的邀请窗口复制。";return;
                    }
                    address.Text=parsedAddress;invitation.Text=parsedInvite;status.Text="连接信息已粘贴。";
                }
                catch(Exception error){status.Text=error.Message;}
            }));
            content.Children.Add(manualFields);
            content.Children.Add(DeviceSyncWindow.Label("加入前，原设备还需要确认；等待时可以取消。"));
            code.TextChanged+=(s,e)=>{
                var digits=new StringBuilder();
                foreach(var character in code.Text){var number=Char.GetNumericValue(character);if(number>=0&&number<=9&&number==Math.Floor(number)&&digits.Length<6)digits.Append((char)('0'+(int)number));}
                if(code.Text!=digits.ToString()){var cursor=digits.Length;code.Text=digits.ToString();code.CaretIndex=cursor;}
            };
        }
        void Invite(){
            content.Children.Add(DeviceSyncWindow.Label("保持此窗口打开，在另一台电脑加入。"));
            content.Children.Add(pending);
            pairingCode.FontSize=34;pairingCode.FontWeight=FontWeights.SemiBold;pairingCode.TextAlignment=TextAlignment.Center;content.Children.Add(pairingCode);
            countdown.TextAlignment=TextAlignment.Center;content.Children.Add(countdown);
            copyCode=DeviceSyncWindow.Action("复制配对码",()=>{
                if(active!=null&&expires>DateTime.UtcNow)try{Clipboard.SetText(active.code);status.Text="配对码已复制";}catch(Exception error){status.Text=error.Message;}
            });copyCode.HorizontalAlignment=HorizontalAlignment.Center;content.Children.Add(copyCode);
            content.Children.Add(DeviceSyncWindow.Label("1  在另一台电脑选择“加入已有同步组”\n2  选中这台电脑并输入配对码\n3  回到这里确认允许它加入"));
            copyConnection=DeviceSyncWindow.Action("复制连接信息",()=>{
                if(active==null||expires<=DateTime.UtcNow||consumed)return;
                try{
                    var addresses=Dns.GetHostAddresses(Dns.GetHostName()).Where(a=>a.AddressFamily==AddressFamily.InterNetwork&&Private(a))
                        .Select(a=>a.ToString()).Distinct().OrderBy(a=>a,StringComparer.Ordinal).ToList();
                    if(addresses.Count==0){status.Text="没有找到可用的局域网地址，请检查网络后重试。";return;}
                    if(addresses.Count==1){CopyConnection(addresses[0]);return;}
                    var menu=new ContextMenu();
                    foreach(var host in addresses){var selected=host;var item=new MenuItem {Header=host};item.Click+=(s,e)=>CopyConnection(selected);menu.Items.Add(item);}
                    menu.PlacementTarget=copyConnection;menu.IsOpen=true;
                }
                catch(Exception error){status.Text=error.Message;}
            });copyConnection.ToolTip="选择另一台电脑能连接的局域网地址";content.Children.Add(copyConnection);
        }
        void CopyConnection(string host){
            if(active==null||expires<=DateTime.UtcNow||consumed)return;
            try{Clipboard.SetText(SyncConnectionInfo.Format(host+":"+active.port,active.invite));status.Text="连接信息已复制。在另一台电脑的“手动连接”中粘贴。";}
            catch(Exception error){status.Text=error.Message;}
        }
        static bool Private(IPAddress address){
            var b=address.GetAddressBytes();
            return b.Length==4&&(b[0]==10||b[0]==172&&b[1]>=16&&b[1]<=31||b[0]==192&&b[1]==168||b[0]==169&&b[1]==254);
        }
        static bool NameValid(string value){
            return !string.IsNullOrWhiteSpace(value)&&Encoding.UTF8.GetByteCount(value)<=128&&!value.Any(char.IsControl);
        }
        void Validate(){
            if(primary==null)return;
            if(mode==Mode.Invite){primary.IsEnabled=!working;return;}
            bool ready=NameValid(name.Text);
            if(mode==Mode.Create)ready&=NameValid(group.Text);
            else ready&=code.Text.Length==6&&(manual.IsChecked==true?!string.IsNullOrWhiteSpace(address.Text)&&!string.IsNullOrWhiteSpace(invitation.Text):nearby.SelectedItem is SyncNearby);
            primary.IsEnabled=!working&&ready;
        }
        async Task Discover(){
            try{
                await DeviceSync.EnsureStarted(true);await DeviceSync.Call<SyncStatus>(new {action="discover"});status.Text="正在查找附近设备…";await Poll();
            }catch(Exception error){status.Text=error.Message;}
        }
        async Task Generate(){
            try{
                await DeviceSync.EnsureStarted(true);
                if(active!=null)await DeviceSync.Call<object>(new {action="cancel_invite"});
                active=await DeviceSync.Call<SyncInvitation>(new {action="invite"});
                consumed=false;
                expires=DateTime.UtcNow.AddSeconds(active.expires_in);pairingCode.Text=active.code;
                status.Text="邀请已开启，等待另一台电脑加入。";await Poll();
            }catch(Exception error){status.Text=error.Message;}
        }
        async Task Poll(){
            if(mode==Mode.Join){
                try{
                    var state=await DeviceSync.Call<SyncStatus>(new {action="status"});
                    var selected=nearby.SelectedItem as SyncNearby;var devices=(state.discovered??new List<SyncNearby>()).Where(d=>!string.IsNullOrEmpty(d.invite)).ToList();
                    var previous=nearby.ItemsSource as List<SyncNearby>;
                    if(previous==null||previous.Count!=devices.Count||!previous.Zip(devices,(a,b)=>a.invite==b.invite&&a.address==b.address&&a.name==b.name).All(same=>same)){
                        nearby.ItemsSource=devices;nearby.SelectedItem=devices.FirstOrDefault(d=>d.invite==selected?.invite);
                    }
                    if(devices.Count==0&&!working)status.Text="暂未找到正在邀请的设备；可以重新查找，或手动连接。";
                }catch(Exception error){status.Text=error.Message;}Validate();
            }else if(mode==Mode.Invite){
                var remaining=expires.HasValue?Math.Max(0,(int)Math.Ceiling((expires.Value-DateTime.UtcNow).TotalSeconds)):0;
                countdown.Text=remaining>0?"邀请剩余 "+remaining/60+":"+(remaining%60).ToString("00"):"邀请已过期，可重新生成。";
                if(remaining==0)pairingCode.Text="配对码已失效";
                try{
                    var state=await DeviceSync.Call<SyncStatus>(new {action="status"});pending.Children.Clear();
                    foreach(var item in state.pending??new List<SyncPending>()){
                        var target=item;var row=new StackPanel {Orientation=Orientation.Horizontal};
                        row.Children.Add(DeviceSyncWindow.Label(target.name+" 等待确认"));
                        row.Children.Add(DeviceSyncWindow.Action("确认加入",()=>{_ = Decision("approve",target.id);}));
                        row.Children.Add(DeviceSyncWindow.Action("拒绝",()=>{_ = Decision("reject",target.id);}));
                        pending.Children.Add(row);
                    }
                    if(pending.Children.Count>0)consumed=true;
                    copyCode.IsEnabled=remaining>0&&!consumed;
                    copyConnection.IsEnabled=copyCode.IsEnabled;
                    if(pending.Children.Count>0)status.Text="请确认是否允许这台电脑加入。";
                }catch(Exception error){status.Text=error.Message;}
            }
        }
        async Task Decision(string action,string id){
            try{await DeviceSync.Call<object>(new {action=action,id=id});await Poll();await changed();}
            catch(Exception error){status.Text=error.Message;}
        }
        async Task Submit(){
            if(!primary.IsEnabled)return;
            if(mode==Mode.Invite){await Generate();return;}
            working=true;Validate();
            try{
                await DeviceSync.EnsureStarted(true);
                if(mode==Mode.Create){
                    status.Text="正在创建同步组…";
                    await DeviceSync.Call<object>(new {action="create",group=group.Text.Trim(),name=name.Text.Trim()});
                }else{
                    var selected=nearby.SelectedItem as SyncNearby;
                    status.Text="等待另一台电脑确认加入，最长约两分钟…";
                    await DeviceSync.Call<object>(new {action="join",address=manual.IsChecked==true?address.Text.Trim():selected.address,
                        invite=manual.IsChecked==true?invitation.Text.Trim():selected.invite,code=code.Text,name=name.Text.Trim()});
                }
                Paths.Set("SyncStarted","1");code.Clear();await DeviceSync.Tick();await changed();closing=true;Window.Close();
            }catch(Exception error){if(!cancelling)status.Text=error.Message+" 个人词库仍保留在本机。";}
            finally{working=false;Validate();}
        }
        async Task Dismiss(){
            if(cancelling)return;cancelling=true;
            try{
                if(mode==Mode.Join&&working)await DeviceSync.Call<object>(new {action="cancel_join"});
                if(mode==Mode.Invite&&active!=null)await DeviceSync.Call<object>(new {action="cancel_invite"});
                await changed();closing=true;Window.Close();
            }catch(Exception error){status.Text=error.Message;cancelling=false;}
        }
    }
}
