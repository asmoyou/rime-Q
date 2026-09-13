#!/usr/bin/env python3
"""End-to-end TLS group -> six independent real librime processes -> readback."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import time
from test_lan_sync import Node, pair, until


def tsv(rows):
    return '# synthetic Rime Q validation\n'+''.join(f'{r["key"]["text"]}\t{r["key"]["code"]}\t{r["weight"]}\n' for r in rows)


def read(path):
    rows=[]
    for line in path.read_text(encoding='utf-8').splitlines():
        if not line or line.startswith('#'):continue
        text,code,weight=line.split('\t')
        if int(weight)>=0:rows.append({'key':{'namespace':'rime_q/full-pinyin/v1','text':text,'code':code.strip()},'weight':int(weight)})
    return sorted(rows,key=lambda r:(r['key']['text'],r['key']['code']))


class Engine:
    def __init__(self,binary,app,root):
        self.root=root
        self.process=subprocess.Popen([str(binary),str(app),str(root)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,encoding='utf-8',creationflags=subprocess.CREATE_NO_WINDOW)
        assert self.response()=='ready','engine failed to initialize'
    def response(self):
        while True:
            line=self.process.stdout.readline()
            if not line:raise RuntimeError('isolated native engine terminated')
            if line.startswith('RIMEQ-SYNC-TEST '):return line[len('RIMEQ-SYNC-TEST '):].strip()
    def call(self,command):
        self.process.stdin.write(command+'\n');self.process.stdin.flush();return self.response()
    def rows(self):
        result=self.call('export')
        if not result.startswith('ok'):raise RuntimeError('engine export blocked')
        return read(self.root/'sync/engine/current.tsv')
    def apply(self,after):
        before=self.rows();directory=self.root/'sync/engine'
        (directory/'before.tsv').write_text(tsv(before),encoding='utf-8')
        (directory/'after.tsv').write_text(tsv(after),encoding='utf-8')
        assert self.call('apply').startswith('ok'),'engine application failed'
        return self.rows()
    def stop(self):
        if self.process.poll() is None:
            self.process.stdin.write('quit\n');self.process.stdin.flush()
            try:self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:self.process.kill();self.process.wait(timeout=5)


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--binary',type=Path,required=True)
    parser.add_argument('--native',type=Path,required=True)
    parser.add_argument('--app',type=Path,required=True)
    parser.add_argument('--output',type=Path,default=Path('artifacts/lan-sync-native-report.json'))
    args=parser.parse_args();nodes=[];engines=[];cases=[];started=time.monotonic();failure=None
    try:
        with tempfile.TemporaryDirectory(prefix='rimeq-sync-native-') as temporary:
            try:
                for i in range(6):
                    root=Path(temporary)/str(i);root.mkdir()
                    nodes.append(Node(args.binary.resolve(),root/'sync',f'Native device {i}'))
                    engines.append(Engine(args.native.resolve(),args.app.resolve(),root))
                nodes[0].call('create',group='Native isolated verification',name=nodes[0].name)
                for node in nodes[1:]:pair(nodes[0],node)
                def step(i):
                    if not nodes[i].call('status')['enabled']:return
                    actual=engines[i].rows();job=nodes[i].call('pending_apply')['job']
                    if job is None:job=nodes[i].call('capture',rows=actual)['job']
                    if job is not None:
                        after=engines[i].apply(job['after'])
                        nodes[i].call('acknowledge',id=job['id'],rows=after)
                def converge(check,indices=range(6)):
                    deadline=time.monotonic()+60
                    while time.monotonic()<deadline:
                        for i in indices:step(i)
                        if all(check(engines[i].rows()) for i in indices):return
                        time.sleep(.2)
                    raise AssertionError('native engines did not converge')
                for i,engine in enumerate(engines):
                    engine.apply([{'key':{'namespace':'rime_q/full-pinyin/v1','text':f'组网词条{i}','code':'ce shi'},'weight':i+1}])
                    step(i)
                converge(lambda rows:len(rows)==6)
                cases.append('six_real_engines_import_capture_tls_apply_readback')
                until(lambda:all(m['applied'] for m in nodes[0].call('status')['members']),'applied receipts did not propagate',60)
                cases.append('every_device_receipt_confirms_real_engine_application')
                nodes[-1].call('pause')
                offline=engines[-1].rows();offline[0]['weight']=900;engines[-1].apply(offline)
                remaining=engines[0].rows()[1:];engines[0].apply(remaining);step(0)
                converge(lambda rows:len(rows)==5,range(5))
                nodes[-1].call('resume')
                until(lambda:len(nodes[-1].call('fixture_rows')['rows'])==5,'helper deletion did not arrive',60)
                converge(lambda rows:len(rows)==5)
                cases.append('offline_engine_learning_does_not_resurrect_received_deletion')
                extra={'key':{'namespace':'rime_q/full-pinyin/v1','text':'输入保护','code':'shu ru bao hu'},'weight':2}
                engines[1].apply(engines[1].rows()+[extra]);step(1)
                engines[-1].call('begin')
                until(lambda:len(nodes[-1].call('fixture_rows')['rows'])==6,'remote update not received during composition',60)
                assert engines[-1].call('export').startswith('blocked'),'active composition was not protected'
                engines[-1].call('cancel');converge(lambda rows:len(rows)==6)
                cases.append('receive_during_composition_apply_after_cancel')
                for i,engine in enumerate(engines):
                    expected=engine.rows();engine.stop();engines[i]=Engine(args.native.resolve(),args.app.resolve(),engine.root)
                    assert engines[i].rows()==expected
                cases.append('six_actual_dictionary_restarts_preserve_synced_data')
            finally:
                for engine in engines:engine.stop()
                for node in nodes:node.stop()
    except Exception as error:failure=str(error);raise
    finally:
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(json.dumps({'kind':'six_native_librime_processes_with_real_tls','nodes':6,'passed':cases,'failure':failure,'seconds':round(time.monotonic()-started,2)},ensure_ascii=False,indent=2),encoding='utf-8')
        print('PASS '+str(len(cases))+' native end-to-end scenarios' if failure is None else 'FAIL native end-to-end verification')


if __name__=='__main__':main()
