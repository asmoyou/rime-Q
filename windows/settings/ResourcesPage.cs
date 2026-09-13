using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using Microsoft.Win32;

namespace RimeQ {
    internal sealed class ResourceRow {
        public string Name { get; set; }
        public string Kind { get; set; }
        public string Count { get; set; }
        public string State { get; set; }
        internal string Id;
        internal BundledDictionary Bundled;
        internal ImportedDictionary Imported;
    }

    internal sealed partial class SettingsWindow {
        void Resources() {
            resourceImport=Async("导入词库…",ImportResource);
            resourceImport.Margin=new Thickness(0);
            pageAction.Children.Add(resourceImport);

            resourceTable=new DataGrid {
                Height=300,AutoGenerateColumns=false,CanUserAddRows=false,CanUserDeleteRows=false,IsReadOnly=true,
                SelectionMode=DataGridSelectionMode.Single,SelectionUnit=DataGridSelectionUnit.FullRow,
                HeadersVisibility=DataGridHeadersVisibility.Column,GridLinesVisibility=DataGridGridLinesVisibility.Horizontal,RowHeight=34
            };
            var nameColumn=new DataGridTextColumn { Header="资源",Binding=new System.Windows.Data.Binding("Name"),Width=260 };
            resourceTable.Columns.Add(nameColumn);
            resourceTable.Columns.Add(new DataGridTextColumn { Header="类型",Binding=new System.Windows.Data.Binding("Kind"),Width=110 });
            resourceTable.Columns.Add(new DataGridTextColumn { Header="词条数 / 大小",Binding=new System.Windows.Data.Binding("Count"),Width=125 });
            resourceTable.Columns.Add(new DataGridTextColumn { Header="状态",Binding=new System.Windows.Data.Binding("State"),Width=170 });
            resourceTable.SizeChanged+=(s,e)=>nameColumn.Width=new DataGridLength(Math.Max(170,e.NewSize.Width-110-125-170-SystemParameters.VerticalScrollBarWidth-4));
            resourceTable.SelectionChanged+=(s,e)=>UpdateResourceSelection();
            page.Children.Add(resourceTable);

            resourceToggle=Async("停用",ToggleResource);
            resourceRemove=Async("移除…",RemoveResource);
            resourceBrowse=Action("查看词条…",BrowseResource);
            resourceExport=Async("导出源文件…",ExportResource);
            resourceExport.Margin=new Thickness(0);
            var actionGrid=new Grid { Margin=new Thickness(0,12,0,0) };
            actionGrid.ColumnDefinitions.Add(new ColumnDefinition());
            actionGrid.ColumnDefinitions.Add(new ColumnDefinition { Width=GridLength.Auto });
            var left=Row(resourceToggle,resourceRemove);
            var right=Row(resourceBrowse,resourceExport);
            actionGrid.Children.Add(left);
            Grid.SetColumn(right,1);
            actionGrid.Children.Add(right);
            page.Children.Add(actionGrid);

            resourceDetail=Text("选择词库查看来源、版本与使用情况。",11,"secondary");
            resourceDetail.TextWrapping=TextWrapping.Wrap;
            resourceDetail.MinHeight=44;
            resourceDetail.VerticalAlignment=VerticalAlignment.Center;
            var details=Action("详细信息…",ShowResourceDetails);
            details.Margin=new Thickness(12,0,0,0);
            var detailGrid=new Grid();
            detailGrid.ColumnDefinitions.Add(new ColumnDefinition());
            detailGrid.ColumnDefinitions.Add(new ColumnDefinition { Width=GridLength.Auto });
            detailGrid.Children.Add(resourceDetail);
            Grid.SetColumn(details,1);
            detailGrid.Children.Add(details);
            page.Children.Add(Frame(detailGrid,12));
            page.Children.Add(Text("支持独立的全拼 .dict.yaml 与 TSV 词表。变更会自动编译，当前输入结束后生效。",11,"secondary"));

            resourceProgress=new ProgressBar { Height=4,IsIndeterminate=true,Visibility=Visibility.Collapsed,Margin=new Thickness(0,2,0,8) };
            resourceProgress.SetResourceReference(ProgressBar.ForegroundProperty,"Accent");
            page.Children.Add(resourceProgress);
            var bottom=new Grid();
            bottom.ColumnDefinitions.Add(new ColumnDefinition());
            bottom.ColumnDefinitions.Add(new ColumnDefinition { Width=GridLength.Auto });
            resourceStatus=Text(resources.LoadingError??Paths.Get("DictionaryStatus","词库与个人学习记录独立保存。"),12,"secondary");
            AutomationProperties.SetName(resourceStatus,"词库资源状态");
            bottom.Children.Add(resourceStatus);
            resourceApply=Async("重新应用",ReapplyResources);
            var restore=Async("恢复内置…",RestoreResources);
            resourceApply.Margin=new Thickness(0);
            var bottomActions=Row(restore,resourceApply);
            Grid.SetColumn(bottomActions,1);
            bottom.Children.Add(bottomActions);
            page.Children.Add(bottom);
            ReloadResourceRows();
        }

