using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using Microsoft.Win32;

namespace RimeQ {
    internal sealed partial class SettingsWindow {
        void Personal() {
            var actions = new WrapPanel(); page.Children.Add(actions);
            actions.Children.Add(Async("读取个人词库", LoadDictionary));
            actions.Children.Add(Async("导入 TSV", async () => {
                var dialog = new OpenFileDialog { Filter = "UTF-8 词表|*.tsv;*.txt", Title = "导入个人词库" };
                if (dialog.ShowDialog(Window) != true) return;
                var imported = DictionaryData.Parse(File.ReadAllText(dialog.FileName, new System.Text.UTF8Encoding(false, true)));
                await DictionaryData.Save(imported); await LoadDictionary(); Status("导入完成，学习记录已合并。");
            }));
            actions.Children.Add(Async("导出备份", async () => {
                var records = await DictionaryData.Load(); var dialog = new SaveFileDialog { Filter = "UTF-8 词表|*.tsv", FileName = "RimeQ-个人词库-" + DateTime.Now.ToString("yyyyMMdd") + ".tsv" };
                if (dialog.ShowDialog(Window) == true) { Paths.AtomicText(dialog.FileName, DictionaryData.Format(records)); Status("备份已保存。"); }
            }));
            var search = new TextBox { ToolTip = "按词语或全拼搜索" }; AutomationProperties.SetName(search, "搜索个人词库"); page.Children.Add(search);
            dictionary = new DataGrid { Height = 360, AutoGenerateColumns = false, CanUserAddRows = false, CanUserDeleteRows = false,
                SelectionMode = DataGridSelectionMode.Single, HeadersVisibility = DataGridHeadersVisibility.Column, GridLinesVisibility = DataGridGridLinesVisibility.Horizontal,
                BorderBrush = Brush("#DBE3D9"), RowHeight = 34, AlternatingRowBackground = Brush("#F7F9F6") };
            dictionary.Columns.Add(new DataGridTextColumn { Header = "词语", Binding = new Binding("Text"), Width = new DataGridLength(1, DataGridLengthUnitType.Star) });
            dictionary.Columns.Add(new DataGridTextColumn { Header = "全拼编码", Binding = new Binding("Code"), Width = new DataGridLength(1, DataGridLengthUnitType.Star) });
            dictionary.Columns.Add(new DataGridTextColumn { Header = "学习次数", Binding = new Binding("Weight"), Width = 95 });
            dictionary.SetResourceReference(DataGrid.BorderBrushProperty, "BorderColor");
            dictionary.SetResourceReference(DataGrid.AlternatingRowBackgroundProperty, "WindowBackground");
            page.Children.Add(dictionary);
            search.TextChanged += (s,e) => { if (dictionary.ItemsSource != null) CollectionViewSource.GetDefaultView(dictionary.ItemsSource).Filter = o => {
                var row = (DictionaryRow)o; return (row.Text ?? "").Contains(search.Text) || (row.Code ?? "").Contains(search.Text); }; };
            var edits = new WrapPanel { Margin = new Thickness(0,14,0,0) }; page.Children.Add(edits);
            edits.Children.Add(Action("新增", () => { if (rows == null) { Status("请先读取个人词库。"); return; } rows.Add(new DictionaryRow { Text = "新词", Code = "xin ci", Weight = 1 }); dictionary.SelectedIndex = rows.Count - 1; dictionary.ScrollIntoView(dictionary.SelectedItem); }));
            edits.Children.Add(Action("删除所选", () => { var row = dictionary.SelectedItem as DictionaryRow; if (row != null) { rows.Remove(row); Status("已标记删除，点击保存后生效；可撤销。"); } }));
            edits.Children.Add(Action("撤销编辑", () => { if (original != null) { rows = new ObservableCollection<DictionaryRow>(Clone(original)); dictionary.ItemsSource = rows; Status("已撤销未保存的编辑。"); } }));
            edits.Children.Add(Async("保存修改", async () => {
                if (saving || rows == null) return; saving = true;
                try {
                    dictionary.CommitEdit(DataGridEditingUnit.Cell, true); dictionary.CommitEdit(DataGridEditingUnit.Row, true);
                    var modified = Clone(rows);
                    var keys = new HashSet<string>(modified.Select(r => r.Text + "\t" + r.Code));
                    modified.AddRange(original.Where(r => !keys.Contains(r.Text + "\t" + r.Code)).Select(r => new DictionaryRow { Text = r.Text, Code = r.Code, Weight = -1 }));
                    await DictionaryData.Save(modified); await LoadDictionary(); Status("个人词库已保存。");
                } finally { saving = false; }
            }));
            page.Children.Add(Text("双击单元格编辑。删除个人记录后，内置词库中的同名词仍可能出现。导入格式：词语、空格分隔的全拼、次数，使用 TAB 分列。", 12, "#667F71"));
            Status("点击“读取个人词库”加载本机学习记录。操作前请结束正在输入的组合。");
        }
        static List<DictionaryRow> Clone(IEnumerable<DictionaryRow> source) { return source.Select(r => new DictionaryRow { Text = r.Text, Code = r.Code, Weight = r.Weight }).ToList(); }
        async Task LoadDictionary() {
            Status("正在读取个人词库…"); var loaded = await DictionaryData.Load();
            if (selected != 1) return;
            original = Clone(loaded); rows = new ObservableCollection<DictionaryRow>(loaded.Where(r => r.Weight >= 0)); dictionary.ItemsSource = rows; Status("已读取 " + rows.Count + " 条记录。");
        }
    }
}
