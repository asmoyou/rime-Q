using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace RimeQ {
    internal static class Paths {
        internal static string App = AppDomain.CurrentDomain.BaseDirectory;
        internal static string Root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "RimeQ");
        internal static string Ini { get { return Path.Combine(Root, "settings.ini"); } }
        internal static string Model { get { return Path.Combine(Root, "models", "wanxiang-lts-zh-hans.gram"); } }
        internal const string Project = "https://github.com/asmoyou/rime-Q";
        internal const string Releases = Project + "/releases";
        internal static string Version { get { return FileVersionInfo.GetVersionInfo(Path.Combine(App, "RimeQ.Broker.exe")).FileVersion; } }
        internal static string Build { get { return FileVersionInfo.GetVersionInfo(Path.Combine(App, "RimeQ.Broker.exe")).FilePrivatePart.ToString(CultureInfo.InvariantCulture); } }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern uint GetPrivateProfileString(string section, string key, string fallback, StringBuilder value, uint size, string path);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool WritePrivateProfileString(string section, string key, string value, string path);
        internal static string Get(string key, string fallback = "") {
            var value = new StringBuilder(4096); GetPrivateProfileString("RimeQ", key, fallback, value, 4096, Ini); return value.ToString();
        }
        internal static void Set(string key, string value) {
            Directory.CreateDirectory(Root);
            if (!WritePrivateProfileString("RimeQ", key, value, Ini)) throw new IOException("无法保存设置。");
        }
        internal static void Open(string target) { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); }
        internal static void OpenWithArguments(string target, string arguments) { Process.Start(new ProcessStartInfo(target, arguments) { UseShellExecute = true }); }
        internal static void Start(string file, string arguments) {
            var info = new ProcessStartInfo(Path.Combine(App, file), arguments) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = App };
            var variables = new Dictionary<string, string>();
            foreach (var key in new[] { "APPDATA", "LOCALAPPDATA", "SystemRoot", "TEMP", "TMP", "USERPROFILE", "WINDIR" }) {
                var value = Environment.GetEnvironmentVariable(key); if (value != null) variables[key] = value;
            }
            info.EnvironmentVariables.Clear(); foreach (var pair in variables) info.EnvironmentVariables[pair.Key] = pair.Value;
            Process.Start(info);
        }
        internal static void AtomicText(string path, string text) {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try {
                File.WriteAllText(temporary, text, new UTF8Encoding(false));
                if (File.Exists(path)) File.Replace(temporary, path, null); else File.Move(temporary, path);
            } finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
    }
    internal sealed class BrokerState {
        internal bool Ready, Handled, Ascii;
        internal string Message;
    }
    internal static class Broker {
        static string Text(BinaryReader reader) {
            uint count = reader.ReadUInt32(); if (count > 16384) throw new IOException("无效的服务响应。");
            var data = reader.ReadBytes((int)count); if (data.Length != count) throw new EndOfStreamException();
            return new UTF8Encoding(false, true).GetString(data);
        }
        internal static Task<BrokerState> Request(int command) {
            return Task.Run(async () => {
                var identity = WindowsIdentity.GetCurrent().User.Value;
                var name = "RimeQ.v1." + identity;
                using (var pipe = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous, TokenImpersonationLevel.Identification)) {
                    await pipe.ConnectAsync(1500);
                    var operation = Exchange(pipe, command);
                    if (await Task.WhenAny(operation, Task.Delay(15000)) != operation) {
                        pipe.Dispose(); throw new TimeoutException("引擎服务响应超时，请结束输入后重试。");
                    }
                    return await operation;
                }
            });
        }
        static async Task ReadExact(Stream stream, byte[] bytes) {
            int offset = 0;
            while (offset < bytes.Length) { int count = await stream.ReadAsync(bytes, offset, bytes.Length - offset); if (count == 0) throw new EndOfStreamException(); offset += count; }
        }
        static async Task<BrokerState> Exchange(Stream pipe, int command) {
            var outgoing = new MemoryStream();
            using (var writer = new BinaryWriter(outgoing, Encoding.UTF8, true)) { writer.Write(16); writer.Write(1); writer.Write(command); writer.Write(0); writer.Write(0); }
            var data = outgoing.ToArray(); await pipe.WriteAsync(data, 0, data.Length);
            var length = new byte[4]; await ReadExact(pipe, length); int size = BitConverter.ToInt32(length, 0);
            if (size <= 0 || size > 65536) throw new IOException("无效的服务响应。");
            var response = new byte[size]; await ReadExact(pipe, response);
            using (var reader = new BinaryReader(new MemoryStream(response), new UTF8Encoding(false, true))) {
                if (reader.ReadInt32() != 1) throw new IOException("输入服务版本不兼容，请重新安装。");
                var state = new BrokerState { Ready = reader.ReadInt32() != 0, Handled = reader.ReadInt32() != 0, Ascii = reader.ReadInt32() != 0 };
                for (int i = 0; i < 4; ++i) reader.ReadInt32(); Text(reader); Text(reader); state.Message = Text(reader);
                var count = reader.ReadUInt32(); if (count > 9) throw new IOException("无效的候选数量。");
                for (int i = 0; i < count; ++i) { Text(reader); Text(reader); }
                if (reader.BaseStream.Position != reader.BaseStream.Length) throw new IOException("无效的响应长度。");
                return state;
            }
        }
    }
    internal sealed class UpdateResult {
        public string State { get; set; }
        public string Message { get; set; }
        public string Tag { get; set; }
    }
    internal sealed class Updates {
        const string Endpoint = "https://api.github.com/repos/asmoyou/rime-Q/releases/latest";
        readonly HttpClient http;
        Task<UpdateResult> pending;
        internal event Action Changed;
        internal UpdateResult Result { get; private set; }
        internal Updates(HttpClient client = null) {
            http = client ?? new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("RimeQ-Windows/0.4.0");
            http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
            Result = new UpdateResult { State = Paths.Get("UpdateState", "unchecked"), Message = Paths.Get("UpdateMessage", "尚未检查更新。"), Tag = Paths.Get("UpdateTag") };
        }
        internal static bool Due(DateTime now, string last, bool enabled) {
            DateTime time;
            if (!enabled) return false;
            if (!DateTime.TryParse(last, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out time)) return true;
            return time > now || now - time >= TimeSpan.FromHours(24);
        }
        internal Task<UpdateResult> Check(bool manual) {
            if (pending != null && !pending.IsCompleted) return pending;
            if (!manual && !Due(DateTime.UtcNow, Paths.Get("LastUpdateAttempt"), Paths.Get("AutoUpdate", "1") == "1")) return Task.FromResult(Result);
            // Save before the request. A crash, clock rollback or network failure also consumes the daily attempt.
            Paths.Set("LastUpdateAttempt", DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture));
            pending = Run(); return pending;
        }
        internal static UpdateResult Parse(HttpStatusCode status, string body, string installed) {
            if (status == HttpStatusCode.NotFound) return new UpdateResult { State = "unpublished", Message = "尚无公开的 Windows 发布版本。" };
            if ((int)status < 200 || (int)status >= 300) return new UpdateResult { State = "failed", Message = "检查失败（HTTP " + (int)status + "），请稍后重试。" };
            var json = new JavaScriptSerializer { MaxJsonLength = 1024 * 1024 }.Deserialize<Dictionary<string, object>>(body);
            if (json == null || !json.ContainsKey("tag_name") || !json.ContainsKey("draft") || !json.ContainsKey("prerelease")) throw new FormatException("无效的发布信息。");
            if (!(json["draft"] is bool) || !(json["prerelease"] is bool)) throw new FormatException("无效的发布状态。");
            if ((bool)json["draft"] || (bool)json["prerelease"]) return new UpdateResult { State = "unpublished", Message = "尚无公开的 Windows 稳定版本。" };
            var tag = json["tag_name"] as string; Version current, release;
            if (tag == null || !Version.TryParse(tag.TrimStart('v'), out release) || !Version.TryParse(installed, out current)) throw new FormatException("无法识别发布版本。");
            bool windows = false;
            if (json.ContainsKey("assets")) {
                var assets = json["assets"] as System.Collections.IEnumerable;
                if (assets != null) foreach (var raw in assets) {
                    var asset = raw as Dictionary<string, object>; object name;
                    if (asset != null && asset.TryGetValue("name", out name) && name is string && ((string)name).StartsWith("RimeQ-", StringComparison.Ordinal) &&
                        ((string)name).EndsWith("-windows-x64.exe", StringComparison.OrdinalIgnoreCase)) windows = true;
                }
            }
            if (!windows) return new UpdateResult { State = "unpublished", Message = "当前公开发布尚未提供 Windows 安装包。" };
            return release > current ? new UpdateResult { State = "available", Message = "发现新版本 " + tag + "，可前往发布页下载。", Tag = tag }
                : new UpdateResult { State = "current", Message = "没有更新的 Windows 版本。", Tag = tag };
        }
        async Task<UpdateResult> Run() {
            try {
                using (var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20)))
                using (var response = await http.GetAsync(Endpoint, HttpCompletionOption.ResponseHeadersRead, timeout.Token)) {
                    if (!response.IsSuccessStatusCode) Result = Parse(response.StatusCode, "", Paths.Version);
                    else {
                    if (response.Content == null || response.Content.Headers.ContentLength > 1024 * 1024) throw new IOException("发布信息为空或过大。");
                    using (var input = await response.Content.ReadAsStreamAsync()) using (var data = new MemoryStream()) {
                        var buffer = new byte[8192]; int count;
                        while ((count = await input.ReadAsync(buffer, 0, buffer.Length, timeout.Token)) != 0) {
                            if (data.Length + count > 1024 * 1024) throw new IOException("发布信息过大。"); data.Write(buffer, 0, count);
                        }
                        Result = Parse(response.StatusCode, Encoding.UTF8.GetString(data.ToArray()), Paths.Version);
                    }
                    }
                }
            } catch (Exception e) when (e is HttpRequestException || e is TaskCanceledException || e is IOException || e is FormatException || e is InvalidOperationException || e is ArgumentException) {
                Result = new UpdateResult { State = "failed", Message = "检查失败，请确认网络连接后重试。", Tag = Paths.Get("UpdateTag") };
            } finally { pending = null; }
            Paths.Set("UpdateState", Result.State); Paths.Set("UpdateMessage", Result.Message); Paths.Set("UpdateTag", Result.Tag ?? "");
            if (Changed != null) Changed(); return Result;
        }
    }
    internal sealed class ModelManager {
        internal const long ExpectedBytes = 420343852;
        internal const string ExpectedHash = "9f80530f470033cfb6d4b44bb861b540f64100426f92dd0f87140883632a3d93";
        internal bool Busy { get; private set; }
        internal bool Valid { get; private set; }
        internal double Progress { get; private set; }
        internal string Status { get; private set; } = "未下载 · 420.3 MB";
        internal event Action Changed;
        CancellationTokenSource cancellation;
        string engineStatus;
        void Notify() { if (Changed != null) Changed(); }
        internal static bool Verify(string path) {
            return Verify(path, ExpectedBytes, ExpectedHash);
        }
        internal static bool Verify(string path, long expectedBytes, string expectedHash) {
            if (!File.Exists(path) || new FileInfo(path).Length != expectedBytes) return false;
            using (var stream = File.OpenRead(path)) using (var hash = SHA256.Create())
                return BitConverter.ToString(hash.ComputeHash(stream)).Replace("-", "").ToLowerInvariant() == expectedHash;
        }
        internal static async Task Receive(Stream input, string path, long expectedBytes, string expectedHash, Action<long> progress, CancellationToken token) {
            bool created = false;
            try {
                token.ThrowIfCancellationRequested();
                using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1024 * 128, true)) {
                    created = true; var bytes = new byte[1024 * 128]; long total = 0; int count;
                    for (;;) {
                        using (var idleTimeout = CancellationTokenSource.CreateLinkedTokenSource(token)) {
                            idleTimeout.CancelAfter(TimeSpan.FromSeconds(45));
                            try { count = await input.ReadAsync(bytes, 0, bytes.Length, idleTimeout.Token); }
                            catch (OperationCanceledException) when (!token.IsCancellationRequested) { throw new IOException("下载连接超时，请重试。"); }
                        }
                        if (count == 0) break;
                        total += count; if (total > expectedBytes) throw new IOException("下载内容超出预期大小。");
                        await output.WriteAsync(bytes, 0, count, token); if (progress != null) progress(total);
                    }
                    await output.FlushAsync(token);
                }
                token.ThrowIfCancellationRequested();
                if (!await Task.Run(() => Verify(path, expectedBytes, expectedHash))) throw new IOException("模型校验失败，请重试。");
                token.ThrowIfCancellationRequested();
            } catch { if (created && File.Exists(path)) File.Delete(path); throw; }
        }
        internal async Task Restore() {
            try {
                Valid = await Task.Run(() => Verify(Paths.Model));
                Status = Valid ? "已下载并通过校验 · 可离线使用" : File.Exists(Paths.Model) ? "模型校验失败，当前使用基础组词。可重新下载。" : "未下载 · 420.3 MB";
            } catch (Exception error) when (error is IOException || error is UnauthorizedAccessException) {
                Valid = false; Status = "模型暂时无法读取，当前使用基础组词。";
            }
            Notify();
        }
        internal void Cancel() { if (cancellation != null) cancellation.Cancel(); }
        internal void RefreshEngineStatus() {
            if (Busy) return;
            var value = Paths.Get("ModelStatus"); if (value == engineStatus) return; engineStatus = value;
            switch (value) {
                case "enabled": Status = "整句优化已开启 · 离线使用"; break;
                case "downloaded": Status = "已下载，当前使用基础组词。"; break;
                case "pending": Status = "等待当前输入结束后切换。"; break;
                case "checking": Status = "正在后台校验本地模型，暂用基础组词。"; break;
                case "invalid": Status = "模型校验失败，已使用基础组词。"; break;
                case "link-error": Status = "无法建立或移除模型链接。请检查数据目录，未知同名文件会保留。"; break;
                case "engine-error": Status = "引擎未能启用此模型，已恢复基础组词。"; break;
                case "storage-error": Status = "模型文件暂时被占用或无法操作，将在空闲时重试。"; break;
                case "missing": Status = "未下载 · 420.3 MB"; break;
                default: return;
            }
            Notify();
        }
        internal async Task Download() {
            if (Busy) return; Busy = true; Progress = 0; Status = "正在连接下载…"; cancellation = new CancellationTokenSource(); Notify();
            var token = cancellation.Token; var folder = Path.GetDirectoryName(Paths.Model); Directory.CreateDirectory(folder);
            var temporary = Path.Combine(folder, Guid.NewGuid().ToString("N") + ".download");
            try {
                var json = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(Path.Combine(Paths.App, "model.json"), Encoding.UTF8));
                if (Convert.ToInt64(json["bytes"], CultureInfo.InvariantCulture) != ExpectedBytes || (string)json["sha256"] != ExpectedHash ||
                    (string)json["filename"] != "wanxiang-lts-zh-hans.gram") throw new IOException("模型描述与依赖锁不一致。");
                var uri = new Uri((string)json["url"]);
                if (uri.Scheme != "https" || uri.Host != "github.com" || !uri.AbsolutePath.StartsWith("/amzxyz/RIME-LMDG/releases/download/LTS/", StringComparison.Ordinal))
                    throw new IOException("无效的模型下载地址。");
                using (var http = new HttpClient { Timeout = Timeout.InfiniteTimeSpan }) {
                    http.DefaultRequestHeaders.UserAgent.ParseAdd("RimeQ-Windows/0.4.0");
                    using (var response = await http.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, token)) {
                        response.EnsureSuccessStatusCode();
                        if (response.Content.Headers.ContentLength.HasValue && response.Content.Headers.ContentLength != ExpectedBytes) throw new IOException("下载大小与依赖锁不一致。");
                        using (var input = await response.Content.ReadAsStreamAsync()) {
                            var clock = Stopwatch.StartNew();
                            await Receive(input, temporary, ExpectedBytes, ExpectedHash, total => {
                                if (clock.ElapsedMilliseconds > 100 || total == ExpectedBytes) {
                                    Progress = 100.0 * total / ExpectedBytes;
                                    Status = total == ExpectedBytes ? "正在校验 SHA-256…" : string.Format(CultureInfo.InvariantCulture, "正在下载 {0:F1} / 420.3 MB", total / 1000000.0);
                                    Notify(); clock.Restart();
                                }
                            }, token);
                        }
                    }
                }
                token.ThrowIfCancellationRequested();
                if (File.Exists(Paths.Model)) {
                    if (await Task.Run(() => Verify(Paths.Model))) File.Delete(temporary);
                    else throw new IOException("已有同名文件校验失败。请先移除旧模型，再重新下载。");
                } else File.Move(temporary, Paths.Model);
                Valid = true; Progress = 100; Paths.Set("RemoveModel", "0"); Paths.Set("Grammar", "1");
                Status = "下载完成，当前输入结束后开启。";
            } catch (OperationCanceledException) { Status = "下载已取消，可随时重试。"; }
            catch (Exception e) when (e is IOException || e is HttpRequestException || e is UnauthorizedAccessException || e is ArgumentException) { Status = "下载失败：" + e.Message; }
            finally { if (File.Exists(temporary)) File.Delete(temporary); Busy = false; cancellation.Dispose(); cancellation = null; Notify(); }
        }
        internal void Remove() { Paths.Set("Grammar", "0"); Paths.Set("RemoveModel", "1"); Status = "当前输入结束后移除模型，保留个人学习。"; Notify(); }
    }
    public sealed class DictionaryRow {
        public string Text { get; set; }
        public string Code { get; set; }
        public int Weight { get; set; }
    }
    internal static class DictionaryData {
        internal static List<DictionaryRow> Parse(string text) {
            if (Encoding.UTF8.GetByteCount(text) > 16 * 1024 * 1024) throw new IOException("词表不能超过 16 MB。");
            var rows = new List<DictionaryRow>(); int lineNumber = 0;
            foreach (var raw in text.Replace("\r", "").Split('\n')) {
                ++lineNumber; if (string.IsNullOrWhiteSpace(raw) || raw.StartsWith("#", StringComparison.Ordinal)) continue;
                var fields = raw.Split('\t'); int weight = 1;
                if (fields.Length < 2 || fields.Length > 3 || fields[0].Length == 0 || fields[0].Length > 128 || fields[0].Any(char.IsControl) ||
                    fields[1].Length == 0 || fields[1].Length > 256 || fields[1].Any(c => !(c >= 'a' && c <= 'z') && c != ' ' && c != '\''))
                    throw new FormatException("第 " + lineNumber + " 行格式错误。使用“词语 TAB 小写全拼 TAB 次数”。");
                if (fields.Length == 3 && !int.TryParse(fields[2], NumberStyles.Integer, CultureInfo.InvariantCulture, out weight))
                    throw new FormatException("第 " + lineNumber + " 行次数无效。");
                if (weight < -1 || weight > 1000000) throw new FormatException("次数超出范围。");
                rows.Add(new DictionaryRow { Text = fields[0], Code = fields[1].Trim(), Weight = weight });
                if (rows.Count > 100000) throw new FormatException("词表不能超过 10 万条。");
            }
            return rows;
        }
        internal static string Format(IEnumerable<DictionaryRow> rows) {
            return "# Rime Q personal dictionary\n" + string.Join("\n", rows.Select(r => r.Text + "\t" + r.Code.Trim() + " \t" + r.Weight.ToString(CultureInfo.InvariantCulture))) + "\n";
        }
        internal static async Task<List<DictionaryRow>> Load() {
            var state = await Broker.Request(7); if (!state.Ready || !state.Handled) throw new IOException(state.Message);
            return Parse(File.ReadAllText(Path.Combine(Paths.Root, "dictionary", "export.tsv"), Encoding.UTF8));
        }
        internal static async Task Save(IEnumerable<DictionaryRow> rows) {
            var text = Format(rows); Parse(text);
            Paths.AtomicText(Path.Combine(Paths.Root, "dictionary", "import.tsv"), text);
            var state = await Broker.Request(8); if (!state.Ready || !state.Handled) throw new IOException(state.Message);
        }
    }
}