        void ResourceStatus(string text) { if(resourceStatus!=null) resourceStatus.Text=text; }

        void ReloadResourceRows() {
            if(resourceTable==null) return;
            var selectedRow=resourceTable.SelectedItem as ResourceRow;
            var selectedId=selectedRow==null?null:selectedRow.Id;
            resourceRows=new List<ResourceRow>();
            foreach(var item in resources.Catalog) {
                var state=item.kind=="model"?model.Status:
                    item.kind=="support"?"随功能内置":
                    !item.optional?"基础必需":
                    resources.Configuration.disabled.Contains(item.id)?"已停用":"已启用";
                resourceRows.Add(new ResourceRow {
                    Name=item.name,Kind=item.kind=="model"?"可选模型":"内置词库",
                    Count=item.kind=="model"?(item.bytes/1000000.0).ToString("F1",CultureInfo.CurrentCulture)+" MB":item.count.ToString("N0",CultureInfo.CurrentCulture),
                    State=state,Id="builtin:"+item.id,Bundled=item
                });
            }
            foreach(var item in resources.Configuration.imported) {
                resourceRows.Add(new ResourceRow {
                    Name=item.name,Kind="第三方词库",Count=item.count.ToString("N0",CultureInfo.CurrentCulture),
                    State=item.enabled?"已启用":"已停用",Id="imported:"+item.id,Imported=item
                });
            }
            resourceTable.ItemsSource=resourceRows;
            var index=selectedId==null?-1:resourceRows.FindIndex(row=>row.Id==selectedId);
            resourceTable.SelectedIndex=index>=0?index:(resourceRows.Count>0?0:-1);
            resourceProgress.Visibility=resources.Busy?Visibility.Visible:Visibility.Collapsed;
            UpdateResourceSelection();
        }

        void RefreshResources() { if(resourceTable!=null) ReloadResourceRows(); }
        ResourceRow SelectedResource { get { return resourceTable==null?null:resourceTable.SelectedItem as ResourceRow; } }

        void UpdateResourceSelection() {
            if(resourceTable==null) return;
            var row=SelectedResource;
            var busy=resources.Busy;
            resourceImport.IsEnabled=!busy&&resources.ConfigurationReadable;
            resourceApply.IsEnabled=!busy&&resources.ConfigurationReadable;
            resourceToggle.IsEnabled=false;
            resourceRemove.IsEnabled=false;
            resourceBrowse.IsEnabled=false;
            resourceExport.IsEnabled=false;
            if(row==null) {
                resourceDetail.Text="选择词库查看来源、版本与使用情况。";
                return;
            }
            if(row.Imported!=null) {
                var item=row.Imported;
                resourceToggle.Content=item.enabled?"停用":"启用";
                resourceToggle.IsEnabled=!busy;
                resourceRemove.IsEnabled=!busy;
                resourceBrowse.IsEnabled=!busy;
                resourceExport.IsEnabled=!busy;
                resourceDetail.Text=item.source+"\n版本 "+item.version+" · "+item.originalName+"\n"+item.license;
            } else {
                var item=row.Bundled;
                var modelRow=item.kind=="model";
                resourceToggle.Content=modelRow?(Paths.Get("Grammar","0")=="1"?"停用":"启用"):
                    (resources.Configuration.disabled.Contains(item.id)?"启用":"停用");
                resourceToggle.IsEnabled=!busy&&(item.optional||(modelRow&&model.Valid&&!model.Busy));
                resourceBrowse.Content=modelRow?"管理模型…":"查看词条…";
                resourceBrowse.IsEnabled=!busy;
                var source=ResourceSource(row,false);
                resourceExport.IsEnabled=!busy&&source!=null&&File.Exists(source);
                resourceDetail.Text=item.source+"\n版本 "+item.version+" · "+item.file+"\n"+(modelRow?model.Status:item.license);
            }
        }

