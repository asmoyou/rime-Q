using System;
using Microsoft.Win32;

namespace RimeQ {
    internal static class InstallerRegistryTests {
        const string Profile = @"Software\Microsoft\CTF\TIP\{C13A9B62-413B-45B8-9EF1-884522319760}";
        const string Other = @"Software\Microsoft\CTF\TIP\{A8A621C8-C840-4F52-9DDC-C38340B2D84D}";
        static void Require(bool value, string message) { if (!value) throw new Exception(message); }
        static bool Exists(RegistryKey root, string path) { using (var key = root.OpenSubKey(path)) return key != null; }
        static void Seed(RegistryKey user) {
            // Reproduce the leftover disabled profile using a private test subtree,
            // with the same nested shape as CTF. Never register or activate a TIP.
            using (var key = user.CreateSubKey(Profile + @"\LanguageProfile\0x00000804\{984DA75B-478E-49B4-9CB6-945CA5E7AD41}")) key.SetValue("Enable", 0);
            using (var key = user.CreateSubKey(Other)) key.SetValue("sentinel", "other-input-method");
            using (var key = user.CreateSubKey(@"Software\RimeQ")) key.SetValue("sentinel", "personal-settings");
        }
        [STAThread]
        static int Main() {
            var fixture = @"Software\RimeQ.Tests\Uninstall-" + Guid.NewGuid().ToString("N");
            try {
                using (var root = Registry.CurrentUser.CreateSubKey(fixture))
                using (var desktop = root.CreateSubKey("desktop-user"))
                using (var administrator = root.CreateSubKey("administrator")) {
                    Seed(desktop); Seed(administrator);
                    Setup.RemoveUserRegistration(administrator);
                    Require(!Exists(administrator, Profile), "Uninstall left the user's disabled CTF profile");
                    Require(Exists(desktop, Profile), "Administrator cleanup reached a different user's profile");
                    Setup.RemoveUserRegistration(desktop);
                    Setup.RemoveUserRegistration(desktop);
                    Require(!Exists(desktop, Profile), "Desktop user cleanup left a CTF profile");
                    foreach (var user in new[] { desktop, administrator }) {
                        using (var other = user.OpenSubKey(Other)) Require((string)other.GetValue("sentinel") == "other-input-method", "Other input method changed");
                        using (var settings = user.OpenSubKey(@"Software\RimeQ")) Require((string)settings.GetValue("sentinel") == "personal-settings", "Personal settings changed");
                    }
                    Seed(desktop);
                    bool rejected = false;
                    using (var readOnly = root.OpenSubKey("desktop-user")) {
                        try { Setup.RemoveUserRegistration(readOnly); } catch (UnauthorizedAccessException) { rejected = true; }
                    }
                    Require(rejected && Exists(desktop, Profile), "A cleanup permission failure was hidden");
                }
                Console.WriteLine("PASS isolated installer registry: disabled profile removal, repeated cleanup, separate users, other input methods/settings retained, permission failure reported");
                return 0;
            } catch (Exception error) { Console.Error.WriteLine(error.Message); return 1; }
            finally { Registry.CurrentUser.DeleteSubKeyTree(fixture, false); }
        }
    }
}
