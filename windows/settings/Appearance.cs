using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;

namespace RimeQ {
    internal static class Appearance {
        internal static readonly string[] Names = { "随系统", "纸白", "雾蓝", "青玉", "浅樱", "暮色", "敲敲猫" };
        internal static readonly string[] Summaries = { "原生材质，随深浅模式变化", "温润纸色，安静清晰", "清浅蓝调，轻盈柔和", "淡绿底色，自然舒适", "暖粉与陶色，柔和明亮", "深色背景，低光环境更舒适", "小猫趴在栏边，陪你一起敲键盘" };
        internal static int Skin { get { int id; return Paths.Get("Cat", "0") == "1" ? 6 : int.TryParse(Paths.Get("Theme", "0"), out id) && id >= 0 && id < 6 ? id : 0; } }
        internal static int FontSize { get { int size; return int.TryParse(Paths.Get("FontSize", "18"), out size) && (size == 16 || size == 18 || size == 20 || size == 22) ? size : 18; } }
        internal static void Select(int skin) { if (skin < 0 || skin > 6) throw new ArgumentOutOfRangeException("skin"); if (skin < 6) Paths.Set("Theme", skin.ToString()); Paths.Set("Cat", skin == 6 ? "1" : "0"); }
        internal static bool SystemDark {
            get { using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")) return key != null && Convert.ToInt32(key.GetValue("AppsUseLightTheme", 1)) == 0; }
        }
        internal static void Apply(Window window, bool dark) {
            var resources = window.Resources;
            string[] names = { "WindowBackground", "CardBackground", "SidebarBackground", "BorderColor", "TextColor", "SecondaryColor", "SelectionBackground", "HoverBackground", "Accent", "ControlBackground" };
            string[] light = { "#F6F7F9", "#FFFFFF", "#ECEEF2", "#E1E4E9", "#202124", "#77797F", "#D3E2F8", "#E5EBF5", "#007AFF", "#FFFFFF" };
            string[] night = { "#202226", "#2A2D32", "#27292E", "#3C3F46", "#F2F2F7", "#A5A8B0", "#30415B", "#343943", "#4B9BFF", "#34373E" };
            for (int i = 0; i < names.Length; ++i) resources[names[i]] = new SolidColorBrush((Color)ColorConverter.ConvertFromString((dark ? night : light)[i]));
            if (SystemParameters.HighContrast) {
                resources["WindowBackground"] = resources["CardBackground"] = resources["ControlBackground"] = SystemColors.WindowBrush;
                resources["TextColor"] = resources["SecondaryColor"] = SystemColors.WindowTextBrush;
                resources["SidebarBackground"] = SystemColors.ControlBrush; resources["BorderColor"] = SystemColors.WindowTextBrush;
            }
            window.SetResourceReference(Window.BackgroundProperty, "WindowBackground"); window.SetResourceReference(Window.ForegroundProperty, "TextColor");
        }
    }
    internal sealed class NativePreview : FrameworkElement {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr LoadLibraryEx(string name, IntPtr file, uint flags);
        [DllImport("RimeQ.Visuals.dll", CallingConvention = CallingConvention.Cdecl)]
        static extern int RimeQRenderPreview(int skin, int size, int pose, int dark, int width, int height, double scale, int mode, IntPtr pixels, int stride);
        static IntPtr library;
        WriteableBitmap bitmap;
        bool dirty = true;
        int skin, size = 18, pose, previousPaw = 2;
        bool dark;
        readonly DispatcherTimer reset = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(160) };
        internal int Mode { get; set; }
        internal int Skin { get { return skin; } set { skin = value; Changed(); } }
        internal int CandidateSize { get { return size; } set { size = value; Changed(); } }
        internal bool Dark { get { return dark; } set { dark = value; Changed(); } }
        internal int Pose { get { return pose; } set { pose = value; Changed(); } }
        internal bool Animating { get { return reset.IsEnabled; } }
        internal NativePreview() {
            if (library == IntPtr.Zero) {
                library = LoadLibraryEx(Path.Combine(Paths.App, "RimeQ.Visuals.dll"), IntPtr.Zero, 0x100 | 0x800);
                if (library == IntPtr.Zero) throw new IOException("候选预览组件未能加载，请修复安装。");
            }
            reset.Tick += (s,e) => { reset.Stop(); Pose = 0; };
            Unloaded += (s,e) => { reset.Stop(); Pose = 0; };
            IsVisibleChanged += (s,e) => { if (!IsVisible) { reset.Stop(); Pose = 0; } };
        }
        void Changed() { dirty = true; InvalidateVisual(); }
        internal void Tap() { reset.Stop(); if (!SystemParameters.ClientAreaAnimation || !IsVisible) { Pose = 0; return; } previousPaw = previousPaw == 1 ? 2 : 1; Pose = previousPaw; reset.Start(); }
        protected override void OnRender(DrawingContext context) {
            base.OnRender(context); var dpi = VisualTreeHelper.GetDpi(this); double scale = dpi.DpiScaleX;
            int width = (int)Math.Ceiling(ActualWidth * scale), height = (int)Math.Ceiling(ActualHeight * scale);
            if (width <= 0 || height <= 0 || width > 4096 || height > 4096) return;
            if (bitmap == null || bitmap.PixelWidth != width || bitmap.PixelHeight != height) { bitmap = new WriteableBitmap(width, height, 96 * scale, 96 * scale, PixelFormats.Pbgra32, null); dirty = true; }
            if (dirty) {
                bitmap.Lock();
                try {
                    if (RimeQRenderPreview(skin,size,pose,dark?1:0,width,height,scale,Mode,bitmap.BackBuffer,bitmap.BackBufferStride) != 1) throw new IOException("候选预览绘制失败。");
                    bitmap.AddDirtyRect(new Int32Rect(0,0,width,height)); dirty = false;
                } finally { bitmap.Unlock(); }
            }
            context.DrawImage(bitmap,new Rect(0,0,ActualWidth,ActualHeight));
        }
    }
}