        string ResourceSource(ResourceRow row,bool original) {
            if(row==null) return null;
            if(row.Imported!=null) return resources.ImportedPath(row.Imported,original);
            if(row.Bundled.kind=="model") return Paths.Model;
            return Path.Combine(Paths.App,"data",row.Bundled.file.Replace('/',Path.DirectorySeparatorChar));
        }

        string ResourceMetadata(ResourceRow row) {
            if(row.Imported!=null) return "来源："+row.Imported.source+"\n版本："+row.Imported.version+"\n原文件："+row.Imported.originalName+
                "\n许可："+row.Imported.license+"\n\nSHA-256：\n"+row.Imported.sha256;
            return "来源："+row.Bundled.source+"\n版本："+row.Bundled.version+"\n文件："+row.Bundled.file+
                "\n许可："+row.Bundled.license+"\n\nSHA-256：\n"+row.Bundled.sha256;
        }

        void ShowResourceDetails() {
            var row=SelectedResource;
            if(row!=null) MessageBox.Show(Window,ResourceMetadata(row),row.Name,MessageBoxButton.OK,MessageBoxImage.Information);
        }

        async Task ApplyResources(DictionaryConfiguration config,string success) {
            Action<string> progress=text=>Window.Dispatcher.BeginInvoke(new Action(()=>ResourceStatus(text)));
            await resources.Apply(config,progress);
            ResourceStatus(success);
            ReloadResourceRows();
        }

        async Task ToggleResource() {
            var row=SelectedResource;
            if(row==null) return;
            if(row.Bundled!=null&&row.Bundled.kind=="model") {
                if(!model.Valid) return;
                var enabled=Paths.Get("Grammar","0")=="1";
                Paths.Set("Grammar",enabled?"0":"1");
                ResourceStatus("等待当前输入结束后"+(enabled?"停用":"启用")+"整句优化。");
                UpdateResourceSelection();
                return;
            }
            var config=resources.CopyConfiguration();
            if(row.Imported!=null) {
                var item=config.imported.Single(value=>value.id==row.Imported.id);
                item.enabled=!item.enabled;
            } else if(row.Bundled.optional) {
                if(config.disabled.Contains(row.Bundled.id)) config.disabled.Remove(row.Bundled.id);
                else config.disabled.Add(row.Bundled.id);
            } else return;
            await ApplyResources(config,"词库已应用，下一次输入使用新词库。");
        }

        Task ReapplyResources() {
            return ApplyResources(resources.CopyConfiguration(),"词库已重新应用，下一次输入使用新词库。");
        }

        async Task RestoreResources() {
            if(MessageBox.Show(Window,"恢复内置词库配置？\n\n重新启用全部内置词库，停用第三方词库。个人学习记录和导入文件会保留，当前配置会先备份。",
                "恢复内置词库",MessageBoxButton.YesNo,MessageBoxImage.Question,MessageBoxResult.No)!=MessageBoxResult.Yes) return;
            Action<string> progress=text=>Window.Dispatcher.BeginInvoke(new Action(()=>ResourceStatus(text)));
            await resources.Restore(progress);
            ResourceStatus("已恢复内置词库。");
            ReloadResourceRows();
        }

        async Task RemoveResource() {
            var row=SelectedResource;
            if(row==null||row.Imported==null) return;
            if(MessageBox.Show(Window,"移除“"+row.Imported.name+"”？\n\n从加载列表移除这个词库。个人学习记录会保留；原始导入文件仍保存在个人数据文件夹中。",
                "移除第三方词库",MessageBoxButton.YesNo,MessageBoxImage.Question,MessageBoxResult.No)!=MessageBoxResult.Yes) return;
            var config=resources.CopyConfiguration();
            config.imported.RemoveAll(item=>item.id==row.Imported.id);
            await ApplyResources(config,"词库已移除，原始导入文件仍保留。");
        }

