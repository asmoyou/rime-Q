#!/usr/bin/env python3
"""Six real Swift adapters/librime engines, isolated roots, authenticated TLS.

Uses an independently identified preview bundle; never the installed input source.
No pairing credentials or dictionary content are included in the report.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import queue
import shutil
import subprocess
import tempfile
import threading
import time
from test_lan_sync import Node, pair, until


def row(text, code='ce shi', weight=1):
    return {'key': {'namespace': 'rime_q/full-pinyin/v1', 'text': text, 'code': code}, 'weight': weight}


class Engine:
    def __init__(self, binary, root):
        self.binary, self.root = binary, root
        self.messages = queue.Queue()
        env = {k: v for k, v in os.environ.items() if k in {'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'PATH', 'LANG'}}
        self.process = subprocess.Popen([str(binary), '--sync-test-node', str(root)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, encoding='utf-8', env=env)
        def read():
            for line in self.process.stdout:
                if line.startswith('RIMEQ-SYNC-TEST '):
                    self.messages.put(json.loads(line.removeprefix('RIMEQ-SYNC-TEST ')))
            self.messages.put({'ok': False, 'error': 'native engine terminated'})
        threading.Thread(target=read, daemon=True).start()
        try:
            assert self.messages.get(timeout=60).get('ready'), 'native engine did not initialize'
        except BaseException:
            self.stop(crash=True)
            raise

    def call(self, action, **values):
        self.process.stdin.write(json.dumps({'action': action, **values}, ensure_ascii=False) + '\n')
        self.process.stdin.flush()
        response = self.messages.get(timeout=160)
        if not response.get('ok'):
            raise RuntimeError(response.get('error', 'native command failed'))
        return response['result']

    def rows(self):
        return sorted(self.call('rows')['rows'], key=lambda r: (r['key']['text'], r['key']['code']))

    def replace(self, rows):
        self.call('replace', rows=rows)

    def tick(self):
        result = self.call('tick')
        assert result['error'] is None, result['error']
        return result

    def stop(self, crash=False):
        if self.process.poll() is None:
            if crash:
                self.process.kill()
            else:
                try:
                    self.process.stdin.write('{"action":"quit"}\n'); self.process.stdin.flush()
                except (BrokenPipeError, OSError):
                    self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill(); self.process.wait(timeout=5)
        self.process.stdin.close(); self.process.stdout.close()


class Cases(list):
    def append(self, value):
        super().append(value)
        print('PASS ' + value, flush=True)


def run(binary, output):
    nodes, engines, cases = [], [], Cases()
    started = time.monotonic()
    failure = None
    try:
        with tempfile.TemporaryDirectory(prefix='rimeq-mac-sync-') as temporary:
            root = Path(temporary)
            (root / 'mac-sync-test-only').touch()
            try:
                invalid = root / 'invalid-parent'
                rejected = subprocess.run([str(binary.parent / 'RimeQ.Sync'), 'serve', '--root', str(invalid),
                    '--isolated', '--no-discovery', '--bind', '127.0.0.1', '--parent-pid', '1'],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
                assert rejected.returncode != 0 and not (invalid / 'state.sqlite').exists()
                cases.append('unrelated_parent_pid_rejected_before_state_access')
                # Default-off adapter must not even create a helper/control file.
                first = root / 'node-0'; first.mkdir()
                engines.append(Engine(binary, first))
                assert not engines[0].call('disabled')['control_exists']
                cases.append('default_off_no_helper_or_dictionary_scan')
                engines[0].call('startup_ui')
                cases.append('unused_page_no_identity_and_failed_start_requires_explicit_retry')
                for i in range(6):
                    directory = root / f'node-{i}'; directory.mkdir(exist_ok=True)
                    nodes.append(Node(binary.parent / 'RimeQ.Sync', directory / 'sync', f'Mac test {i}'))
                    if i:
                        engines.append(Engine(binary, directory))
                nodes[0].call('create', group='Mac native validation', name=nodes[0].name)
                for i in range(1, 6):
                    pair(nodes[i-1], nodes[i])  # Non-founder invitations, relay topology.
                def converge(expected, indices=range(6)):
                    def step():
                        for i in indices:
                            nodes[i].call('sync_now'); engines[i].tick()
                        return all(engines[i].rows() == sorted(expected, key=lambda r: (r['key']['text'], r['key']['code'])) for i in indices)
                    until(step, 'native adapters did not converge', 90)
                expected = [row('原生组网' + text, 'yuan sheng zu wang ' + code, i+1) for i, (text, code) in enumerate(zip('甲乙丙丁戊己', ['jia', 'yi', 'bing', 'ding', 'wu', 'ji']))]
                for i, engine in enumerate(engines):
                    engine.replace([expected[i]]); engine.tick()
                converge(expected)
                cases.append('six_swift_adapters_real_librime_tls_nonfounder_invitations')
                until(lambda: all(m['applied'] for m in nodes[0].call('status')['members']), 'missing signed engine receipts', 60)
                cases.append('six_signed_readback_receipts')
                engines[0].call('ui')
                # This loopback harness deliberately disables mDNS. Refresh the
                # changed listener address after resume, as discovery does on LAN.
                nodes[1].call('add_peer', address=nodes[0].address())
                output.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(engines[0].root / 'sync-window.png', output.parent / 'macos-sync-window.png')
                cases.append('native_window_search_stable_rows_pause_resume_and_join_cancellation')
                assert '原生组网甲' in engines[0].call('candidates', code='yuanshengzuwangjia')['candidates'], 'synced phrase missing from full-pinyin candidates'
                cases.append('synced_word_recalled_in_real_candidates')

                # Old local learning must not resurrect a deletion merely received by the helper.
                nodes[-1].call('pause')
                stale = engines[-1].rows(); stale[0]['weight'] = 900; engines[-1].replace(stale)
                expected = engines[0].rows()[1:]; engines[0].replace(expected); engines[0].tick()
                converge(expected, range(5))
                nodes[-1].call('resume')
                until(lambda: nodes[-1].call('status')['rows'] == 5, 'deletion not received', 60)
                converge(expected)
                cases.append('received_deletion_blocks_unapplied_old_learning')
                renewed = dict(stale[0], weight=3)
                expected.append(renewed); engines[-1].replace(expected); engines[-1].tick(); converge(expected)
                cases.append('learning_after_applied_deletion_starts_new_generation')

                # Decreasing a weight requires librime deletion followed by restoration.
                expected[0]['weight'] = 1; engines[0].replace(expected); engines[0].tick(); converge(expected)
                cases.append('explicit_weight_reduction')
                extra = row('输入保护', 'shu ru bao hu', 2)
                engines[-1].call('begin')
                expected.append(extra); engines[0].replace(expected); engines[0].tick()
                until(lambda: nodes[-1].call('status')['rows'] == len(expected), 'update not received during input', 60)
                result = engines[-1].tick()
                assert result['composition'] and result['document'] == ''
                engines[-1].call('cancel'); converge(expected)
                cases.append('active_composition_not_committed_or_overwritten')

                # Insert a real composition during the capture IPC suspension.
                extra = row('异步组合', 'yi bu zu he', 2)
                expected.append(extra); engines[0].replace(expected); engines[0].tick()
                until(lambda: nodes[-1].call('status')['rows'] == len(expected), 'hook update not received', 60)
                engines[-1].call('hook', after='capture', effect='begin')
                result = engines[-1].tick(); assert result['composition'] and result['document'] == ''
                assert nodes[-1].call('pending_apply')['job'] is not None
                engines[-1].call('cancel'); converge(expected)
                cases.append('composition_started_during_capture_await_defers_write')

                extra = row('异步基线', 'yi bu ji xian', 2)
                expected.append(extra); engines[0].replace(expected); engines[0].tick()
                until(lambda: nodes[-1].call('status')['rows'] == len(expected), 'stale update not received', 60)
                engines[-1].call('hook', after='capture', effect='learn'); engines[-1].tick()
                assert nodes[-1].call('pending_apply')['job'] is None, 'stale application was not aborted'
                expected.append(row('异步学习', 'yi bu xue xi', 7)); converge(expected)
                cases.append('learning_during_await_rejects_stale_snapshot_without_loss')

                backup = engines[-1].root / 'lexicon-backups/before-last-change.tsv'
                manual_backup = backup.read_bytes()
                engines[-1].call('english')
                extra = row('英文保持', 'ying wen bao chi', 2)
                expected.append(extra); engines[0].replace(expected); engines[0].tick(); converge(expected)
                assert engines[-1].call('type', text='abc')['document'] == 'abc'
                engines[-1].call('english')
                assert backup.read_bytes() == manual_backup
                cases.append('ascii_mode_and_manual_undo_backup_preserved')
                engines[-1].call('undo')
                assert all(r['key']['text'] != '异步学习' for r in engines[-1].rows()), 'background sync broke manual undo'
                engines[-1].replace(expected); engines[-1].tick(); converge(expected)
                cases.append('manual_undo_remains_usable_after_background_sync')

                # Pending application survives native process death before importing.
                extra = row('中断恢复', 'zhong duan hui fu', 2)
                expected.append(extra); engines[0].replace(expected); engines[0].tick()
                until(lambda: nodes[-1].call('status')['rows'] == len(expected), 'recovery update missing', 60)
                engines[-1].call('hook', after='capture', effect='fail')
                assert engines[-1].call('tick')['error'] is not None
                assert nodes[-1].call('pending_apply')['job'] is not None
                engines[-1].stop(crash=True); engines[-1] = Engine(binary, engines[-1].root)
                converge(expected)
                cases.append('native_crash_before_import_resumes_pending_application')

                # Real engine write completed but acknowledgement was not observed.
                extra = row('回执恢复', 'hui zhi hui fu', 2)
                expected.append(extra); engines[0].replace(expected); engines[0].tick()
                until(lambda: nodes[-1].call('status')['rows'] == len(expected), 'ack update missing', 60)
                engines[-1].call('hook', after='acknowledge', effect='fail', before=True)
                assert engines[-1].call('tick')['error'] is not None
                engines[-1].stop(crash=True); engines[-1] = Engine(binary, engines[-1].root)
                engines[-1].call('hook', after='acknowledge', effect='learn_again')
                expected = [dict(r, weight=11) if r['key']['text'] == '异步学习' else r for r in expected]
                converge(expected)
                cases.append('native_crash_after_engine_import_before_ack_resumes_idempotently')
                # Backup failure must stop before the real engine can be modified.
                extra = row('备份保护', 'bei fen bao hu', 2)
                expected.append(extra); engines[0].replace(expected); engines[0].tick()
                until(lambda: nodes[-1].call('status')['rows'] == len(expected), 'backup update missing', 60)
                before = engines[-1].rows()
                backups = engines[-1].root / 'sync/backups'
                saved = engines[-1].root / 'sync/backups-saved'
                backups.rename(saved)
                try:
                    backups.write_text('synthetic unavailable backup directory')
                    assert engines[-1].call('tick')['error'] is not None
                    assert engines[-1].rows() == before, 'engine changed despite failed backup'
                    assert nodes[-1].call('pending_apply')['job'] is not None
                finally:
                    backups.unlink(); saved.rename(backups)
                converge(expected)
                cases.append('backup_write_failure_preserves_engine_and_retries_pending_job')

                # A pending job plus a different actual dictionary must stop automatic writes.
                extra = row('冲突恢复', 'chong tu hui fu', 2)
                expected.append(extra); engines[0].replace(expected); engines[0].tick()
                until(lambda: nodes[-1].call('status')['rows'] == len(expected), 'conflict update missing', 60)
                engines[-1].call('hook', after='capture', effect='fail')
                assert engines[-1].call('tick')['error'] is not None
                local = engines[-1].rows() + [row('本机保留', 'ben ji bao liu', 5)]
                engines[-1].replace(local)
                assert engines[-1].call('tick')['error'] is not None
                assert engines[-1].rows() == sorted(local, key=lambda r: (r['key']['text'], r['key']['code']))
                engines[-1].call('recover')
                backups = engines[-1].root / 'sync/backups'
                assert len(list(backups.glob('recovery-local-*.tsv'))) == 1
                assert len(list(backups.glob('recovery-target-*.tsv'))) == 1
                expected = local; converge(expected)
                cases.append('conflicting_recovery_pauses_and_preserves_both_snapshots')

                # Restart the actual service; Swift must notice and resume its persisted group.
                nodes[-1].stop(crash=True)
                engines[-1].tick()
                assert nodes[-1].call('status')['group'] is not None
                for node in nodes[:-1]: node.call('add_peer', address=nodes[-1].address())
                converge(expected)
                cases.append('swift_restarts_failed_helper_with_persisted_identity')
                engines[-1].stop(crash=True)
                until(lambda: not (engines[-1].root / 'sync/control.json').exists(), 'helper survived its native parent', 10)
                engines[-1] = Engine(binary, engines[-1].root)
                engines[-1].tick()
                nodes[-2].call('add_peer', address=nodes[-1].address())
                converge(expected)
                cases.append('helper_exits_after_native_parent_crash_and_restarts_cleanly')
                for i, engine in enumerate(engines):
                    before = engine.rows(); engine.stop(); engines[i] = Engine(binary, engine.root)
                    assert engines[i].rows() == before
                    assert engines[i].call('preference')['started'], 'enabled preference was lost across restart'
                engines[-1].tick()
                nodes[-2].call('add_peer', address=nodes[-1].address())
                converge(expected)
                cases.append('six_engine_restarts_preserve_dictionary_and_group')
                before = engines[-1].rows()
                engines[-1].call('leave')
                assert engines[-1].rows() == before
                assert list((engines[-1].root / 'sync/archives').glob('state-*.sqlite'))
                cases.append('native_leave_preserves_dictionary_and_archives_sync_state')
            finally:
                for engine in engines: engine.stop()
                for node in nodes: node.stop()
                for directory in root.glob('node-*'):
                    suite = 'com.asmoyou.rimeq.sync-test.' + root.name + '.' + directory.name
                    subprocess.run(['defaults', 'delete', suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
                    # macOS can retain an empty plist after deleting a domain.
                    preference = Path.home() / 'Library/Preferences' / (suite + '.plist')
                    if preference.exists() and plistlib.loads(preference.read_bytes()) == {}:
                        preference.unlink()
    except Exception as error:
        failure = str(error) or type(error).__name__
        raise
    finally:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps({'kind': 'six_mac_swift_adapters_real_librime_tls_loopback', 'nodes': 6,
            'os': platform.mac_ver()[0], 'architecture': platform.machine(), 'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            'passed': cases, 'failure': failure, 'seconds': round(time.monotonic()-started, 2)}, ensure_ascii=False, indent=2) + '\n')
        print(f'{"PASS" if failure is None else "FAIL"} {len(cases)} Mac native sync scenarios', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--output', type=Path, default=Path('artifacts/lan-sync-macos-native-report.json'))
    args = parser.parse_args()
    from build_macos import isolated_smoke_app
    with isolated_smoke_app(args.app.resolve()) as preview:
        run(preview / 'Contents/MacOS/RimeQ', args.output)
