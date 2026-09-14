using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace RimeQ {
    internal sealed class BundledDictionary {
        public string id { get; set; }
        public string name { get; set; }
        public string file { get; set; }
        public int count { get; set; }
        public long bytes { get; set; }
        public string sha256 { get; set; }
        public string source { get; set; }
        public string version { get; set; }
        public string license { get; set; }
        public bool optional { get; set; }
        public string kind { get; set; }
    }
    internal sealed class ImportedDictionary {
        public string id { get; set; }
        public string name { get; set; }
        public string originalName { get; set; }
        public string version { get; set; }
        public string source { get; set; }
        public string license { get; set; }
        public string sha256 { get; set; }
        public int count { get; set; }
        public long bytes { get; set; }
        public bool enabled { get; set; }
    }
    internal sealed class DictionaryConfiguration {
        public int format { get; set; } = 1;
        public string generation { get; set; }
        public List<string> disabled { get; set; } = new List<string>();
        public List<ImportedDictionary> imported { get; set; } = new List<ImportedDictionary>();
    }
    internal sealed class DictionaryImport {
        internal byte[] Original;
        internal string OriginalName, Name, Version;
        internal List<DictionaryRow> Entries;

        static string Scalar(string value) {
            value = value.Trim();
            if (value.Length >= 2 && ((value[0] == '\'' && value[value.Length-1] == '\'') || (value[0] == '"' && value[value.Length-1] == '"')))
                value = value.Substring(1,value.Length-2);
            return value;
        }
        internal static DictionaryImport Read(string path) {
            var file = new FileInfo(path); if (!file.Exists || file.Length > 32 * 1024 * 1024) throw new IOException("请选择不超过 32 MB 的文本词库文件。");
            var original = File.ReadAllBytes(path); string text;
            try { text = new UTF8Encoding(false,true).GetString(original); } catch (DecoderFallbackException) { throw new IOException("词库必须是 UTF-8 编码的文本文件。"); }
            if (text.Length > 0 && text[0] == '\ufeff') text = text.Substring(1);
            var lines = text.Replace("\r","").Split('\n'); var name = Path.GetFileNameWithoutExtension(path); var version = "未注明";
            var columns = new List<string> { "text", "code", "weight" }; int start = 0;
            if (path.EndsWith(".dict.yaml",StringComparison.OrdinalIgnoreCase)) {
                var end = Array.FindIndex(lines, 0, Math.Min(1000,lines.Length), line => line.Trim() == "...");
                if (end < 0) throw new FormatException("Rime 词表缺少以 ... 结束的 YAML 文件头。");
                for (int i=0;i<end;++i) {
                    var line = lines[i].Trim();
                    if (line.StartsWith("import_tables:",StringComparison.Ordinal)) throw new FormatException("请选择包含实际词条的独立 Rime 词表，不支持仅引用其他词表的合集。");
                    if (line.StartsWith("name:",StringComparison.Ordinal)) name = Scalar(line.Substring(5));
                    else if (line.StartsWith("version:",StringComparison.Ordinal)) version = Scalar(line.Substring(8));
                    else if (line.StartsWith("columns:",StringComparison.Ordinal)) {
                        var value = line.Substring(8).Trim();
                        if (!value.StartsWith("[",StringComparison.Ordinal) || !value.EndsWith("]",StringComparison.Ordinal)) throw new FormatException("词表 columns 需要使用 [text, code, weight] 格式。");
                        columns = value.Substring(1,value.Length-2).Split(',').Select(item => item.Trim()).ToList();
                    }
                }
                start = end + 1;
            } else if (!path.EndsWith(".tsv",StringComparison.OrdinalIgnoreCase) && !path.EndsWith(".txt",StringComparison.OrdinalIgnoreCase))
                throw new FormatException("支持 UTF-8 的 .dict.yaml 或 TSV 词表；二进制词库请先转换为全拼文本。");
            var textColumn = columns.IndexOf("text"); var codeColumn = columns.IndexOf("code"); var weightColumn = columns.IndexOf("weight");
            if (textColumn < 0 || codeColumn < 0 || columns.Distinct(StringComparer.Ordinal).Count() != columns.Count || columns.Any(column => !new[] {"text","code","weight","stem"}.Contains(column)))
                throw new FormatException("第三方词表需要明确的词条与全拼列（text、code），不支持声调、双拼或无注音词表。");
            var unique = new Dictionary<string,DictionaryRow>(StringComparer.Ordinal);
            for (int i=start;i<lines.Length;++i) {
                var line = lines[i]; if (line.Length == 0 || line.StartsWith("#",StringComparison.Ordinal)) continue;
                var fields = line.Split('\t');
                if (fields.Length <= Math.Max(textColumn,codeColumn) || fields.Length > columns.Count) throw new FormatException("第 "+(i+1)+" 行缺少词条或拼音，或含有多余的列。");
                var rawWeight = weightColumn >= 0 && weightColumn < fields.Length && fields[weightColumn].Length > 0 ? fields[weightColumn] : "100";
                double number; if (!double.TryParse(rawWeight,NumberStyles.Float,CultureInfo.InvariantCulture,out number) || double.IsNaN(number) || double.IsInfinity(number) || number < 0 || number >= int.MaxValue)
                    throw new FormatException("第 "+(i+1)+" 行的词频必须是非负数，不支持百分比词频。");
                DictionaryRow row;
                try {
                    row = DictionaryData.Parse(fields[textColumn]+"\t"+fields[codeColumn]+"\t"+((int)number).ToString(CultureInfo.InvariantCulture),false,false).Single();
                    DictionaryData.ValidateFullPinyin(row);
                } catch (Exception error) when (error is FormatException || error is IOException) { throw new FormatException("第 "+(i+1)+" 行："+error.Message); }
                DictionaryRow prior; if (!unique.TryGetValue(row.Id,out prior) || row.Weight > prior.Weight) unique[row.Id] = row;
                if (unique.Count > 500000) throw new FormatException("单个第三方词库最多支持 50 万条记录。");
            }
            if (unique.Count == 0) throw new FormatException("没有找到带全拼编码的词条。");
            return new DictionaryImport { Original=original, OriginalName=Path.GetFileName(path), Name=name, Version=version,
                Entries=unique.Values.OrderBy(row=>row.Id,StringComparer.Ordinal).ToList() };
        }
    }

    internal sealed class DictionaryResources {
        static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 32 * 1024 * 1024 };
        internal readonly List<BundledDictionary> Catalog;
        internal DictionaryConfiguration Configuration { get; private set; }
        internal string LoadingError { get; private set; }
        internal bool ConfigurationReadable { get; private set; } = true;
        internal bool Busy { get; private set; }
        internal event Action Changed;
        internal Func<Task> RestartBroker;
        internal string DirectoryPath { get { return Path.Combine(Paths.Root,"dictionaries"); } }
        internal string ManifestPath { get { return Path.Combine(DirectoryPath,"configuration.json"); } }
        string ActivePath { get { return Path.Combine(DirectoryPath,"active.txt"); } }
        string GenerationsPath { get { return Path.Combine(DirectoryPath,"generations"); } }

        internal DictionaryResources() {
            Catalog = Json.Deserialize<List<BundledDictionary>>(File.ReadAllText(Path.Combine(Paths.App,"dictionaries.json"),new UTF8Encoding(false,true))) ?? new List<BundledDictionary>();
            Configuration = new DictionaryConfiguration(); RestartBroker = BrokerLifecycle.Restart;
            if (File.Exists(ManifestPath)) try {
                var loaded = Json.Deserialize<DictionaryConfiguration>(File.ReadAllText(ManifestPath,new UTF8Encoding(false,true)));
                Validate(loaded,true); Configuration = loaded;
            } catch (Exception error) { ConfigurationReadable=false; LoadingError="词库配置读取失败。原文件已保留："+error.Message; }
        }
        void Notify() { var changed=Changed; if (changed!=null) changed(); }
        internal DictionaryConfiguration CopyConfiguration() { return Json.Deserialize<DictionaryConfiguration>(Json.Serialize(Configuration)); }
        void Validate(DictionaryConfiguration config, bool persisted=false) {
            if (config == null || config.format != 1 || config.disabled == null || config.imported == null ||
                config.disabled.Except(Catalog.Where(item=>item.optional).Select(item=>item.id),StringComparer.Ordinal).Any() ||
                config.imported.Select(item=>item.id).Distinct(StringComparer.OrdinalIgnoreCase).Count()!=config.imported.Count ||
                config.imported.Any(item => { Guid id; return !Guid.TryParse(item.id,out id) || string.IsNullOrWhiteSpace(item.name); }) ||
                (config.generation!=null && !Guid.TryParse(config.generation,out _))) throw new FormatException("词库配置格式或版本不受支持。");
            if (persisted && config.generation==null && (config.disabled.Count>0 || config.imported.Any(item=>item.enabled)))
                throw new FormatException("词库启用配置缺少对应的编译资源。");
        }
        internal string ImportedPath(ImportedDictionary entry, bool original=false) { return Path.Combine(DirectoryPath,"imports",entry.id+(original?".source":".tsv")); }
        static string Hash(byte[] bytes) { using (var sha=SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-","").ToLowerInvariant(); }
        internal DictionaryConfiguration Adding(DictionaryImport draft, string name, string source, string license) {
            if (Busy || !ConfigurationReadable) throw new IOException(LoadingError ?? "正在应用词库，请稍候。");
            var entry = new ImportedDictionary { id=Guid.NewGuid().ToString(), name=string.IsNullOrWhiteSpace(name)?draft.Name:name.Trim(), originalName=draft.OriginalName,
                version=draft.Version, source=string.IsNullOrWhiteSpace(source)?"本地导入："+draft.OriginalName:source.Trim(),
                license=string.IsNullOrWhiteSpace(license)?"未注明，原始声明随源文件保留":license.Trim(), sha256=Hash(draft.Original),
                count=draft.Entries.Count, bytes=draft.Original.LongLength, enabled=true };
            if (Configuration.imported.Any(item=>item.sha256==entry.sha256)) throw new IOException("此词库已经导入，可在列表中启用它。");
            System.IO.Directory.CreateDirectory(Path.Combine(DirectoryPath,"imports"));
            Paths.AtomicBytes(ImportedPath(entry,true),draft.Original); Paths.AtomicText(ImportedPath(entry),string.Join("\n",draft.Entries.Select(row=>row.Text+"\t"+row.Code+"\t"+row.Weight.ToString(CultureInfo.InvariantCulture)))+"\n");
            var updated=CopyConfiguration(); updated.imported.Add(entry); return updated;
        }
        static string Quote(string value) { return "\""+value.Replace("\"","\\\"")+"\""; }
        static int RunCompiler(string generation, string user) {
            var info=new ProcessStartInfo(Path.Combine(Paths.App,"RimeQ.Broker.exe"),"--deploy "+Quote(generation)+" "+Quote(user)) { UseShellExecute=false,CreateNoWindow=true,WorkingDirectory=Paths.App };
            var values=new Dictionary<string,string>(); foreach(var key in new[]{"APPDATA","LOCALAPPDATA","SystemRoot","TEMP","TMP","USERPROFILE","WINDIR"}) { var value=Environment.GetEnvironmentVariable(key); if(value!=null) values[key]=value; }
            info.EnvironmentVariables.Clear(); foreach(var pair in values) info.EnvironmentVariables[pair.Key]=pair.Value;
            using(var process=Process.Start(info)) {
                if(!process.WaitForExit(180000)) { try { process.Kill();process.WaitForExit(); } catch { } throw new TimeoutException("词库编译超时，已继续使用原词库。"); }
                return process.ExitCode;
            }
        }
        static void CopyTree(string source,string target) {
            System.IO.Directory.CreateDirectory(target);
            foreach(var directory in System.IO.Directory.GetDirectories(source)) CopyTree(directory,Path.Combine(target,Path.GetFileName(directory)));
            foreach(var file in System.IO.Directory.GetFiles(source)) File.Copy(file,Path.Combine(target,Path.GetFileName(file)),true);
        }
        string BuildGeneration(DictionaryConfiguration config, Action<string> progress) {
            var id=config.generation; var root=Path.Combine(GenerationsPath,id); var data=Path.Combine(root,"data");
            if (System.IO.Directory.Exists(root)) throw new IOException("新的词库资源目录已存在。");
            System.IO.Directory.CreateDirectory(root); File.WriteAllText(Path.Combine(root,".rimeq-generation"),"Rime Q dictionary generation\n",Encoding.UTF8);
            progress("正在准备词库资源…"); CopyTree(Path.Combine(Paths.App,"data"),data);
            System.IO.Directory.CreateDirectory(Path.Combine(root,"runtime")); File.Copy(Path.Combine(Paths.App,"runtime","rime.dll"),Path.Combine(root,"runtime","rime.dll"));
            var tables=new List<string>{"cn_dicts/8105","cn_dicts/base","cn_dicts/ext","cn_dicts/tencent","cn_dicts/others"}.Where(item=>!config.disabled.Contains(item)).ToList();
            foreach(var entry in config.imported.Where(item=>item.enabled)) {
                var resource="q_import_"+entry.id.Replace("-","").ToLowerInvariant();
                var header="---\nname: "+resource+"\nversion: '1'\nsort: by_weight\ncolumns: [text, code, weight]\n...\n";
                Paths.AtomicText(Path.Combine(data,resource+".dict.yaml"),header+File.ReadAllText(ImportedPath(entry),Encoding.UTF8)); tables.Add(resource);
            }
            var original=File.ReadAllText(Path.Combine(data,"rime_ice.dict.yaml"),Encoding.UTF8).Replace("\r\n","\n"); var separator=original.IndexOf("\n...\n",StringComparison.Ordinal);
            if(separator<0) throw new IOException("内置词库文件头损坏。");
            var generated="# Generated by Rime Q; originals and attribution are retained.\n---\nname: rime_ice\nversion: '"+id+"'\nimport_tables:\n"+
                string.Join("\n",tables.Select(item=>"  - "+item))+"\n...\n"+original.Substring(separator+5);
            Paths.AtomicText(Path.Combine(data,"rime_ice.dict.yaml"),generated);
            foreach(var name in new[]{"rime_ice.table.bin","rime_ice.reverse.bin","rime_ice.prism.bin","rime_q.schema.yaml","rime_q_grammar.schema.yaml"}) {
                var path=Path.Combine(data,"build",name); if(File.Exists(path)) File.Delete(path);
            }
            var compiler=Path.Combine(DirectoryPath,"compiler",Guid.NewGuid().ToString());
            try {
                progress("正在编译词库，输入仍使用原配置…"); System.IO.Directory.CreateDirectory(compiler);
                if(RunCompiler(root,compiler)!=0) throw new IOException("词库编译失败，已继续使用原词库。请检查全拼编码和词频。");
                CopyTree(Path.Combine(compiler,"rime","build"),Path.Combine(data,"build"));
            } finally { if(System.IO.Directory.Exists(compiler)) System.IO.Directory.Delete(compiler,true); }
            foreach(var name in new[]{"rime_ice.table.bin","rime_ice.reverse.bin","rime_ice.prism.bin","rime_q.schema.yaml","rime_q_grammar.schema.yaml"})
                if(!File.Exists(Path.Combine(data,"build",name)) || new FileInfo(Path.Combine(data,"build",name)).Length==0) throw new IOException("词库索引不完整："+name);
            Paths.AtomicText(Path.Combine(root,".rimeq-input-config"),BaseFingerprint());
            return id;
        }
        string BaseFingerprint() {
            using(var sha=SHA256.Create()) {
                foreach(var path in new[]{Path.Combine(Paths.App,"dictionaries.json"),Path.Combine(Paths.App,"data","rime_q.schema.yaml"),Path.Combine(Paths.App,"data","rime_q_grammar.schema.yaml"),Path.Combine(Paths.App,"data","rime_ice.dict.yaml"),Path.Combine(Paths.App,"data","lua","q_corrector.lua")}) {
                    var bytes=File.ReadAllBytes(path); sha.TransformBlock(bytes,0,bytes.Length,bytes,0);
                }
                sha.TransformFinalBlock(new byte[0],0,0); return BitConverter.ToString(sha.Hash).Replace("-","").ToLowerInvariant();
            }
        }
        internal bool NeedsRefresh {
            get { try {
                var active=File.Exists(ActivePath)?File.ReadAllText(ActivePath).Trim():null;
                if(!string.Equals(active,Configuration.generation,StringComparison.OrdinalIgnoreCase)) return true;
                return Configuration.generation!=null && (Configuration.disabled.Count>0 || Configuration.imported.Any(item=>item.enabled)) &&
                    (!File.Exists(Path.Combine(GenerationsPath,Configuration.generation,".rimeq-input-config")) || File.ReadAllText(Path.Combine(GenerationsPath,Configuration.generation,".rimeq-input-config")).Trim()!=BaseFingerprint()); }
                catch(IOException) { return true; } catch(UnauthorizedAccessException) { return true; } }
        }
        async Task Activate(string generation) {
            System.IO.Directory.CreateDirectory(DirectoryPath);
            if(generation==null) { if(File.Exists(ActivePath)) File.Delete(ActivePath); }
            else Paths.AtomicText(ActivePath,generation+"\n");
            await RestartBroker();
            var expected=generation ?? ""; if(Paths.Get("ActiveGeneration")!=expected) throw new IOException("输入服务未能切换到新的词库资源。");
        }
        internal async Task Apply(DictionaryConfiguration proposed, Action<string> progress) {
            if(Busy || !ConfigurationReadable) throw new IOException(LoadingError ?? "正在应用词库，请稍候。");
            Validate(proposed); Busy=true; Notify(); var old=CopyConfiguration(); var oldIds=new HashSet<string>(old.imported.Select(item=>item.id)); string generation=null;bool safeToCleanup=true;
            try {
                var next=Json.Deserialize<DictionaryConfiguration>(Json.Serialize(proposed));
                if(next.disabled.Count==0 && !next.imported.Any(item=>item.enabled)) next.generation=null;
                else { next.generation=Guid.NewGuid().ToString(); generation=next.generation; await Task.Run(()=>BuildGeneration(next,progress)); }
                progress(generation==null?"正在恢复内置词库…":"编译完成，正在切换输入资源…");
                try { await Activate(next.generation); }
                catch {
                    try { await Activate(old.generation); } catch { safeToCleanup=false; }
                    throw;
                }
                try { Paths.AtomicText(ManifestPath,Json.Serialize(next)); }
                catch { try { await Activate(old.generation); } catch { safeToCleanup=false; } throw; }
                Configuration=next; LoadingError=null;
                Prune(new HashSet<string>(new[]{old.generation,next.generation}.Where(value=>value!=null),StringComparer.OrdinalIgnoreCase));
            } catch {
                if(safeToCleanup&&generation!=null&&System.IO.Directory.Exists(Path.Combine(GenerationsPath,generation)))System.IO.Directory.Delete(Path.Combine(GenerationsPath,generation),true);
                if(safeToCleanup)foreach(var entry in proposed.imported.Where(item=>!oldIds.Contains(item.id))){foreach(var path in new[]{ImportedPath(entry),ImportedPath(entry,true)})if(File.Exists(path))File.Delete(path);}
                throw;
            } finally { Busy=false; Notify(); }
        }
        internal async Task Restore(Action<string> progress) {
            if(File.Exists(ManifestPath)) File.Copy(ManifestPath,Path.Combine(DirectoryPath,"configuration-backup-"+Guid.NewGuid()+".json"));
            var restored=CopyConfiguration(); restored.disabled.Clear(); foreach(var item in restored.imported) item.enabled=false;
            await Apply(restored,progress);
        }
        void Prune(HashSet<string> keep) {
            if(!System.IO.Directory.Exists(GenerationsPath)) return;
            foreach(var path in System.IO.Directory.GetDirectories(GenerationsPath)) { Guid id; if(Guid.TryParse(Path.GetFileName(path),out id) && !keep.Contains(Path.GetFileName(path))) try { System.IO.Directory.Delete(path,true); } catch(IOException) { } catch(UnauthorizedAccessException) { } }
        }
    }

    internal static class BrokerLifecycle {
        static bool OwnBroker(Process process) { try { return string.Equals(process.MainModule.FileName,Path.Combine(Paths.App,"RimeQ.Broker.exe"),StringComparison.OrdinalIgnoreCase); } catch { return false; } }
        internal static async Task Restart() {
            BrokerState current=null;
            try { current=await Broker.Request(6); } catch (TimeoutException) { } catch (IOException) { }
            if(current!=null && current.Ready && !current.Handled) throw new IOException(current.Message);
            var until=DateTime.UtcNow.AddSeconds(8);
            while(DateTime.UtcNow<until && Process.GetProcessesByName("RimeQ.Broker").Any(OwnBroker)) await Task.Delay(100);
            if(Process.GetProcessesByName("RimeQ.Broker").Any(OwnBroker)) throw new IOException("输入服务未能正常退出，请结束当前输入后重试。");
            Paths.Start("RimeQ.Broker.exe","--serve");
            Exception last=null;
            for(int i=0;i<12;++i) { await Task.Delay(250); try { var state=await Broker.Request(9); if(state.Ready) return; } catch(Exception error) when(error is IOException || error is TimeoutException) { last=error; } }
            throw new IOException("输入服务未能重新启动。",last);
        }
    }
}