        async Task ImportResource() {
            var dialog=new OpenFileDialog {
                Title="导入第三方全拼词库",
                Filter="全拼词库|*.dict.yaml;*.tsv;*.txt|Rime 词表|*.dict.yaml|TSV 文本|*.tsv;*.txt"
            };
            if(dialog.ShowDialog(Window)!=true) return;
            var draft=await Task.Run(()=>DictionaryImport.Read(dialog.FileName));
            string name,source,license;
            if(!DictionaryDialogs.ImportMetadata(Window,draft,out name,out source,out license)) return;
            var config=resources.Adding(draft,name,source,license);
            await ApplyResources(config,"词库已应用，下一次输入使用新词库。");
        }

        async Task ExportResource() {
            var row=SelectedResource;
            var source=ResourceSource(row,true);
            if(row==null||source==null||!File.Exists(source)) return;
            var name=row.Imported!=null?row.Imported.originalName:Path.GetFileName(source);
            var dialog=new SaveFileDialog { Title="导出词库源文件",FileName=name,Filter="源文件|*"+Path.GetExtension(name)+"|所有文件|*.*" };
            if(dialog.ShowDialog(Window)==true) {
                var bytes=await Task.Run(()=>File.ReadAllBytes(source));
                Paths.AtomicBytes(dialog.FileName,bytes);
                ResourceStatus("源文件已导出。");
            }
        }

        void BrowseResource() {
            var row=SelectedResource;
            if(row==null) return;
            if(row.Bundled!=null&&row.Bundled.kind=="model") { ShowPage(0);return; }
            var source=ResourceSource(row,false);
            if(source!=null&&File.Exists(source)) new DictionaryEntriesWindow(Window,source,row.Name).Show();
        }
    }

    internal sealed class DictionaryEntriesWindow {
        internal readonly Window Window;
        readonly string path;
        readonly TextBox search;
        readonly DataGrid table;
        readonly TextBlock status;
        int generation;

        sealed class PreviewRow {
            public string Text { get; set; }
            public string Code { get; set; }
            public string Weight { get; set; }
        }
        sealed class PreviewResult {
            internal List<PreviewRow> Rows;
            internal int Count;
        }

