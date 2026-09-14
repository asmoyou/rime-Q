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
        internal static void AtomicBytes(string path, byte[] bytes) {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path)));
            var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try {
                File.WriteAllBytes(temporary, bytes);
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
            http.DefaultRequestHeaders.UserAgent.ParseAdd("RimeQ-Windows/0.4.2");
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
                    http.DefaultRequestHeaders.UserAgent.ParseAdd("RimeQ-Windows/0.4.2");
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
        internal string Id { get { return Code + "\t" + Text; } }
        internal DictionaryRow Copy(int? weight = null) { return new DictionaryRow { Text = Text, Code = Code, Weight = weight ?? Weight }; }
    }
    internal sealed class DictionaryChange {
        internal List<DictionaryRow> Before, After;
        internal HashSet<string> Ids { get { return new HashSet<string>(Before.Concat(After).Select(row => row.Id), StringComparer.Ordinal); } }
    }
    internal static class DictionaryData {
        const int Limit = 32 * 1024 * 1024;
        static readonly UTF8Encoding StrictUtf8 = new UTF8Encoding(false, true);
        static HashSet<string> syllables;
        internal static Func<Task<List<DictionaryRow>>> TestLoad { get; set; }
        internal static Func<IEnumerable<DictionaryRow>,Task> TestImport { get; set; }
        internal static DictionaryChange LastChange { get; private set; }
        internal static string BackupDirectory { get { return Path.Combine(Paths.Root, "lexicon-backups"); } }
        internal static string BackupPath { get { return Path.Combine(BackupDirectory, "before-last-change.tsv"); } }

        internal static string NormalizeCode(string code) {
            return string.Join(" ", (code ?? "").Replace("ü", "v").Replace("'", " ").Split(new[] {' '}, StringSplitOptions.RemoveEmptyEntries));
        }
        static DictionaryRow Draft(string text, string code, int weight, bool allowDelete) {
            var row = new DictionaryRow { Text = (text ?? "").Trim(), Code = NormalizeCode(code), Weight = weight };
            if (row.Text.Length == 0 || row.Text.StartsWith("#", StringComparison.Ordinal) || Encoding.UTF8.GetByteCount(row.Text) > 1024 || row.Text.Any(char.IsControl) ||
                row.Code.Length == 0 || Encoding.UTF8.GetByteCount(row.Code) > 1024 || row.Code.Split(' ').Any(part => part.Length == 0 || part.Length > 16 || part.Any(c => !(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z'))) ||
                row.Weight < (allowDelete ? -1 : 0) || row.Weight == int.MaxValue)
                throw new FormatException("词条不能为空；拼音请按音节用空格分隔，不带声调，例如 xing he ci ku。权重须为非负整数。");
            return row;
        }
        internal static List<DictionaryRow> Parse(string text, bool allowDelete = false, bool allowEmpty = true) {
            if (text == null || Encoding.UTF8.GetByteCount(text) > Limit) throw new IOException("词表不能超过 32 MB。");
            if (text.Length > 0 && text[0] == '\ufeff') text = text.Substring(1);
            var unique = new Dictionary<string, DictionaryRow>(StringComparer.Ordinal); int lineNumber = 0;
            foreach (var raw in text.Replace("\r", "").Split('\n')) {
                ++lineNumber;
                if (raw.StartsWith("#@/db_name\t", StringComparison.Ordinal) && raw != "#@/db_name\trime_q")
                    throw new FormatException("此文件属于其他输入方案，请导入 Rime Q 的全拼学习词库。");
                if (string.IsNullOrWhiteSpace(raw) || raw.StartsWith("#", StringComparison.Ordinal)) continue;
                var fields = raw.Split('\t'); int weight = 1;
                if (fields.Length < 2 || fields.Length > 3 || (fields.Length == 3 && !int.TryParse(fields[2], NumberStyles.Integer, CultureInfo.InvariantCulture, out weight)))
                    throw new FormatException("第 " + lineNumber + " 行格式不正确。需要：词条、拼音、可选学习权重，以制表符分隔。");
                DictionaryRow row;
                try { row = Draft(fields[0], fields[1], weight, allowDelete); }
                catch (FormatException error) { throw new FormatException("第 " + lineNumber + " 行：" + error.Message); }
                DictionaryRow prior;
                if (!unique.TryGetValue(row.Id, out prior) || row.Weight > prior.Weight) unique[row.Id] = row;
                if (unique.Count > 200000) throw new FormatException("一次最多导入 20 万条个人记录。");
            }
            if (!allowEmpty && unique.Count == 0) throw new FormatException("文件中没有可导入的词条。");
            return unique.Values.OrderBy(row => row.Id, StringComparer.Ordinal).ToList();
        }
        static HashSet<string> Syllables() {
            if (syllables != null) return syllables;
            var result = new HashSet<string>(StringComparer.Ordinal);
            var path = Path.Combine(Paths.App, "data", "cn_dicts", "8105.dict.yaml"); bool body = false;
            foreach (var line in File.ReadLines(path, StrictUtf8)) {
                if (line.Trim() == "...") { body = true; continue; }
                if (!body || line.Length == 0 || line.StartsWith("#", StringComparison.Ordinal)) continue;
                var fields = line.Split('\t'); if (fields.Length < 2) continue;
                foreach (var value in fields[1].Split(new[] {' '}, StringSplitOptions.RemoveEmptyEntries)) result.Add(value);
            }
            if (result.Count == 0) throw new IOException("拼音校验资源不可用，请重新安装 Rime Q。");
            return syllables = result;
        }
        internal static void ValidateFullPinyin(DictionaryRow row) {
            var known = Syllables();
            if (row.Code.Split(' ').Any(part => !known.Contains(part) && !part.All(c => c >= 'A' && c <= 'Z')))
                throw new FormatException("拼音中有无法识别的音节。请使用不带声调的全拼，并用空格分隔，例如 shu ru fa。");
        }
        internal static List<DictionaryRow> ParsePersonal(string text) {
            var rows=Parse(text,false,false); foreach(var row in rows) ValidateFullPinyin(row); return rows;
        }
        internal static List<DictionaryRow> ReadPersonal(string path) {
            var file=new FileInfo(path);if(!file.Exists||file.Length>Limit)throw new IOException("请选择不超过 32 MB 的个人词库文件。");
            return ParsePersonal(File.ReadAllText(path,StrictUtf8));
        }
        internal static string Format(IEnumerable<DictionaryRow> rows) {
            return "# Rime Q personal dictionary export\n#@/db_name\trime_q\n# 词条\t全拼（空格分隔）\t学习权重\n" +
                string.Join("\n", rows.Select(r => r.Text + "\t" + r.Code + "\t" + r.Weight.ToString(CultureInfo.InvariantCulture))) + "\n";
        }
        internal static async Task<List<DictionaryRow>> Load() {
            if (TestLoad != null) return await TestLoad();
            var state = await Broker.Request(7); if (!state.Ready || !state.Handled) throw new IOException(state.Message);
            return Parse(File.ReadAllText(Path.Combine(Paths.Root, "dictionary", "export.tsv"), StrictUtf8));
        }
        static async Task Import(IEnumerable<DictionaryRow> rows) {
            var values = rows.ToList(); var text = Format(values); Parse(text, true);
            if (TestImport != null) { await TestImport(values); return; }
            Paths.AtomicText(Path.Combine(Paths.Root, "dictionary", "import.tsv"), text);
            var state = await Broker.Request(8); if (!state.Ready || !state.Handled) throw new IOException(state.Message);
        }
        static bool Same(IEnumerable<DictionaryRow> left, IEnumerable<DictionaryRow> right) {
            var a = left.OrderBy(row => row.Id, StringComparer.Ordinal).ToList(); var b = right.OrderBy(row => row.Id, StringComparer.Ordinal).ToList();
            return a.Count == b.Count && a.Zip(b, (x,y) => x.Text == y.Text && x.Code == y.Code && x.Weight == y.Weight).All(value => value);
        }
        static async Task<List<DictionaryRow>> Apply(DictionaryChange change, List<DictionaryRow> current = null) {
            current = current ?? await Load(); var ids = change.Ids;
            if (!Same(current.Where(row => ids.Contains(row.Id)), change.Before))
                throw new IOException("这些词条在上次读取后已有新的学习或修改。请刷新列表后重试，避免覆盖新记录。");
            Directory.CreateDirectory(BackupDirectory); Paths.AtomicText(BackupPath, Format(current));
            var after = new HashSet<string>(change.After.Select(row => row.Id), StringComparer.Ordinal);
            var previous = change.Before.ToDictionary(row => row.Id, row => row.Weight, StringComparer.Ordinal);
            var updates = change.After.Where(row => previous.ContainsKey(row.Id) && previous[row.Id] > row.Weight).Select(row => row.Copy(-1)).ToList();
            updates.AddRange(change.After.Select(row => row.Copy()));
            updates.AddRange(change.Before.Where(row => !after.Contains(row.Id)).Select(row => row.Copy(-1)));
            await Import(updates);
            var actual = await Load(); var observed = actual.Where(row => ids.Contains(row.Id)).Select(row => row.Copy()).ToList();
            LastChange = new DictionaryChange { Before = change.Before.Select(row => row.Copy()).ToList(), After = observed };
            if (!Same(observed, change.After)) throw new IOException("修改未能完整完成。已保留修改前的备份，可刷新后撤销或恢复备份。");
            return actual;
        }
        internal static async Task<List<DictionaryRow>> Save(DictionaryRow entry, DictionaryRow original) {
            entry = Draft(entry.Text, entry.Code, Math.Max(1, original == null ? entry.Weight : original.Weight), false); ValidateFullPinyin(entry);
            return await Apply(new DictionaryChange { Before = original == null ? new List<DictionaryRow>() : new List<DictionaryRow> { original.Copy() }, After = new List<DictionaryRow> { entry } });
        }
        internal static Task<List<DictionaryRow>> Delete(IEnumerable<DictionaryRow> entries) {
            var removed = entries.Select(row => row.Copy()).ToList(); if (removed.Count == 0) throw new InvalidOperationException("请先选择词条。");
            return Apply(new DictionaryChange { Before = removed, After = new List<DictionaryRow>() });
        }
        internal static async Task<List<DictionaryRow>> Merge(IEnumerable<DictionaryRow> entries) {
            var imported = entries.Select(row => Draft(row.Text, row.Code, row.Weight, false)).ToList(); foreach (var row in imported) ValidateFullPinyin(row);
            var current = await Load(); var incoming = new HashSet<string>(imported.Select(row => row.Id), StringComparer.Ordinal);
            var originals = current.Where(row => incoming.Contains(row.Id)).Select(row => row.Copy()).ToList();
            var byId = originals.ToDictionary(row => row.Id, row => row.Weight, StringComparer.Ordinal);
            var changed = imported.Select(row => row.Copy(Math.Max(Math.Max(1, row.Weight), byId.ContainsKey(row.Id) ? byId[row.Id] : 0))).ToList();
            return await Apply(new DictionaryChange { Before = originals, After = changed }, current);
        }
        internal static async Task<List<DictionaryRow>> Undo() {
            if (LastChange == null) throw new InvalidOperationException("当前没有可以撤销的修改。");
            var change = LastChange; LastChange = null;
            var result=await Apply(new DictionaryChange { Before = change.After.Select(row => row.Copy()).ToList(), After = change.Before.Select(row => row.Copy(Math.Max(1, row.Weight))).ToList() });
            LastChange=null; return result;
        }
    }
}
