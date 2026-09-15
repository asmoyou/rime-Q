using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace RimeQ {
    internal sealed partial class SettingsWindow {
        internal readonly Window Window;
        readonly StackPanel page, pageAction, navigation, footer;
        readonly TextBlock title, subtitle, status;
        readonly ScrollViewer scroll;
        readonly Updates updates;
        readonly ModelManager model;
        readonly DictionaryResources resources;
        readonly Dictionary<int, Button> nav = new Dictionary<int, Button>();
        readonly Dictionary<int, Border> choices = new Dictionary<int, Border>();
        readonly Dictionary<int, TextBlock> checks = new Dictionary<int, TextBlock>();
        readonly List<NativePreview> previews = new List<NativePreview>();
        int selected, dictionaryLoadVersion;
        bool dark, dictionaryBusy;
        TextBlock updateStatus, updateCheckedAt, modelStatus, selectionStatus;
        ProgressBar modelProgress;
        Button download, cancel, remove, catUse;
        Border advancedCard;
        CheckBox grammar;
        ObservableCollection<DictionaryRow> rows;
        DataGrid dictionary;
        List<DictionaryRow> dictionaryAll;
        TextBox dictionarySearch;
        ComboBox dictionarySort;
        TextBlock dictionaryStatus, dictionaryEmptyTitle, dictionaryEmptyNote;
        FrameworkElement dictionaryEmpty;
        Button dictionaryEdit, dictionaryDelete, dictionaryUndo, dictionaryExport;
        DataGrid resourceTable;
        ProgressBar resourceProgress;
        TextBlock resourceDetail, resourceStatus;
        Button resourceImport, resourceToggle, resourceRemove, resourceBrowse, resourceExport, resourceApply;
        List<ResourceRow> resourceRows;
        internal Func<Task<List<DictionaryRow>>> DictionaryLoader = DictionaryData.Load;
        internal SettingsWindow(Updates updates, ModelManager model, DictionaryResources resources = null) {
            this.updates = updates; this.model = model; this.resources = resources ?? new DictionaryResources();
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Shell.xaml")) Window = (Window)XamlReader.Load(stream);
            dark = Appearance.SystemDark; Appearance.Apply(Window, dark);
            page = (StackPanel)Window.FindName("Page"); pageAction = (StackPanel)Window.FindName("PageAction"); navigation = (StackPanel)Window.FindName("Navigation"); footer = (StackPanel)Window.FindName("Footer");
            title = (TextBlock)Window.FindName("PageTitle"); subtitle = (TextBlock)Window.FindName("PageSubtitle"); status = (TextBlock)Window.FindName("Status"); scroll = (ScrollViewer)Window.FindName("PageScroll");
            var decoder = new IconBitmapDecoder(new Uri(Path.Combine(Paths.App,"RimeQ.ico")),BitmapCreateOptions.PreservePixelFormat,BitmapCacheOption.OnLoad);
            var logo = decoder.Frames.OrderByDescending(frame => frame.PixelWidth).First(); ((Image)Window.FindName("BrandIcon")).Source = logo; Window.Icon = logo;
            navigation.Children.Add(Group("偏好设置")); AddNav("输入与外观",0,"keyboard",navigation); AddNav("皮肤",4,"palette",navigation);
            var dictionaryGroup = Group("词库"); dictionaryGroup.Margin = new Thickness(0,18,0,8); navigation.Children.Add(dictionaryGroup);
            AddNav("个人词库",1,"book",navigation); AddNav("词库与模型",2,"layers",navigation);
            var divider = Separator(); divider.Margin = new Thickness(0,0,0,10); footer.Children.Add(divider);
            footer.Children.Add(Navigation("使用说明","help",() => Paths.Open(Path.Combine(Paths.App,"help","index.html"))));
            footer.Children.Add(Navigation("GitHub 项目","code",() => Paths.Open(Paths.Project))); AddNav("版本与更新",3,"update",footer);
            updates.Changed += UpdateChanged; model.Changed += ModelChanged; this.resources.Changed += ResourcesChanged; SystemEvents.UserPreferenceChanged += SystemChanged;
            Window.Closed += (s,e) => { updates.Changed -= UpdateChanged; model.Changed -= ModelChanged; this.resources.Changed -= ResourcesChanged; SystemEvents.UserPreferenceChanged -= SystemChanged; };
            ShowPage(0);
        }
        void UpdateChanged() { Window.Dispatcher.BeginInvoke(new Action(RefreshUpdate)); }
        void ModelChanged() { Window.Dispatcher.BeginInvoke(new Action(() => { RefreshModel(); RefreshResources(); })); }
        void ResourcesChanged() { Window.Dispatcher.BeginInvoke(new Action(RefreshResources)); }
        void SystemChanged(object sender, UserPreferenceChangedEventArgs args) { Window.Dispatcher.BeginInvoke(new Action(() => SetAppearance(Appearance.SystemDark))); }
        internal void SetAppearance(bool value) { dark = value; Appearance.Apply(Window,dark); foreach (var preview in previews) preview.Dark = dark; }
        Brush Brush(string color) { return new SolidColorBrush((Color)ColorConverter.ConvertFromString(color)); }
        TextBlock Text(string value, int size = 13, string color = null) {
            var label = new TextBlock { Text = value, FontSize = size, TextWrapping = TextWrapping.Wrap, LineHeight = size + 6 };
            label.SetResourceReference(TextBlock.ForegroundProperty, color == null ? "TextColor" : "SecondaryColor"); return label;
        }
        TextBlock Group(string name) { var label = Text(name,11,"secondary"); label.Margin = new Thickness(0,0,0,8); return label; }
        FrameworkElement Icon(string name) {
            var paths = new Dictionary<string,string> {
                {"keyboard","M1,4 L17,4 17,14 1,14 Z M4,7 L5,7 M8,7 L9,7 M12,7 L13,7 M4,10 L5,10 M8,10 L9,10 M12,10 L13,10 M5,12 L13,12"},
                {"palette","M9,1 C4,1 1,4 1,9 C1,14 5,17 10,17 C13,17 14,14 12,12 C11,10 14,10 15,10 C19,10 17,1 9,1 Z M5,5 L5.1,5 M10,4 L10.1,4 M14,7 L14.1,7 M5,10 L5.1,10"},
                {"book","M3,1 L15,1 15,17 3,17 Z M5,1 L5,17 M8,5 L12,5 M8,8 L12,8"},
                {"layers","M1,6 L9,2 17,6 9,10 Z M1,10 L9,14 17,10 M1,14 L9,18 17,14"},
                {"help","M9,1 A8,8 0 1 1 8.99,1 M6,6 C6,2 13,3 12,7 C12,9 9,8 9,11 M9,14 L9.1,14"},
                {"code","M5,5 L1,9 5,13 M13,5 L17,9 13,13 M11,2 L7,16"},
                {"update","M3,5 C6,-1 15,1 16,6 M13,6 L17,6 17,2 M15,13 C12,19 3,17 2,12 M5,12 L1,12 1,16"}
            };
            var path = new System.Windows.Shapes.Path { Data = Geometry.Parse(paths[name]), StrokeThickness = 1.2, StrokeStartLineCap = PenLineCap.Round,
                StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round, Stretch = Stretch.Uniform, Width = 16, Height = 16 };
            path.SetResourceReference(System.Windows.Shapes.Shape.StrokeProperty,"SecondaryColor"); return path;
        }
        Button Navigation(string label, string icon, Action action) {
            var button = Action(label,action); button.Style = (Style)Window.FindResource("NavigationButton"); button.Margin = new Thickness(0,2,0,2); button.HorizontalContentAlignment = HorizontalAlignment.Stretch;
            var row = new Grid(); row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(28) }); row.ColumnDefinitions.Add(new ColumnDefinition());
            var glyph = Icon(icon); glyph.HorizontalAlignment = HorizontalAlignment.Left; row.Children.Add(glyph);
            var text = Text(label,13); text.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(text,1); row.Children.Add(text); button.Content = row; return button;
        }
        void AddNav(string label,int id,string icon,StackPanel parent) { var button = Navigation(label,icon,() => ShowPage(id)); nav.Add(id,button); parent.Children.Add(button); }
        Button Action(string label,Action action) {
            var button = new Button { Content = label, Margin = new Thickness(0,0,8,0), HorizontalContentAlignment = HorizontalAlignment.Center };
            AutomationProperties.SetName(button,label); button.Click += (s,e) => { try { action(); } catch (Exception error) { Error(error); } }; return button;
        }
        Button Async(string label,Func<Task> action) {
            var button = new Button { Content = label, Margin = new Thickness(0,0,8,0), HorizontalContentAlignment = HorizontalAlignment.Center };
            AutomationProperties.SetName(button,label);
            button.Click += async (s,e) => { button.IsEnabled = false; try { await action(); } catch (Exception error) { Error(error); } finally { button.IsEnabled = true; RefreshModel(); } }; return button;
        }
        void Error(Exception error) { status.Text = "操作未完成：" + error.Message; status.Foreground = Brush("#B34C46"); status.Visibility = Visibility.Visible; }
        void Status(string text) { status.Text = text; status.SetResourceReference(TextBlock.ForegroundProperty,"SecondaryColor"); status.Visibility = Visibility.Visible; }
        Border Frame(UIElement child,double padding = 0) {
            var border = new Border { Child = child, CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(1), Padding = new Thickness(padding) };
            border.SetResourceReference(Border.BackgroundProperty,"CardBackground"); border.SetResourceReference(Border.BorderBrushProperty,"BorderColor"); return border;
        }
        FrameworkElement Separator() { var line = new Border { Height = 1 }; line.SetResourceReference(Border.BackgroundProperty,"BorderColor"); return line; }
        StackPanel Section(string label,UIElement content,string note = null) {
            var section = new StackPanel { Margin = new Thickness(0,0,0,22) }; var heading = Text(label,12,"secondary"); heading.FontWeight = FontWeights.Medium; heading.Margin = new Thickness(0,0,0,9);
            section.Children.Add(heading); section.Children.Add(content);
            if(note != null) { var text = Text(note,12,"secondary"); text.Margin = new Thickness(0,9,0,0); section.Children.Add(text); }
            page.Children.Add(section); return section;
        }
        StackPanel Card(string heading,string description = null) {
            var contents = new StackPanel(); if(description != null) { var text = Text(description,13,"secondary"); text.Margin = new Thickness(0,0,0,12); contents.Children.Add(text); }
            Section(heading,Frame(contents,18)); return contents;
        }
        FrameworkElement Setting(string label,FrameworkElement control,string detail = null,double height = 58) {
            var grid = new Grid { MinHeight = height, Margin = new Thickness(18,0,18,0) }; grid.ColumnDefinitions.Add(new ColumnDefinition()); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var labels = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0,14,20,14) };
            var title = Text(label,13); title.FontWeight = FontWeights.Medium; labels.Children.Add(title);
            if(detail != null) { var text = Text(detail,12,"secondary"); text.Margin = new Thickness(0,5,0,0); labels.Children.Add(text); }
            grid.Children.Add(labels); control.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(control,1); grid.Children.Add(control); return grid;
        }
        StackPanel Vertical(params UIElement[] children) { var panel = new StackPanel(); foreach(var child in children) panel.Children.Add(child); return panel; }
        WrapPanel Row(params UIElement[] children) {
            var panel = new WrapPanel { VerticalAlignment = VerticalAlignment.Center };
            for(int i=0;i<children.Length;++i) { if(children[i] is FrameworkElement element) element.Margin = new Thickness(0,0,i==children.Length-1?0:8,0); panel.Children.Add(children[i]); } return panel;
        }
        CheckBox Check(string label,string key,string fallback = "0",bool toggle = false) {
            var control = new CheckBox { Content = label, IsChecked = Paths.Get(key,fallback) == "1" };
            AutomationProperties.SetName(control,label); if(toggle) control.Style = (Style)Window.FindResource("Switch");
            control.Click += (s,e) => { try { Paths.Set(key,control.IsChecked == true?"1":"0"); Status("已保存，当前输入结束后生效。"); } catch(Exception error) { Error(error); } }; return control;
        }
        NativePreview Preview(int skin,int fontSize,double height=172,int mode=0) {
            var preview = new NativePreview { Skin = skin, CandidateSize = fontSize, Dark = dark, Height = height, Mode = mode };
            previews.Add(preview); return preview;
        }
        internal void ShowPage(int id) {
            selected = id; page.Children.Clear(); pageAction.Children.Clear(); previews.Clear(); choices.Clear(); checks.Clear();
            updateStatus = updateCheckedAt = modelStatus = selectionStatus = null; grammar = null; modelProgress = null; download = cancel = remove = catUse = null; advancedCard = null;
            resourceTable=null;resourceProgress=null;resourceDetail=resourceStatus=null;resourceImport=resourceToggle=resourceRemove=resourceBrowse=resourceExport=resourceApply=null;resourceRows=null;
            status.Visibility = Visibility.Collapsed; scroll.ScrollToTop();
            foreach(var pair in nav) {
                bool active = pair.Key == id;
                if(active) pair.Value.SetResourceReference(Button.BackgroundProperty,"SelectionBackground"); else pair.Value.Background = Brushes.Transparent;
                var content = (Grid)pair.Value.Content;
                ((System.Windows.Shapes.Path)content.Children[0]).SetResourceReference(System.Windows.Shapes.Shape.StrokeProperty,active?"Accent":"SecondaryColor");
                ((TextBlock)content.Children[1]).FontWeight = active?FontWeights.SemiBold:FontWeights.Normal;
            }
            var names = new[] { "输入与外观","个人词库","词库与模型","版本与更新","皮肤" };
            var descriptions = new[] { "按自己的习惯，调整输入与候选显示。","整理选词时积累的学习记录。","管理内置资源，添加自己的专业词表。","Rime Q · 简洁、流畅、离线的中文输入法。","选择舒服的配色，或让小伙伴陪你打字。" };
            title.Text = names[id]; subtitle.Text = descriptions[id];
            if(id == 0) InputPage(); else if(id == 1) Personal(); else if(id == 2) Resources(); else if(id == 3) Version(); else Skins();
        }
        internal void ActivateCurrent() {
            if(selected==0)RefreshModel();else if(selected==1)LoadDictionaryOnOpen();else if(selected==2)RefreshResources();else if(selected==3)RefreshUpdate();else RefreshSkins();
        }
        void InputPage() {
            grammar = Check("整句优化（万象语法模型）","Grammar",toggle:true);
            var help = Action("?",() => MessageBox.Show(Window,"开启：通过万象语法模型辅助整句组词。\n\n关闭：使用基础组词、词频与个人学习。两种状态共用词库和学习记录。","整句优化",MessageBoxButton.OK,MessageBoxImage.Information));
            help.Width = help.MinWidth = 20; help.Height = 22; help.MinHeight = 22; help.Padding = new Thickness(0); help.BorderThickness = new Thickness(0); help.Background = Brushes.Transparent;
            help.Content = Icon("help"); AutomationProperties.SetName(help,"了解整句优化");
            var controls = new Grid { Width = 96 }; var switchRow = Row(help,grammar); switchRow.HorizontalAlignment = HorizontalAlignment.Right; controls.Children.Add(switchRow);
            modelStatus = Text(model.Status,12,"secondary"); download = Async("下载并开启",model.Download); cancel = Action("取消下载",model.Cancel); remove = Action("移除模型…",() => {
                if(MessageBox.Show(Window,"移除万象模型？\n\n释放约 420.3 MB 空间，并关闭整句优化。基础输入、词库和学习记录会保留。","移除万象模型",MessageBoxButton.YesNo,MessageBoxImage.Question,MessageBoxResult.No)==MessageBoxResult.Yes) model.Remove();
            });
            var buttons = Row(download,cancel,remove);
            modelProgress = new ProgressBar { Height = 4, Minimum = 0, Maximum = 100, Margin = new Thickness(18,0,18,12) }; modelProgress.SetResourceReference(ProgressBar.ForegroundProperty,"Accent");
            var modelRow = new Grid { MinHeight = 48, Margin = new Thickness(18,0,18,0) }; modelRow.ColumnDefinitions.Add(new ColumnDefinition()); modelRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            modelStatus.VerticalAlignment = VerticalAlignment.Center; modelStatus.Margin = new Thickness(0,6,12,6); modelRow.Children.Add(modelStatus); Grid.SetColumn(buttons,1); modelRow.Children.Add(buttons);
            Section("输入",Frame(Vertical(Setting("整句优化",controls,"使用万象语法模型，辅助连续输入时的组词。",76),Separator(),modelRow,modelProgress)),"万象模型按需下载。基础组词与个人学习无需模型，也能离线使用。");
            Section("拼音纠错",Frame(Vertical(
                Setting("相邻键容错",Check("相邻键容错","AdjacentKeyCorrection","1",toggle:true),"按错相邻字母时尝试出词，例如 nihso 可找到“你好”。",82),Separator(),
                Setting("正确拼音提示",Check("正确拼音提示","CorrectionHints","1",toggle:true),"纠错候选显示“中国（zhong guo）”等注释，注释不会上屏。",82))),
                "完全离线。更改在当前组合输入结束后生效。相邻键容错会增加计算量；关闭后仍保留 zhogn → zhong 等基础拼写规则。正常简拼和补全不标为手误。");
            var font = new ComboBox { Width = 96, ItemsSource = new[] {16,18,20,22}, SelectedItem = Appearance.FontSize }; AutomationProperties.SetName(font,"候选字号");
            var skin = Action(Appearance.Names[Appearance.Skin]+"  ›",() => ShowPage(4)); skin.Width = 96; skin.Margin = new Thickness(0); AutomationProperties.SetName(skin,"选择候选皮肤");
            var rows = Frame(Vertical(Setting("候选字号",font),Separator(),Setting("候选皮肤",skin)));
            var preview = Preview(Appearance.Skin,Appearance.FontSize,PreviewHeight(Appearance.Skin,Appearance.FontSize)); preview.Margin = new Thickness(0,12,0,0);
            font.SelectionChanged += (s,e) => { if(font.SelectedItem != null) { Paths.Set("FontSize",font.SelectedItem.ToString()); preview.CandidateSize = (int)font.SelectedItem; preview.Height = PreviewHeight(preview.Skin,preview.CandidateSize); } };
            Section("候选显示",Vertical(rows,preview));
            var shortcuts = new UniformGrid { Columns = 4 };
            string[] keys = {"Shift / Ctrl+Space","Caps Lock","数字键","− / ="}, details = {"中英文切换","锁定大写","选择候选","候选翻页"};
            for(int i=0;i<4;++i) { var key = Text(keys[i],12); key.FontFamily = new FontFamily("Consolas"); key.FontWeight = FontWeights.Medium; var detail = Text(details[i],12,"secondary"); detail.Margin = new Thickness(0,8,0,0); var card = Frame(Vertical(key,detail),16); card.Margin = new Thickness(0,0,i<3?12:0,0); shortcuts.Children.Add(card); }
            Section("常用按键",shortcuts);
            Section("快捷输入",Frame(Text("rq 日期 · sj 时间 · xq 星期 · nl 农历\ncC1+2 计算器 · R123.45 金额大写 · U62fc Unicode\nuuid 随机标识 · [ / ] 取候选首字 / 尾字",12,"secondary"),16),"中文模式下输入，空格或数字键选取结果。完整用法见“使用说明”。");
            RefreshModel();
        }
        static double PreviewHeight(int skin,int size) { return Math.Max(172,2*(size+16)+16+(skin==6?57:0)+42); }
        void Skins() {
            selectionStatus = Text("",12,"secondary"); selectionStatus.Margin = new Thickness(0,0,0,22); page.Children.Add(selectionStatus);
            var grid = new Grid(); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(212) }); grid.ColumnDefinitions.Add(new ColumnDefinition());
            var preview = Preview(6,Appearance.FontSize,Math.Max(190,PreviewHeight(6,Appearance.FontSize))); preview.Width = 196; preview.Margin = new Thickness(16,16,0,16); grid.Children.Add(preview);
            var labels = new StackPanel { Margin = new Thickness(20,16,20,16), VerticalAlignment = VerticalAlignment.Center }; Grid.SetColumn(labels,1); grid.Children.Add(labels);
            labels.Children.Add(Text("动态陪伴",11,"secondary")); var name = Text("敲敲猫",19); name.FontWeight = FontWeights.SemiBold; name.Margin = new Thickness(0,12,0,12); labels.Children.Add(name);
            labels.Children.Add(Text("小猫趴在候选栏外，陪你一起敲键盘。\n候选内容保持紧凑，停笔后小猫也休息。",12,"secondary"));
            catUse = Action("使用敲敲猫",() => ChooseSkin(6)); var actions = Row(Action("试敲一下",preview.Tap),catUse); actions.Margin = new Thickness(0,12,0,0); labels.Children.Add(actions);
            advancedCard = Frame(grid); Section("高级皮肤",advancedCard);
            var tiles = new SkinGrid();
            for(int i=0;i<6;++i) {
                int skin = i; var content = new Grid(); content.RowDefinitions.Add(new RowDefinition { Height = new GridLength(92) }); content.RowDefinitions.Add(new RowDefinition());
                var sample = Preview(skin,12,80,1); sample.Margin = new Thickness(12,10,12,2); content.Children.Add(sample);
                var title = Text(Appearance.Names[skin],13); title.FontWeight = FontWeights.Medium; title.Margin = new Thickness(16,8,40,0); Grid.SetRow(title,1); content.Children.Add(title);
                var check = new TextBlock { Text = "✓", Foreground = Brushes.White, FontSize = 12, FontWeight = FontWeights.SemiBold, TextAlignment = TextAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
                var circle = new Border { Width = 17, Height = 17, CornerRadius = new CornerRadius(9), Child = check, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0,0,16,0), VerticalAlignment = VerticalAlignment.Center }; circle.SetResourceReference(Border.BackgroundProperty,"Accent"); Grid.SetRow(circle,1); content.Children.Add(circle); checks[skin] = check;
                var frame = Frame(content); choices[skin] = frame;
                var button = Action(Appearance.Names[skin],() => ChooseSkin(skin)); button.Style = (Style)Window.FindResource("SkinChoice"); button.Padding = new Thickness(0); button.BorderThickness = new Thickness(0); button.Margin = new Thickness(0); button.HorizontalAlignment = HorizontalAlignment.Stretch; button.HorizontalContentAlignment = HorizontalAlignment.Stretch; button.Content = frame;
                tiles.Children.Add(button);
            }
            Section("简洁皮肤",tiles); RefreshSkins();
        }
        internal void ChooseSkin(int skin) { Appearance.Select(skin); RefreshSkins(); }
        void RefreshSkins() {
            int active = Appearance.Skin;
            if(selectionStatus != null) selectionStatus.Text = Appearance.Names[active]+" · "+Appearance.Summaries[active]+"。选择即保存，下一次输入时生效。";
            foreach(var item in choices) { item.Value.SetResourceReference(Border.BorderBrushProperty,item.Key==active?"Accent":"BorderColor"); item.Value.BorderThickness = new Thickness(item.Key==active?2:1); ((FrameworkElement)checks[item.Key].Parent).Visibility = item.Key==active?Visibility.Visible:Visibility.Collapsed; }
            if(advancedCard != null) { advancedCard.SetResourceReference(Border.BorderBrushProperty,active==6?"Accent":"BorderColor"); advancedCard.BorderThickness = new Thickness(active==6?2:1); }
            if(catUse != null) { catUse.Content = active==6?"正在使用":"使用敲敲猫"; catUse.IsEnabled = active!=6; }
        }
        void RefreshModel() {
            if(modelStatus != null) modelStatus.Text = model.Status;
            if(modelProgress != null) { modelProgress.Value = model.Progress; modelProgress.Visibility = model.Busy?Visibility.Visible:Visibility.Collapsed; }
            if(download != null) { download.Visibility = !model.Busy&&!model.Valid&&!File.Exists(Paths.Model)?Visibility.Visible:Visibility.Collapsed; download.IsEnabled = !model.Busy; }
            if(cancel != null) cancel.Visibility = model.Busy?Visibility.Visible:Visibility.Collapsed;
            if(remove != null) { remove.Visibility = File.Exists(Paths.Model) && !model.Busy?Visibility.Visible:Visibility.Collapsed; remove.IsEnabled = !model.Busy; }
            if(grammar != null) { grammar.IsEnabled = model.Valid && !model.Busy; grammar.IsChecked = Paths.Get("Grammar")=="1"; }
        }
        void Version() {
            var check=Async("检查更新…",async()=>{updateStatus.Text="正在查询发布信息…";await updates.Check(true);RefreshUpdate();DictionaryDialogs.ShowUpdateResult(Window,updates.Result);});check.Width=120;check.Margin=new Thickness(0);
            Section("当前版本",Frame(Setting("Rime Q "+Paths.Version,check,"Windows x64 · 构建 "+Paths.Build,80)));
            var controls=new CheckBox { IsChecked=Paths.Get("AutoUpdate","1")=="1",Style=(Style)Window.FindResource("Switch") };AutomationProperties.SetName(controls,"每天自动检查更新");
            controls.Click+=(s,e)=>{try{Paths.Set("AutoUpdate",controls.IsChecked==true?"1":"0");RefreshUpdate();}catch(Exception error){Error(error);}};
            updateStatus=Text("",13);updateCheckedAt=Text("",12,"secondary");var updateInfo=Vertical(updateStatus,updateCheckedAt);updateInfo.Margin=new Thickness(0,12,0,0);
            Section("软件更新",Vertical(Frame(Setting("自动检查更新",controls,"每天一次，只查询 GitHub 发布信息。",76)),updateInfo),"发现新版会在输入法菜单和此处提示。下载与安装由你决定。");
            var project=Action("打开 GitHub",()=>Paths.Open(Paths.Project));project.Width=120;project.Margin=new Thickness(0);
            var releases=Action("查看发布记录",()=>Paths.Open(Paths.Releases));releases.Width=120;releases.Margin=new Thickness(0);
            Section("项目",Frame(Vertical(Setting("GitHub 项目",project,"asmoyou / rime-Q · 源码、文档与问题反馈",76),Separator(),Setting("发布记录",releases,"查看版本变化，下载安装包。",76))));
            page.Children.Add(Text("日常输入与学习都在本机完成。更新检查不发送输入内容或个人词库。",12,"secondary"));RefreshUpdate();
        }
        void RefreshUpdate() {
            if(updateStatus==null)return;updateStatus.Text=updates.Result.Message;
            if(updates.Result.State=="available")updateStatus.SetResourceReference(TextBlock.ForegroundProperty,"Accent");else updateStatus.SetResourceReference(TextBlock.ForegroundProperty,"TextColor");
            DateTime last;if(DateTime.TryParse(Paths.Get("LastUpdateAttempt"),CultureInfo.InvariantCulture,DateTimeStyles.RoundtripKind,out last))updateCheckedAt.Text="上次检查："+last.ToLocalTime().ToString("g",CultureInfo.CurrentCulture);
            else updateCheckedAt.Text=Paths.Get("AutoUpdate","1")=="1"?"启用输入法后将在后台检查。":"自动检查已关闭，可随时手动检查。";
        }
    }
    internal sealed class SkinGrid : Panel {
        protected override Size MeasureOverride(Size available) {
            int columns = available.Width >= 660?3:2; double width = Math.Max(1,(available.Width-(columns-1)*12)/columns);
            foreach(UIElement child in Children) child.Measure(new Size(width,132)); int rows = (Children.Count+columns-1)/columns;
            return new Size(available.Width,rows*132+Math.Max(0,rows-1)*12);
        }
        protected override Size ArrangeOverride(Size size) {
            int columns = size.Width >= 660?3:2; double width = Math.Max(1,(size.Width-(columns-1)*12)/columns);
            for(int i=0;i<Children.Count;++i) Children[i].Arrange(new Rect((i%columns)*(width+12),(i/columns)*144,width,132)); return size;
        }
    }
}
