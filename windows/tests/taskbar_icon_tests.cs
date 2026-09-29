using System;
using System.Drawing;
using System.IO;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace RimeQ {
    internal static class TaskbarIconTests {
        [DllImport("user32.dll")] static extern int GetGuiResources(IntPtr process, int flag);
        static void Require(bool value, string message) { if (!value) throw new Exception(message); }
        static void Pixels(Icon icon, Color ink, bool premultiplied=true) {
            using (var bitmap = icon.ToBitmap()) {
                int solid = 0, clear = 0;
                for (int y=0;y<bitmap.Height;++y) for (int x=0;x<bitmap.Width;++x) {
                    var pixel=bitmap.GetPixel(x,y);
                    if(pixel.A<=3) ++clear;
                    if(pixel.A==255) ++solid;
                    if(pixel.A>0) {
                        // HICON bitmaps expose premultiplied channels at antialiased edges.
                        int alpha=premultiplied?pixel.A:255;
                        Require(Math.Abs(pixel.R-ink.R*alpha/255)<=1 && Math.Abs(pixel.G-ink.G*alpha/255)<=1 && Math.Abs(pixel.B-ink.B*alpha/255)<=1,
                            "Solid glyph pixels do not match taskbar text colour: size="+bitmap.Width+" expected="+ink+" actual="+pixel);
                    }
                }
                Require(solid>10 && clear>bitmap.Width*bitmap.Height/2,"Glyph lost its stroke or transparent background: size="+bitmap.Width+" solid="+solid+" clear="+clear);
            }
        }
        [STAThread] static int Main(string[] args) {
            try {
                Directory.CreateDirectory(args[0]);
                // Start-menu shortcuts extract the EXE icon, a separate path
                // from the tray and registered TIP. Check the compiled resource.
                string shellPath=args.Length>1?args[1]:Process.GetCurrentProcess().MainModule.FileName;
                using(var shellIcon=Icon.ExtractAssociatedIcon(shellPath)) {
                    Require(shellIcon!=null,"Shell could not extract the application icon");
                    // PNG application frames retain straight alpha, unlike
                    // our dynamically rendered premultiplied tray bitmaps.
                    Pixels(shellIcon,Color.White,false);
                }
                // Reproduces this machine: dark shell, light applications. Never write system preferences.
                var white=TaskbarIcon.SelectInk(key => key=="SystemUsesLightTheme" ? 0 : 1,false,Color.Red);
                var dark=TaskbarIcon.SelectInk(key => key=="SystemUsesLightTheme" ? 1 : 0,false,Color.Red);
                Require(white.ToArgb()==Color.White.ToArgb(),"Dark taskbar with light apps must use white ink");
                Require(dark.ToArgb()==Color.FromArgb(32,33,36).ToArgb(),"Light taskbar with dark apps must use dark ink");
                Require(TaskbarIcon.SelectInk(key=>null,false,Color.Red).ToArgb()==Color.White.ToArgb(),"Missing shell preference defaults to dark shell");
                Require(TaskbarIcon.SelectInk(key=>throw new Exception("High contrast must not read theme"),true,Color.Yellow)==Color.Yellow,"High contrast text colour");
                foreach(int size in new[]{16,20,24,32,40,48,64}) foreach(var ink in new[]{white,dark,Color.Yellow})
                    using(var icon=TaskbarIcon.Create(ink,size)) {
                        using(var bitmap=icon.ToBitmap())bitmap.Save(Path.Combine(args[0],size+"-"+ink.ToArgb()+".png"));
                        Require(icon.Width==size && icon.Height==size,"Wrong taskbar icon size"); Pixels(icon,ink);
                    }
                using(var tray=new Forms.NotifyIcon()) {
                    var current=white;
                    using(var owner=new TaskbarIcon(tray,Dispatcher.CurrentDispatcher,()=>current)) {
                        Pixels(tray.Icon,white);var first=tray.Icon;owner.Refresh();
                        Require(ReferenceEquals(first,tray.Icon),"Unchanged preferences allocated a new icon");
                        int before=GetGuiResources(Process.GetCurrentProcess().Handle,0);
                        for(int i=0;i<100;++i){current=i%2==0?dark:white;owner.Refresh();Pixels(tray.Icon,current);}
                        Require(GetGuiResources(Process.GetCurrentProcess().Handle,0)<=before+4,"Theme switches leaked GDI handles");
                        owner.Dispose();owner.Refresh();Require(tray.Icon==null,"Disposed owner retained the icon");
                    }
                }
                Console.WriteLine("PASS taskbar icons: mixed app/shell themes, high contrast, 7 native sizes, transparent pixels, repeated refresh and disposal");return 0;
            } catch(Exception error) {Console.Error.WriteLine(error);return 1;}
        }
    }
}
