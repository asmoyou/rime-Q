#!/usr/bin/env python3
"""Upgrade two real isolated v1 services in-place, keeping group and learning.

Requires an explicit old binary; never opens installed/user sync storage.
"""
import argparse
from pathlib import Path
import tempfile
from test_lan_sync import Node, pair, until

def row(text,code,weight):
    return {'key':{'namespace':'rime_q/full-pinyin/v1','text':text,'code':code},'weight':weight}

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--old-binary',type=Path,required=True)
    parser.add_argument('--binary',type=Path,required=True)
    args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='rimeq-protocol-upgrade-') as temporary:
        nodes=[]
        try:
            nodes=[Node(args.old_binary.resolve(),Path(temporary)/str(i),f'Synthetic {i}') for i in range(2)]
            assert all(n.call('status')['protocol']==1 for n in nodes)
            nodes[0].call('create',group='Synthetic upgrade',name=nodes[0].name);pair(*nodes)
            legacy=row('SyntheticLegacy','ce shi',7)
            nodes[0].call('capture',rows=[legacy])
            until(lambda:nodes[1].call('status')['rows']==1,'legacy rows not transferred')
            job=nodes[1].call('capture',rows=[])['job'];nodes[1].call('acknowledge',id=job['id'],rows=job['after'])
            ids=[n.call('status')['id'] for n in nodes];group=nodes[0].call('status')['group']
            nodes[0].stop();nodes[0].binary=args.binary.resolve();nodes[0].start()
            nodes[0].call('add_peer',address=nodes[1].address())
            until(lambda:'协议版本不一致' in (nodes[0].call('status')['network_error'] or ''),'missing upgrade guidance')
            learned=[row('SyntheticEnglish','amazon',17),row('SyntheticShort','u',19),row('SyntheticCase','iPhone',23)]
            nodes[0].call('capture',rows=[legacy]+learned)
            assert nodes[1].call('status')['rows']==1,'v2 data leaked to incompatible service'
            nodes[1].stop();nodes[1].binary=args.binary.resolve();nodes[1].start()
            nodes[0].call('add_peer',address=nodes[1].address());nodes[1].call('add_peer',address=nodes[0].address())
            until(lambda:nodes[1].call('status')['rows']==4,'upgrade did not transfer full learning')
            job=nodes[1].call('capture',rows=[legacy])['job'];assert job and len(job['after'])==4
            nodes[1].call('acknowledge',id=job['id'],rows=job['after'])
            until(lambda:all(m['applied'] for m in nodes[0].call('status')['members']),'missing full readback receipt')
            assert [n.call('status')['id'] for n in nodes]==ids
            assert all(n.call('status')['group']==group for n in nodes)
            until(lambda:nodes[0].call('status')['network_error'] is None,'upgrade warning did not clear')
            print('PASS real v1 -> mixed-version guard -> v2 group/identity preservation and complete learned records')
        finally:
            for node in nodes:node.stop()

if __name__=='__main__':main()
