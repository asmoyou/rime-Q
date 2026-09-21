using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;

namespace RimeQ {
    // Actual DeviceSync + Rust helper + librime, all on a synthetic marked root.
    // No production named pipe, installed settings, user dictionary or UI is used.
    internal static class SyncCoordinatorTests {
        internal sealed class CapturedRows {public List<SyncRow> rows {get;set;}}
        static Process engine;
        static int calls,exports;
        static bool failProbe,failAfterApply;
        static string FilePath(string name){return Path.Combine(DeviceSync.Root,"engine",name+".tsv");}
        static void Require(bool condition,string message){if(!condition)throw new Exception(message);}
        static string Response(){string line;while((line=engine.StandardOutput.ReadLine())!=null)if(line.StartsWith("RIMEQ-SYNC-TEST "))return line.Substring(16);throw new IOException("Fixture ended");}
        static void Command(string command){var bytes=System.Text.Encoding.ASCII.GetBytes(command+"\n");engine.StandardInput.BaseStream.Write(bytes,0,bytes.Length);engine.StandardInput.BaseStream.Flush();}
        static BrokerState Send(string command){
            Command(command);var fields=Response().Split('\t');
            return new BrokerState {Ready=true,Handled=fields[0]=="ok",Message=fields.Length>1?fields[1]:""};
        }
        static Task<BrokerState> Request(int command){
            if(command==11)Require(DeviceSync.ProgressText(new SyncStatus {enabled=true}).Contains("正在读取本机学习记录"),"Export stage not observable");
            if(command==12)Require(DeviceSync.ProgressText(new SyncStatus {enabled=true}).Contains("正在写入本机词库"),"Apply stage not observable");
            ++calls;if(command==10&&failProbe)throw new IOException("Synthetic engine failure");
            if(command==11)++exports;
            var result=Send(command==10?"probe":command==11?"export":"apply");
            if(command==12&&failAfterApply)throw new IOException("Synthetic interruption after engine write");
            return Task.FromResult(result);
        }
        static List<SyncRow> Read(){return DeviceSync.ToSync(DictionaryData.Parse(System.IO.File.ReadAllText(FilePath("current"))));}
        static void Write(IEnumerable<SyncRow> rows){
            Require(Send("export").Handled,"Fixture export failed");
            Paths.AtomicText(FilePath("before"),System.IO.File.ReadAllText(FilePath("current")));
            Paths.AtomicText(FilePath("after"),DictionaryData.Format(DeviceSync.FromSync(rows)));
            Require(Send("apply").Handled,"Fixture apply failed");
        }
        static SyncRow Row(string text,string code,int weight=1){return new SyncRow {key=new SyncKey {@namespace="rime_q/full-pinyin/v1",text=text,code=code},weight=weight};}
        static async Task Change(SyncRow row,int? weight){await DeviceSync.Call<object>(new {action="fixture_change",changes=new[]{new {key=row.key,weight=weight}}});}
        static async Task Run(){
            var oldPeer=new SyncMember {self=false,online=false,needs_upgrade=true};
            var statusReason=new SyncStatus {enabled=true,members=new List<SyncMember>{new SyncMember {self=true,online=true},oldPeer}};
            Require(DeviceSync.SuccessSummary(statusReason).Contains("升级")&&DeviceSync.MemberSuccessSummary(oldPeer).Contains("需要升级"),"Missing success time did not explain protocol upgrade");
            oldPeer.needs_upgrade=false;Require(DeviceSync.SuccessSummary(statusReason).Contains("等待其他设备连接"),"Missing success time did not explain offline peer");
            oldPeer.online=true;Require(DeviceSync.SuccessSummary(statusReason).Contains("双方应用确认"),"Missing success time did not explain confirmation");
            statusReason.last_sync_at=1;Require(!DeviceSync.SuccessSummary(statusReason).Contains("尚无"),"Recorded success time was hidden by peer state");
            var stalled=new SyncStatus {enabled=true,progress=new SyncProgress {stage="等待其他设备应用并确认",confirmed=1,total=2,elapsed_seconds=31}};
            Require(DeviceSync.ProgressText(stalled).Contains("等待较久")&&DeviceSync.ProgressText(stalled).Contains("1 / 2"),"Stalled confirmation is not visible");
            stalled.enabled=false;Require(DeviceSync.ProgressText(stalled).StartsWith("已暂停同步"),"Pause was hidden by stale progress");
            var local=Row("合成全拼","ce shi",5);var english=Row("SyntheticEnglish","amazon",17);var abbreviated=Row("合成简码","u",19);
            var seed=new[]{local,english,abbreviated,Row("SyntheticAcronym","NASA",3),Row("SyntheticCase","iPhone",21),Row("SyntheticLong","internationalization",22)};
            Write(seed);
            Paths.Set("SyncStarted","1");DeviceSync.EngineRequest=Request;
            await DeviceSync.Tick(true);
            Require(DeviceSync.LastError==null,"Mixed engine codes blocked capture: "+DeviceSync.LastError);
            var complete=await DeviceSync.Call<CapturedRows>(new {action="fixture_rows"});
            Require(DeviceSync.Same(complete.rows,seed),"Native learning rows were silently excluded or rewritten in sync");
            var status=await DeviceSync.Call<SyncStatus>(new {action="status"});
            Require(status.members.Single(m=>m.self).applied,"Local receipt not applied");
            Require(status.last_sync_at==0&&DeviceSync.SuccessTime(0)=="尚无成功记录","Single-node capture claimed cross-device success");
            Require(Read().Count==6,"Initial capture lost local records");
            var remote=Row("合成远端","yuan duan",7);
            await Change(local,null);await Change(remote,7);await DeviceSync.Tick(true);
            Require(DeviceSync.LastError==null,"Remote apply failed: "+DeviceSync.LastError);
            Require(DeviceSync.Same(Read(),seed.Where(r=>r!=local).Concat(new[]{remote})),"Remote changes lost native data or ignored deletion");
            failProbe=true;await DeviceSync.Tick(true);Require(DeviceSync.LastError!=null,"Synthetic error not reported");int before=calls;
            Require(DeviceSync.ProgressText(status).Contains("同步失败，等待自动重试"),"Retry phase missing");
            await DeviceSync.Tick();await DeviceSync.Tick();Require(calls==before,"Failure retries did not back off");
            failProbe=false;await DeviceSync.Tick(true);Require(calls>before&&DeviceSync.LastError==null,"Manual sync did not bypass backoff or clear stale error");
            // Applied engine data but no receipt: next run acknowledges the complete snapshot.
            await Change(remote,11);failAfterApply=true;await DeviceSync.Tick(true);
            Require(DeviceSync.LastError!=null,"Synthetic write interruption not reported");
            Require((await DeviceSync.Call<SyncJobResult>(new {action="pending_apply"})).job!=null,"Pending recovery missing");
            failAfterApply=false;await DeviceSync.Tick(true);
            Require(DeviceSync.LastError==null&&(await DeviceSync.Call<SyncJobResult>(new {action="pending_apply"})).job==null,"Readback acknowledgement failed");
            Require(Read().Single(r=>r.key.code=="amazon").weight==17&&Read().Single(r=>r.key.code=="u").weight==19,"Recovery changed retained weights");
            // Recovery chooses the complete actual engine state.
            await Change(remote,13);
            await DeviceSync.Call<SyncJobResult>(new {action="capture",rows=Read()});
            Require((await DeviceSync.Call<SyncJobResult>(new {action="pending_apply"})).job!=null,"Recovery fixture job missing");
            await DeviceSync.RecoverLocal();await DeviceSync.Tick(true);
            Require(DeviceSync.LastError==null&&Read().Any(r=>r.key.code=="amazon"),"RecoverLocal rejected or erased engine-only records");
            await Change(english,23);await Change(abbreviated,null);await DeviceSync.Tick(true);
            Require(DeviceSync.LastError==null&&Read().Single(r=>r.key.code=="amazon").weight==23&&!Read().Any(r=>r.key.code=="u"),"Native-code update/deletion did not reach engine");
            Send("begin");before=exports;await DeviceSync.Tick(true);Require(exports==before,"Active composition was exported");
            Require(DeviceSync.ProgressText(status).Contains("等待当前输入结束"),"Input wait phase missing");Send("cancel");
            Console.WriteLine("PASS real coordinator + Rust + librime: complete native codes and case, applied receipt, remote deletion/update, retry backoff, manual retry, interrupted-write recovery, recover-local, active input guard");
        }
        static int Main(string[] args){
            try{
                if(args.Length!=3)return 2;Paths.App=Path.GetFullPath(args[0]);Paths.Root=Path.GetFullPath(args[1]);
                Require(System.IO.File.Exists(Path.Combine(DeviceSync.Root,"isolated-test-only")),"Synthetic service root required");
                var start=new ProcessStartInfo(args[2],"\""+Paths.App+"\" \""+Paths.Root+"\""){UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,RedirectStandardOutput=true};
                engine=Process.Start(start);Require(Response()=="ready","Engine not ready");Run().GetAwaiter().GetResult();return 0;
            }catch(Exception error){Console.Error.WriteLine(error.Message);return 1;}
            finally{if(engine!=null&&!engine.HasExited){Command("quit");if(!engine.WaitForExit(10000))engine.Kill();engine.Dispose();}}
        }
    }
}
