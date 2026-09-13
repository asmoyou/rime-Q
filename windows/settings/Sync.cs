using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace RimeQ {
    internal sealed class SyncKey {public string @namespace {get;set;} public string text {get;set;} public string code {get;set;}}
    internal sealed class SyncRow {public SyncKey key {get;set;} public int weight {get;set;}}
    internal sealed class SyncJob {public string id {get;set;} public List<SyncRow> before {get;set;} public List<SyncRow> after {get;set;}}
    internal sealed class SyncJobResult {public SyncJob job {get;set;}}
    internal sealed class SyncGroup {public string id {get;set;} public string name {get;set;}}
    internal sealed class SyncMember {public string id {get;set;} public string name {get;set;} public bool self {get;set;} public bool removed {get;set;} public bool online {get;set;} public bool applied {get;set;} public long last_seen {get;set;}}
    internal sealed class SyncPending {public string id {get;set;} public string name {get;set;}}
    internal sealed class SyncNearby {public string address {get;set;} public string name {get;set;} public string invite {get;set;}}
    internal sealed class SyncStatus {public string id {get;set;} public SyncGroup group {get;set;} public bool enabled {get;set;} public List<SyncMember> members {get;set;} public List<SyncPending> pending {get;set;} public List<SyncNearby> discovered {get;set;} public int port {get;set;} public bool waiting_input {get;set;} public Dictionary<string,long> version {get;set;} public string network_error {get;set;} public string revision {get;set;} public bool can_remove {get;set;}}
    internal sealed class SyncInvitation {public string invite {get;set;} public string code {get;set;} public int expires_in {get;set;} public int port {get;set;}}
    internal sealed class SyncDescriptor {public string address {get;set;} public string token {get;set;}}
    internal static class DeviceSync {
        internal static string Root {get{return Path.Combine(Paths.Root,"sync");}}
        internal static string LastError {get;private set;}
        internal static string LastState {get;private set;}
        internal static event Action Changed;
        static bool busy,starting;
        static string revision,version;
        static JavaScriptSerializer Json(){return new JavaScriptSerializer {MaxJsonLength=96*1024*1024,RecursionLimit=64};}
        internal static async Task EnsureStarted() {
            if(File.Exists(Path.Combine(Root,"control.json")))try{await Call<SyncStatus>(new {action="status"});return;}catch(IOException){}catch(SocketException){}catch(TimeoutException){}
            if(starting){for(int i=0;i<30&&starting;i++)await Task.Delay(100);return;}
            starting=true;
            try{
                if(!File.Exists(Path.Combine(Paths.App,"RimeQ.Sync.exe")))throw new IOException("同步组件缺失，请安装包含此功能的完整版本。");
                Paths.Start("RimeQ.Sync.exe","serve --root \""+Root+"\"");
                for(int i=0;i<40;i++){await Task.Delay(100);try{await Call<SyncStatus>(new {action="status"});return;}catch(IOException){}catch(SocketException){}catch(TimeoutException){}}
                throw new IOException("同步服务未能启动，请稍后重试。");
            }finally{starting=false;}
        }
        internal static async Task<T> Call<T>(object request) {
            var serializer=Json();var descriptor=serializer.Deserialize<SyncDescriptor>(File.ReadAllText(Path.Combine(Root,"control.json"),Encoding.UTF8));
            var split=descriptor.address.LastIndexOf(':');IPAddress address;
            if(split<1||!IPAddress.TryParse(descriptor.address.Substring(0,split),out address)||!IPAddress.IsLoopback(address))throw new IOException("同步控制地址无效。");
            using(var client=new TcpClient()){
                var connection=client.ConnectAsync(address,int.Parse(descriptor.address.Substring(split+1)));
                if(await Task.WhenAny(connection,Task.Delay(3000))!=connection)throw new TimeoutException("同步服务连接超时。");await connection;
                var operation=Exchange<T>(client.GetStream(),descriptor.token,request,serializer);
                if(await Task.WhenAny(operation,Task.Delay(145000))!=operation)throw new TimeoutException("同步请求超时，请重新添加设备。");return await operation;
            }
        }
        static async Task<T> Exchange<T>(NetworkStream stream,string token,object request,JavaScriptSerializer serializer){
            var bytes=Encoding.UTF8.GetBytes(serializer.Serialize(new {token=token,request=request}));
            if(bytes.Length>96*1024*1024)throw new IOException("个人词库超过同步容量。");
            var length=BitConverter.GetBytes(IPAddress.HostToNetworkOrder(bytes.Length));await stream.WriteAsync(length,0,4);await stream.WriteAsync(bytes,0,bytes.Length);
            await ReadExact(stream,length);int size=IPAddress.NetworkToHostOrder(BitConverter.ToInt32(length,0));if(size<=0||size>96*1024*1024)throw new IOException("同步响应无效。");
            var data=new byte[size];await ReadExact(stream,data);var result=serializer.Deserialize<Dictionary<string,object>>(new UTF8Encoding(false,true).GetString(data));
            if(!result.ContainsKey("ok")||!(bool)result["ok"])throw new IOException(Friendly(result.ContainsKey("error")?Convert.ToString(result["error"]):""));
            return serializer.ConvertToType<T>(result["result"]);
        }
        static async Task ReadExact(Stream stream,byte[] bytes){int offset=0;while(offset<bytes.Length){int count=await stream.ReadAsync(bytes,offset,bytes.Length-offset);if(count==0)throw new EndOfStreamException();offset+=count;}}
        static string Friendly(string message){
            if(message.Contains("pairing")||message.Contains("invitation"))return "配对未完成。请检查六位配对码，并在原设备确认；过期后重新生成邀请。";
            if(message.Contains("removed")||message.Contains("unauthorized"))return "设备已被移除或未获授权，请重新加入同步组。";
            if(message.Contains("only the group creator"))return "请在创建同步组的电脑上移除设备。";
            if(message.Contains("already in a group"))return "这台电脑已加入同步组。";
            if(message.Contains("capacity")||message.Contains("limit"))return "同步数据超过本版限制，请减少单次操作规模或更新版本。";
            return "同步操作未完成，请检查设备状态后重试。";
        }
        internal static List<SyncRow> ToSync(IEnumerable<DictionaryRow> rows){return rows.Select(r=>new SyncRow {key=new SyncKey {@namespace="rime_q/full-pinyin/v1",text=r.Text,code=r.Code.Trim()},weight=r.Weight}).OrderBy(r=>r.key.text,StringComparer.Ordinal).ThenBy(r=>r.key.code,StringComparer.Ordinal).ToList();}
        internal static List<DictionaryRow> FromSync(IEnumerable<SyncRow> rows){return rows.Select(r=>new DictionaryRow {Text=r.key.text,Code=r.key.code,Weight=r.weight}).ToList();}
        internal static bool Same(IEnumerable<SyncRow> left,IEnumerable<SyncRow> right){return left.OrderBy(r=>r.key.text,StringComparer.Ordinal).ThenBy(r=>r.key.code,StringComparer.Ordinal).Select(r=>r.key.text+"\t"+r.key.code+"\t"+r.weight).SequenceEqual(right.OrderBy(r=>r.key.text,StringComparer.Ordinal).ThenBy(r=>r.key.code,StringComparer.Ordinal).Select(r=>r.key.text+"\t"+r.key.code+"\t"+r.weight));}
        internal static async Task Tick(){
            if(busy||Paths.Get("SyncStarted","0")!="1")return;busy=true;
            try{
                await EnsureStarted();var status=await Call<SyncStatus>(new {action="status"});if(!status.enabled||status.group==null)return;
                var probe=await Broker.Request(10);if(!probe.Ready||!probe.Handled){LastState="等待当前输入结束";return;}
                var remote=status.revision;
                if(probe.Message==revision&&remote==version&&!status.waiting_input)return;
                var exported=await Broker.Request(11);if(!exported.Handled){LastState="等待当前输入结束";return;}
                var path=Path.Combine(Root,"engine","current.tsv");var actual=ToSync(DictionaryData.Parse(File.ReadAllText(path,new UTF8Encoding(false,true))));
                var job=(await Call<SyncJobResult>(new {action="pending_apply"})).job;
                if(job!=null&&Same(actual,job.after)){await Call<object>(new {action="acknowledge",id=job.id,rows=actual});job=null;}
                if(job==null)job=(await Call<SyncJobResult>(new {action="capture",rows=actual})).job;
                if(job!=null){
                    if(!Same(actual,job.before))throw new IOException("同步恢复期间词库已有新修改。已保留本机记录和恢复快照，请在同步页面处理。");
                    Paths.AtomicText(Path.Combine(Root,"engine","before.tsv"),DictionaryData.Format(FromSync(actual)));
                    Paths.AtomicText(Path.Combine(Root,"engine","after.tsv"),DictionaryData.Format(FromSync(job.after)));
                    var applied=await Broker.Request(12);
                    if(!applied.Handled){if(applied.Message=="sync-stale"){await Call<object>(new {action="abort_unapplied",id=job.id});revision=null;return;}if(applied.Message=="sync-busy"){LastState="等待当前输入结束";return;}throw new IOException("同步写入未能完整完成，已保留备份，将在下次检查时恢复。");}
                    actual=ToSync(DictionaryData.Parse(File.ReadAllText(path,new UTF8Encoding(false,true))));
                    await Call<object>(new {action="acknowledge",id=job.id,rows=actual});revision=applied.Message;
                }else revision=exported.Message;
                version=remote;LastError=null;LastState="本机词库已同步";
            }catch(Exception error){LastError=error.Message;LastState="同步等待处理";}finally{busy=false;if(Changed!=null)Changed();}
        }
        internal static async Task RecoverLocal(){
            if(busy)throw new IOException("正在同步，请稍后重试。");busy=true;
            try{
                var job=(await Call<SyncJobResult>(new {action="pending_apply"})).job;
                if(job==null)return;
                var exported=await Broker.Request(11);if(!exported.Handled)throw new IOException("请结束当前输入后重试。");
                var actual=ToSync(DictionaryData.Parse(File.ReadAllText(Path.Combine(Root,"engine","current.tsv"),new UTF8Encoding(false,true))));
                var backup=Path.Combine(Root,"backups");Directory.CreateDirectory(backup);var tag=Guid.NewGuid().ToString("N");
                Paths.AtomicText(Path.Combine(backup,"recovery-local-"+tag+".tsv"),DictionaryData.Format(FromSync(actual)));
                Paths.AtomicText(Path.Combine(backup,"recovery-target-"+tag+".tsv"),DictionaryData.Format(FromSync(job.after)));
                await Call<object>(new {action="recover_local",id=job.id,rows=actual});revision=null;version=null;LastError=null;
            }finally{busy=false;}
        }
        internal static async Task Leave(){
            Paths.Set("SyncStarted","0");while(busy)await Task.Delay(100);
            try{await Call<object>(new {action="leave"});revision=null;version=null;LastError=null;}
            catch{Paths.Set("SyncStarted","1");throw;}
        }
        internal static void Stop(){try{Task.Run(()=>Call<object>(new {action="shutdown"})).Wait(1500);}catch(Exception){}}
    }
}
