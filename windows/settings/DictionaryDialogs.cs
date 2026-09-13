using System;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace RimeQ {
    internal static class DictionaryDialogs {
        static TextBlock Label(string text) { return new TextBlock { Text=text,VerticalAlignment=VerticalAlignment.Center,Margin=new Thickness(0,0,12,0) }; }
        static Button Button(string text,bool primary=false) { return new Button { Content=text,MinWidth=84,Margin=new Thickness(8,0,0,0),IsDefault=primary,IsCancel=!primary }; }
        static Window Dialog(Window owner,string title,double height) {
            var window=new Window { Owner=owner,Title=title,Width=510,Height=height,ResizeMode=ResizeMode.NoResize,WindowStartupLocation=WindowStartupLocation.CenterOwner,
                ShowInTaskbar=false,Background=owner.Background,FontFamily=owner.FontFamily,FontSize=owner.FontSize,Foreground=owner.Foreground };
            return window;
        }
        static Grid Form(params Tuple<string,TextBox>[] fields) {
            var grid=new Grid { Margin=new Thickness(0,18,0,20) }; grid.ColumnDefinitions.Add(new ColumnDefinition { Width=new GridLength(80) }); grid.ColumnDefinitions.Add(new ColumnDefinition());
            for(int i=0;i<fields.Length;++i) {
                grid.RowDefinitions.Add(new RowDefinition { Height=GridLength.Auto });
                var label=Label(fields[i].Item1); label.Margin=new Thickness(0,i==0?0:12,12,0); Grid.SetRow(label,i); grid.Children.Add(label);
                var input=fields[i].Item2; input.Margin=new Thickness(0,i==0?0:12,0,0); Grid.SetRow(input,i); Grid.SetColumn(input,1); grid.Children.Add(input);
            }
            return grid;
        }
        internal static bool Edit(Window owner,DictionaryRow original,out DictionaryRow result) {
            result=null; var window=Dialog(owner,original==null?"新增个人词条":"编辑个人词条",275);
            var text=new TextBox { Text=original==null?"":original.Text }; var code=new TextBox { Text=original==null?"":original.Code };
            var note=new TextBlock { Text="拼音按音节用空格分隔，例如 xing he ci ku。编辑会保留原来的学习权重。",TextWrapping=TextWrapping.Wrap };
            note.Foreground=owner.FindResource("SecondaryColor") as Brush;
            var cancel=Button("取消"); var save=Button("保存",true); var buttons=new StackPanel { Orientation=Orientation.Horizontal,HorizontalAlignment=HorizontalAlignment.Right };
            buttons.Children.Add(cancel); buttons.Children.Add(save);
            var panel=new StackPanel { Margin=new Thickness(24) }; panel.Children.Add(note); panel.Children.Add(Form(Tuple.Create("词条",text),Tuple.Create("全拼",code))); panel.Children.Add(buttons); window.Content=panel;
            DictionaryRow value=null;
            save.Click+=(s,e)=>{ try { value=DictionaryData.ParsePersonal(text.Text+"\t"+code.Text+"\t1\n").Single(); value.Weight=original==null?1:original.Weight; window.DialogResult=true; }
                catch(Exception error) when(error is FormatException || error is System.IO.IOException) { MessageBox.Show(window,error.Message,"未能保存",MessageBoxButton.OK,MessageBoxImage.Warning); } };
            cancel.Click+=(s,e)=>window.DialogResult=false; window.Loaded+=(s,e)=>text.Focus();
            if(window.ShowDialog()==true) { result=value; return true; } return false;
        }
        internal static bool ImportMetadata(Window owner,DictionaryImport draft,out string name,out string source,out string license) {
            name=source=license=null; var window=Dialog(owner,"导入 "+draft.Entries.Count.ToString("N0",CultureInfo.CurrentCulture)+" 条词条",340);
            var info=new TextBlock { Text="词库会作为独立资源管理，已有词条保留原词频。原始文件及其中的作者声明会一并保存。",TextWrapping=TextWrapping.Wrap };
            info.Foreground=owner.FindResource("SecondaryColor") as Brush;
            var nameBox=new TextBox { Text=draft.Name }; var sourceBox=new TextBox(); var licenseBox=new TextBox();
            var cancel=Button("取消"); var save=Button("导入并启用",true); var buttons=new StackPanel { Orientation=Orientation.Horizontal,HorizontalAlignment=HorizontalAlignment.Right };
            buttons.Children.Add(cancel); buttons.Children.Add(save);
            var panel=new StackPanel { Margin=new Thickness(24) }; panel.Children.Add(info); panel.Children.Add(Form(Tuple.Create("名称",nameBox),Tuple.Create("来源",sourceBox),Tuple.Create("许可",licenseBox))); panel.Children.Add(buttons); window.Content=panel;
            save.Click+=(s,e)=>{ if(string.IsNullOrWhiteSpace(nameBox.Text)){MessageBox.Show(window,"请输入词库名称。","未能导入",MessageBoxButton.OK,MessageBoxImage.Warning);return;} window.DialogResult=true; };
            cancel.Click+=(s,e)=>window.DialogResult=false;
            if(window.ShowDialog()==true) { name=nameBox.Text;source=sourceBox.Text;license=licenseBox.Text;return true; } return false;
        }
        internal static void ShowUpdateResult(Window owner,UpdateResult result) {
            var window=Dialog(owner,"检查更新",245);var title=new TextBlock { Text=result.Message,FontSize=17,FontWeight=FontWeights.SemiBold };
            string detail;if(result.State=="available")detail="当前版本："+Paths.Version+"。可以前往发布页面查看说明并下载。";
            else if(result.State=="current")detail="当前版本："+Paths.Version+"。";
            else if(result.State=="unpublished")detail="项目暂时没有可供检查的公开 Windows 版本。";
            else detail="请检查网络连接后重试，或打开发布页面查看。";
            var information=new TextBlock { Text=detail,TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,14,0,22) };
            var close=Button("关闭",true);var releases=Button("打开发布页面");var buttons=new StackPanel { Orientation=Orientation.Horizontal,HorizontalAlignment=HorizontalAlignment.Right };
            buttons.Children.Add(close);buttons.Children.Add(releases);var panel=new StackPanel { Margin=new Thickness(24) };panel.Children.Add(title);panel.Children.Add(information);panel.Children.Add(buttons);window.Content=panel;
            close.Click+=(s,e)=>window.Close();releases.Click+=(s,e)=>{Paths.Open(Paths.Releases);window.Close();};window.ShowDialog();
        }
    }
}