        internal DictionaryEntriesWindow(Window owner,string path,string name) {
            this.path=path;
            Window=new Window {
                Owner=owner,Title=name,Width=780,Height=550,MinWidth=620,MinHeight=420,WindowStartupLocation=WindowStartupLocation.CenterOwner,
                Background=owner.Background,FontFamily=owner.FontFamily,FontSize=owner.FontSize,Foreground=owner.Foreground
            };
            var root=new Grid { Margin=new Thickness(20) };
            root.RowDefinitions.Add(new RowDefinition { Height=GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition());
            root.RowDefinitions.Add(new RowDefinition { Height=GridLength.Auto });
            search=new TextBox { ToolTip="搜索词条或拼音",Margin=new Thickness(0,0,0,12) };
            AutomationProperties.SetName(search,"搜索词库词条");
            var searchHost=new Grid { Margin=new Thickness(0,0,0,12) };search.Margin=new Thickness(0);var placeholder=new TextBlock { Text="搜索词条或拼音",Margin=new Thickness(9,0,0,0),VerticalAlignment=VerticalAlignment.Center,IsHitTestVisible=false,Opacity=.65 };
            searchHost.Children.Add(search);searchHost.Children.Add(placeholder);root.Children.Add(searchHost);
            table=new DataGrid {
                AutoGenerateColumns=false,CanUserAddRows=false,CanUserDeleteRows=false,IsReadOnly=true,
                HeadersVisibility=DataGridHeadersVisibility.Column,GridLinesVisibility=DataGridGridLinesVisibility.Horizontal,RowHeight=32
            };
            var textColumn=new DataGridTextColumn { Header="词条",Binding=new System.Windows.Data.Binding("Text"),Width=300 };
            var codeColumn=new DataGridTextColumn { Header="拼音 / 编码",Binding=new System.Windows.Data.Binding("Code"),Width=240 };
            table.Columns.Add(textColumn);
            table.Columns.Add(codeColumn);
            table.Columns.Add(new DataGridTextColumn { Header="原始词频",Binding=new System.Windows.Data.Binding("Weight"),Width=120 });
            table.SizeChanged+=(s,e)=> {
                var available=Math.Max(340,e.NewSize.Width-120-SystemParameters.VerticalScrollBarWidth-4);
                textColumn.Width=new DataGridLength(Math.Floor(available*.55));
                codeColumn.Width=new DataGridLength(Math.Ceiling(available*.45));
            };
            Grid.SetRow(table,1);
            root.Children.Add(table);
            status=new TextBlock { Text="正在读取…",Margin=new Thickness(0,10,0,0) };
            Grid.SetRow(status,2);
            root.Children.Add(status);
            Window.Content=root;
            Action updatePlaceholder=()=>placeholder.Visibility=string.IsNullOrEmpty(search.Text)&&!search.IsKeyboardFocused?Visibility.Visible:Visibility.Collapsed;
            search.TextChanged+=(s,e)=>{updatePlaceholder();LoadRows();};search.GotKeyboardFocus+=(s,e)=>updatePlaceholder();search.LostKeyboardFocus+=(s,e)=>updatePlaceholder();updatePlaceholder();
            Window.Loaded+=(s,e)=>LoadRows();
        }

        internal void Show() { Window.Show(); }

        async void LoadRows() {
            var epoch=++generation;
            var query=(search.Text??"").ToLowerInvariant().Replace(" ","");
            status.Text="正在搜索…";
            try {
                var result=await Task.Run(()=>Read(query));
                if(epoch!=generation) return;
                table.ItemsSource=result.Rows;
                status.Text="匹配 "+result.Count.ToString("N0",CultureInfo.CurrentCulture)+" 条"+
                    (result.Count>1000?" · 显示前 1,000 条，请缩小搜索范围。":"");
            } catch(Exception error) when(error is IOException||error is UnauthorizedAccessException||error is DecoderFallbackException) {
                if(epoch==generation) status.Text=error.Message;
            }
        }

        PreviewResult Read(string query) {
            var file=new FileInfo(path);
            if(!file.Exists||file.Length>128L*1024*1024) throw new IOException("词库文件不存在或超过 128 MB。");
            var text=new UTF8Encoding(false,true).GetString(File.ReadAllBytes(path)).Replace("\r","");
            var lines=text.Split('\n');
            var yaml=path.EndsWith(".yaml",StringComparison.OrdinalIgnoreCase);
            var body=!yaml;
            var weightOnly=Path.GetFileName(path).Equals("tencent.dict.yaml",StringComparison.OrdinalIgnoreCase);
            var columns=new List<string>{"text","code","weight"};
            var rows=new List<PreviewRow>();
            var matches=0;
            foreach(var raw in lines) {
                var trimmed=raw.Trim();
                if(!body) {
                    if(trimmed.StartsWith("columns:",StringComparison.Ordinal)&&trimmed.Contains("[")&&trimmed.EndsWith("]",StringComparison.Ordinal)) {
                        var value=trimmed.Substring(trimmed.IndexOf('[')+1);
                        columns=value.Substring(0,value.Length-1).Split(',').Select(item=>item.Trim()).ToList();
                    }
                    if(trimmed=="...") body=true;
                    continue;
                }
                if(raw.Length==0||raw.StartsWith("#",StringComparison.Ordinal)) continue;
                if(query.Length>0&&!raw.ToLowerInvariant().Replace(" ","").Contains(query)) continue;
                matches++;
                if(rows.Count>=1000) continue;
                var parts=raw.Split('\t');
                if(weightOnly) rows.Add(new PreviewRow { Text=parts[0],Code="自动注音",Weight=parts.Length>1?parts[1]:"默认" });
                else {
                    var textIndex=columns.IndexOf("text");
                    var codeIndex=columns.IndexOf("code");
                    var weightIndex=columns.IndexOf("weight");
                    rows.Add(new PreviewRow {
                        Text=textIndex>=0&&textIndex<parts.Length?parts[textIndex]:parts[0],
                        Code=codeIndex>=0&&codeIndex<parts.Length?parts[codeIndex]:"自动注音",
                        Weight=weightIndex>=0&&weightIndex<parts.Length?parts[weightIndex]:"默认"
                    });
                }
            }
            return new PreviewResult { Rows=rows,Count=matches };
        }
    }
}
