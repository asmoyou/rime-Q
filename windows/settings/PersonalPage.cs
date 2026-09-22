using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;

namespace RimeQ {
    internal sealed partial class SettingsWindow {
        void Personal() {
            var tools=new Grid { Margin=new Thickness(0,0,0,12) };
            tools.ColumnDefinitions.Add(new ColumnDefinition());
            for(int i=0;i<3;i++)tools.ColumnDefinitions.Add(new ColumnDefinition { Width=GridLength.Auto });
            AutomationProperties.SetName(tools,"个人词库工具栏");
            dictionarySearch=new TextBox { ToolTip="搜索词条或拼音",MinWidth=160 };
            AutomationProperties.SetName(dictionarySearch,"搜索个人学习记录");
            dictionarySort=new ComboBox { Width=132,ItemsSource=new[]{"按学习权重","按词条","按拼音"},SelectedIndex=0,Margin=new Thickness(0,0,8,0) };
            var refresh=Async("刷新",LoadDictionary);
            var add=Async("新增…",()=>EditDictionary(null));add.Margin=new Thickness(0);pageAction.Children.Add(add);
            var sync=Action("附近设备同步…",ShowDeviceSync);sync.Margin=new Thickness(0);
            var search=SearchField(dictionarySearch,"搜索词条或拼音");
            foreach(var control in new FrameworkElement[]{search,dictionarySort,refresh,sync})control.VerticalAlignment=VerticalAlignment.Center;
            tools.Children.Add(search);
            Grid.SetColumn(dictionarySort,1);tools.Children.Add(dictionarySort);
            Grid.SetColumn(refresh,2);tools.Children.Add(refresh);
            Grid.SetColumn(sync,3);tools.Children.Add(sync);page.Children.Add(tools);

            dictionary=new DataGrid { Height=390,AutoGenerateColumns=false,CanUserAddRows=false,CanUserDeleteRows=false,IsReadOnly=true,
                SelectionMode=DataGridSelectionMode.Extended,SelectionUnit=DataGridSelectionUnit.FullRow,HeadersVisibility=DataGridHeadersVisibility.Column,
                GridLinesVisibility=DataGridGridLinesVisibility.Horizontal,BorderBrush=Brush("#DBE3D9"),RowHeight=34,AlternatingRowBackground=Brush("#F7F9F6") };
            var textColumn=new DataGridTextColumn { Header="词条",Binding=new System.Windows.Data.Binding("Text"),Width=240 };
            var codeColumn=new DataGridTextColumn { Header="全拼",Binding=new System.Windows.Data.Binding("Code"),Width=320 };
            var weightHeader=new TextBlock { Text="学习权重",ToolTip="用于排序的参考值，包含导入权重，不等于实际输入次数。" };
            dictionary.Columns.Add(textColumn);dictionary.Columns.Add(codeColumn);dictionary.Columns.Add(new DataGridTextColumn { Header=weightHeader,Binding=new System.Windows.Data.Binding("Weight"),Width=95 });
            dictionary.SizeChanged+=(s,e)=>{ var available=Math.Max(360,e.NewSize.Width-95-SystemParameters.VerticalScrollBarWidth-4);
                textColumn.Width=new DataGridLength(Math.Floor(available*.44)); codeColumn.Width=new DataGridLength(Math.Ceiling(available*.56)); };
            dictionary.SetResourceReference(DataGrid.BorderBrushProperty,"BorderColor");dictionary.SetResourceReference(DataGrid.AlternatingRowBackgroundProperty,"WindowBackground");
            dictionary.SelectionChanged+=(s,e)=>UpdateDictionaryActions(); dictionary.MouseDoubleClick+=async (s,e)=>{ if(dictionary.SelectedItems.Count==1) try { await EditDictionary((DictionaryRow)dictionary.SelectedItem); } catch(Exception error) { Error(error); } };
            dictionaryEmptyTitle=Text("还没有学习记录",15);dictionaryEmptyTitle.FontWeight=FontWeights.Medium;dictionaryEmptyTitle.TextAlignment=TextAlignment.Center;
            dictionaryEmptyNote=Text("日常选词后会逐渐积累，也可以手动新增。",12,"secondary");dictionaryEmptyNote.TextAlignment=TextAlignment.Center;
            dictionaryEmpty=Vertical(dictionaryEmptyTitle,dictionaryEmptyNote);dictionaryEmpty.HorizontalAlignment=HorizontalAlignment.Center;dictionaryEmpty.VerticalAlignment=VerticalAlignment.Center;dictionaryEmpty.IsHitTestVisible=false;
            var table=new Grid();table.Children.Add(dictionary);table.Children.Add(dictionaryEmpty);page.Children.Add(table);

            dictionaryEdit=Async("编辑…",()=>EditDictionary(dictionary.SelectedItem as DictionaryRow));
            dictionaryDelete=Async("删除…",DeleteDictionary);dictionaryUndo=Async("撤销上次修改",UndoDictionary);dictionaryExport=Async("导出…",ExportDictionary);
            var import=Async("导入…",ImportDictionary);dictionaryExport.Margin=new Thickness(0);
            var actionGrid=new Grid { Margin=new Thickness(0,12,0,0) };actionGrid.ColumnDefinitions.Add(new ColumnDefinition());actionGrid.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});
            var editActions=Row(dictionaryEdit,dictionaryDelete,dictionaryUndo); var fileActions=Row(import,dictionaryExport);actionGrid.Children.Add(editActions);Grid.SetColumn(fileActions,1);actionGrid.Children.Add(fileActions);page.Children.Add(actionGrid);
            page.Children.Add(Text("学习权重不等于输入次数。删除仅移除个人记录，内置同名词仍可能出现。",11,"secondary"));
            var bottom=new Grid { Margin=new Thickness(0,8,0,0) };bottom.ColumnDefinitions.Add(new ColumnDefinition());bottom.ColumnDefinitions.Add(new ColumnDefinition{Width=GridLength.Auto});
            dictionaryStatus=Text("正在读取…",12,"secondary");AutomationProperties.SetName(dictionaryStatus,"个人词库状态");bottom.Children.Add(dictionaryStatus);
            var backup=Action("查看备份",ShowDictionaryBackup);backup.Margin=new Thickness(0);Grid.SetColumn(backup,1);bottom.Children.Add(backup);page.Children.Add(bottom);
            dictionarySearch.TextChanged+=(s,e)=>FilterDictionary();dictionarySort.SelectionChanged+=(s,e)=>FilterDictionary();
            UpdateDictionaryActions();LoadDictionaryOnOpen();
        }
        static List<DictionaryRow> Clone(IEnumerable<DictionaryRow> source) { return source.Select(row=>row.Copy()).ToList(); }
        FrameworkElement SearchField(TextBox input,string placeholderText) {
            var host=new Grid { Margin=new Thickness(0,0,10,0) };var placeholder=Text(placeholderText,12,"secondary");placeholder.Margin=new Thickness(9,0,0,0);placeholder.VerticalAlignment=VerticalAlignment.Center;placeholder.IsHitTestVisible=false;
            host.Children.Add(input);host.Children.Add(placeholder);Action update=()=>placeholder.Visibility=string.IsNullOrEmpty(input.Text)&&!input.IsKeyboardFocused?Visibility.Visible:Visibility.Collapsed;
            input.TextChanged+=(s,e)=>update();input.GotKeyboardFocus+=(s,e)=>update();input.LostKeyboardFocus+=(s,e)=>update();update();return host;
        }
        void DictionaryStatus(string text) { if(dictionaryStatus!=null) dictionaryStatus.Text=text; }
        async void LoadDictionaryOnOpen() { try { await LoadDictionary(); } catch(Exception error) { if(!closed&&selected==1) Error(error); } }
        async Task LoadDictionary() {
            var target=dictionary;int version=++dictionaryLoadVersion;dictionaryBusy=true;DictionaryStatus("正在读取…");UpdateDictionaryActions();
            try { var loaded=await DictionaryLoader();if(selected!=1||dictionary!=target||dictionaryLoadVersion!=version)return;SetDictionaryRows(loaded); }
            finally { if(selected==1&&dictionary==target&&dictionaryLoadVersion==version){dictionaryBusy=false;UpdateDictionaryActions();} }
        }
        void SetDictionaryRows(IEnumerable<DictionaryRow> loaded) { dictionaryAll=Clone(loaded.Where(row=>row.Weight>=0));FilterDictionary(); }
        void FilterDictionary() {
            if(dictionary==null||dictionaryAll==null)return;
            var query=(dictionarySearch.Text??"").Trim().ToLowerInvariant();var codeQuery=query.Replace(" ","").Replace("'","");IEnumerable<DictionaryRow> filtered=dictionaryAll.Where(row=>query.Length==0||
                (row.Text??"").IndexOf(query,StringComparison.CurrentCultureIgnoreCase)>=0||(row.Code??"").Replace(" ","").ToLowerInvariant().Contains(codeQuery));
            if(dictionarySort.SelectedIndex==0)filtered=filtered.OrderByDescending(row=>row.Weight).ThenBy(row=>row.Text,StringComparer.CurrentCulture);
            else if(dictionarySort.SelectedIndex==2)filtered=filtered.OrderBy(row=>row.Code,StringComparer.Ordinal).ThenBy(row=>row.Text,StringComparer.CurrentCulture);
            else filtered=filtered.OrderBy(row=>row.Text,StringComparer.CurrentCulture).ThenBy(row=>row.Code,StringComparer.Ordinal);
            rows=new ObservableCollection<DictionaryRow>(filtered);dictionary.ItemsSource=rows;
            dictionaryEmpty.Visibility=rows.Count==0?Visibility.Visible:Visibility.Collapsed;
            dictionaryEmptyTitle.Text=dictionaryAll.Count==0?"还没有学习记录":"没有匹配的词条";
            dictionaryEmptyNote.Text=dictionaryAll.Count==0?"日常选词后会逐渐积累，也可以手动新增。":"换个词语或拼音试试。";
            DictionaryStatus(dictionaryAll.Count==0?"还没有个人学习记录。打字选词后可点击刷新，也可以手动新增。":"共 "+dictionaryAll.Count.ToString("N0",CultureInfo.CurrentCulture)+" 条 · 当前显示 "+rows.Count.ToString("N0",CultureInfo.CurrentCulture)+" 条");UpdateDictionaryActions();
        }
        void UpdateDictionaryActions() {
            var count=dictionary==null?0:dictionary.SelectedItems.Count;
            if(dictionaryEdit!=null)dictionaryEdit.IsEnabled=!dictionaryBusy&&dictionaryAll!=null&&count==1;
            if(dictionaryDelete!=null)dictionaryDelete.IsEnabled=!dictionaryBusy&&dictionaryAll!=null&&count>0;
            if(dictionaryUndo!=null)dictionaryUndo.IsEnabled=!dictionaryBusy&&DictionaryData.LastChange!=null;
            if(dictionaryExport!=null)dictionaryExport.IsEnabled=!dictionaryBusy&&dictionaryAll!=null&&dictionaryAll.Count>0;
        }
        async Task ChangeDictionary(string pending,Func<Task<List<DictionaryRow>>> operation) {
            dictionaryBusy=true;DictionaryStatus(pending);UpdateDictionaryActions();
            try { var loaded=await operation();if(!closed&&selected==1)SetDictionaryRows(loaded); }
            finally { dictionaryBusy=false;if(selected==1)UpdateDictionaryActions(); }
        }
        async Task EditDictionary(DictionaryRow entry) {
            DictionaryRow draft;if(!DictionaryDialogs.Edit(Window,entry,out draft))return;
            await ChangeDictionary(entry==null?"正在新增个人词条…":"正在保存个人词条…",()=>DictionaryData.Save(draft,entry));
        }
        async Task DeleteDictionary() {
            var selectedRows=dictionary.SelectedItems.Cast<DictionaryRow>().ToList();if(selectedRows.Count==0)return;
            if(MessageBox.Show(Window,"删除 "+selectedRows.Count.ToString("N0",CultureInfo.CurrentCulture)+" 条个人学习记录？\n\n修改前会自动保存备份，也可以撤销本次删除。","删除个人记录",MessageBoxButton.YesNo,MessageBoxImage.Warning,MessageBoxResult.No)!=MessageBoxResult.Yes)return;
            await ChangeDictionary("正在删除个人记录…",()=>DictionaryData.Delete(selectedRows));
        }
        async Task UndoDictionary() { await ChangeDictionary("正在撤销上次修改…",DictionaryData.Undo); }
        async Task ImportDictionary() {
            var dialog=new OpenFileDialog { Filter="UTF-8 词表|*.tsv;*.txt",Title="导入个人学习词库" };if(dialog.ShowDialog(Window)!=true)return;
            var imported=await Task.Run(()=>DictionaryData.ReadPersonal(dialog.FileName));
            if(MessageBox.Show(Window,"导入 "+imported.Count.ToString("N0",CultureInfo.CurrentCulture)+" 条个人记录？\n\n与现有记录合并；同词同拼音保留较高学习权重。修改前自动备份。","导入个人词库",MessageBoxButton.YesNo,MessageBoxImage.Question,MessageBoxResult.No)!=MessageBoxResult.Yes)return;
            await ChangeDictionary("正在合并个人词库…",()=>DictionaryData.Merge(imported));
        }
        async Task ExportDictionary() {
            var records=await DictionaryData.Load();var dialog=new SaveFileDialog { Filter="UTF-8 词表|*.tsv",FileName="RimeQ-个人词库.tsv",Title="导出全部个人学习记录" };
            if(dialog.ShowDialog(Window)==true){Paths.AtomicText(dialog.FileName,DictionaryData.Format(records));DictionaryStatus("已导出 "+records.Count.ToString("N0",CultureInfo.CurrentCulture)+" 条个人记录。");}
        }
        void ShowDictionaryBackup() { Directory.CreateDirectory(DictionaryData.BackupDirectory);Paths.Open(DictionaryData.BackupDirectory); }
    }
}
