"""Exercise the distributed Windows CPU engines with non-private fixture audio."""
import argparse
import base64
import json
from pathlib import Path
import subprocess
import time
import urllib.request
import wave


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--data-dir', type=Path, required=True)
    parser.add_argument('--result', type=Path, required=True)
    args = parser.parse_args()
    bundle = args.bundle.resolve()
    data = args.data_dir.resolve()
    # The caller downloads models into a dedicated, disposable CI directory.
    # The service writes Prompt metadata here, never the user's normal store.
    port = 18767
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    checks = []
    def request(route, payload=None, headers=None):
        req = urllib.request.Request(f'http://127.0.0.1:{port}'+route, data=payload, headers=headers or {})
        with opener.open(req, timeout=240) as response:
            return json.load(response)
    log = args.result.with_suffix('.log')
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open('w', encoding='utf-8') as output:
        child = subprocess.Popen([str(bundle/'runtime/python/python.exe'), '-B',
            str(bundle/'backend/windows_server.py'), '--data-dir', str(data), '--port', str(port),
            '--llama-server', str(bundle/'runtime/llama/llama-server.exe'), '--parent-pid', str(__import__('os').getpid())],
            stdout=output, stderr=output, creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
        try:
            deadline = time.monotonic()+180
            while time.monotonic()<deadline:
                if child.poll() is not None: raise RuntimeError('Packaged backend exited during load')
                try:
                    health=request('/health')
                    if health.get('cleanup_ready') and health.get('asr_ready'): break
                except (OSError,ValueError): pass
                time.sleep(.5)
            else: raise TimeoutError('Production models did not load')
            checks.append('production_asr_and_cleanup_ready')
            wav = Path(__file__).parent/'fixtures/chinese.wav'
            with wave.open(str(wav)) as audio:
                assert audio.getframerate()==16000 and audio.getnchannels()==1 and audio.getsampwidth()==2
            options={'language':'zh','cleanup':True,'vocabulary':['订单','工单','交期甘特图']}
            headers={'Content-Type':'audio/wav','X-Dictation-Options':base64.b64encode(json.dumps(options,ensure_ascii=False).encode()).decode()}
            started=time.monotonic();result=request('/dictate',wav.read_bytes(),headers);elapsed=time.monotonic()-started
            assert result['raw_text'].strip() and result['text'].strip(), 'Empty real inference'
            assert result['cleanup_applied'],result.get('warning','cleanup not applied')
            # Semantic checks are acceptance fixtures, never product replacements.
            normalized=result['text'].replace('訂','订').replace('單','单').replace('試','试').replace('發','发').replace('佈','布')
            assert '订单' in normalized and '工单' in normalized and '测试' in normalized, normalized
            assert '不要' in normalized or '不直接' in normalized or '别直接' in normalized, normalized
            assert not normalized.lstrip().startswith('{"text"'), 'Wire envelope escaped into final text'
            checks.append('real_chinese_audio_to_final_text')
            # A dictated request must remain a request; JSON-like material and
            # labels belong to the speaker and must not be stripped by keywords.
            raw='请保留标题“修正说明”和代码 `x < 2`。这只是个建议，先别发布。'
            profile=health['active_prompt_version_id']
            edited=request('/cleanup/reprocess',json.dumps({'raw_text':raw},ensure_ascii=False).encode(),
                {'Content-Type':'application/json','X-Cleanup-Prompt-Version':profile})
            assert edited['cleanup_applied'] and '修正说明' in edited['text'] and '`x < 2`' in edited['text'], edited
            assert '别发布' in edited['text'] or '不要发布' in edited['text'], edited
            checks.append('real_cleanup_preserves_quotes_code_and_negation')
            report={'success':True,'checks':checks,'models':health['models'],'audio_result':result,
                    'cleanup_result':edited,'wall_seconds':elapsed,'microphone_used':False,
                    'fixture':'synthetic Chinese speech; no user transcript'}
            args.result.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
            print(json.dumps(report,ensure_ascii=False))
        except Exception as error:
            args.result.write_text(json.dumps({'success':False,'checks':checks,'error':str(error)},ensure_ascii=False,indent=2),encoding='utf-8')
            raise
        finally:
            if child.poll() is None:
                child.terminate()
                try: child.wait(timeout=10)
                except subprocess.TimeoutExpired: child.kill();child.wait()

if __name__=='__main__': main()
