using System;
using System.Drawing;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Threading;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace RimeQ {
    // The shell and applications have independent light/dark settings.
    internal sealed class TaskbarIcon : IDisposable {
        readonly Forms.NotifyIcon tray;
        readonly Dispatcher dispatcher;
        readonly Func<Color> readInk;
        Icon owned;
        Color ink;
        int size;
        bool disposed;
        [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr icon);

        internal static Color SelectInk(Func<string, object> preference, bool highContrast, Color systemText) {
            if (highContrast) return systemText;
            return Convert.ToInt32(preference("SystemUsesLightTheme") ?? 0) == 0 ? Color.White : Color.FromArgb(32,33,36);
        }
        static Color CurrentInk() {
            using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                return SelectInk(name => key == null ? null : key.GetValue(name), Forms.SystemInformation.HighContrast, SystemColors.ControlText);
        }
        internal static Icon Create(Color ink, int size) {
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("TaskbarQ.ico"))
            using (var source = new Icon(stream, size, size))
            using (var bitmap = source.ToBitmap()) {
                for (int y = 0; y < bitmap.Height; ++y) for (int x = 0; x < bitmap.Width; ++x)
                    bitmap.SetPixel(x, y, Color.FromArgb(bitmap.GetPixel(x,y).A, ink));
                var handle = bitmap.GetHicon();
                try { using (var result = Icon.FromHandle(handle)) return (Icon)result.Clone(); }
                finally { DestroyIcon(handle); }
            }
        }
        internal TaskbarIcon(Forms.NotifyIcon tray, Dispatcher dispatcher, Func<Color> readInk = null) {
            this.tray = tray; this.dispatcher = dispatcher; this.readInk = readInk ?? CurrentInk;
            Refresh();
            SystemEvents.UserPreferenceChanged += PreferencesChanged;
        }
        void PreferencesChanged(object sender, UserPreferenceChangedEventArgs args) {
            if (!disposed && !dispatcher.HasShutdownStarted) dispatcher.BeginInvoke(new Action(Refresh));
        }
        internal void Refresh() {
            if (disposed) return;
            var nextInk = readInk(); var nextSize = Math.Max(16, Math.Min(64, Forms.SystemInformation.SmallIconSize.Width));
            if (owned != null && nextInk == ink && nextSize == size) return;
            var next = Create(nextInk, nextSize); var previous = owned;
            tray.Icon = next; owned = next; ink = nextInk; size = nextSize;
            if (previous != null) previous.Dispose();
        }
        public void Dispose() {
            if (disposed) return;
            disposed = true; SystemEvents.UserPreferenceChanged -= PreferencesChanged;
            tray.Icon = null;
            if (owned != null) { owned.Dispose(); owned = null; }
        }
    }
}
