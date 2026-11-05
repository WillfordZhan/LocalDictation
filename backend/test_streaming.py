"""CPU-only protocol and scheduling tests; no model imports or GPU calls."""
import ast
import base64
from concurrent.futures import ThreadPoolExecutor
import http.client
import json
from pathlib import Path
import threading
import time
import unittest
import uuid
from unittest.mock import Mock, patch
from types import SimpleNamespace
import numpy as np
from server import DictationOptions, DictationService, LocalModels, Recording, RequestError, make_handler
from streaming import IDLE_TIMEOUT, MAX_SESSIONS, RESULT_RETENTION, SAMPLE_RATE, next_cut
from http.server import ThreadingHTTPServer


def pcm(seconds, amplitude=700):
    return np.full(round(seconds*SAMPLE_RATE), amplitude, dtype='<i2').tobytes()


def wait_for(predicate, seconds=3):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        if predicate(): return
        time.sleep(.005)
    raise AssertionError('Expected state not reached')


class Models:
    asr_path=Path('Qwen3-ASR-test')
    cleanup_path=Path('Qwen3-test-editor')
    asr_ready=True
    cleanup_ready=True
    message='ready'

    def __init__(self):
        self.asr_calls=[];self.cleanup_calls=[];self.threads=[]
        self.asr_entered=threading.Event();self.edit_entered=threading.Event()
        self.asr_release=threading.Event();self.edit_release=threading.Event()
        self.asr_release.set();self.edit_release.set();self.failure=None

    def load(self): self.threads.append(threading.get_ident())

    def transcribe_segment(self, recording, options, max_tokens):
        self.threads.append(threading.get_ident())
        self.asr_calls.append((recording,options,max_tokens));self.asr_entered.set()
        if not self.asr_release.wait(3): raise TimeoutError('test release missing')
        if self.failure: raise self.failure
        return f'片段{len(self.asr_calls)}',10

    def transcribe(self, recording, options):
        return self.transcribe_segment(recording,options,8192)[0]

    def cleanup(self, text, options):
        self.threads.append(threading.get_ident())
        self.cleanup_calls.append((text,options));self.edit_entered.set()
        if not self.edit_release.wait(3): raise TimeoutError('test release missing')
        return '整理：'+text


class StreamHTTPTests(unittest.TestCase):
    def setUp(self):
        self.models=Models()
        self.service=DictationService(self.models,memory_only_prompts=True)
        self.service.load_complete=True
        self.server=ThreadingHTTPServer(('127.0.0.1',0),make_handler(self.service))
        self.server.daemon_threads=True
        self.thread=threading.Thread(target=self.server.serve_forever,kwargs={'poll_interval':.01},daemon=True)
        self.thread.start();self.requests=ThreadPoolExecutor(max_workers=4)

    def tearDown(self):
        self.models.asr_release.set();self.models.edit_release.set();self.service.streams.close()
        self.requests.shutdown(wait=True)
        self.server.shutdown();self.server.server_close();self.thread.join()
        self.service.worker.shutdown(wait=True)

    def request(self, method, path, value=None, headers=None):
        headers=dict(headers or {})
        if isinstance(value,(dict,list)):
            value=json.dumps(value).encode();headers.setdefault('Content-Type','application/json')
        client=http.client.HTTPConnection(*self.server.server_address,timeout=5)
        client.request(method,path,value,headers)
        response=client.getresponse();result=response.status,json.loads(response.read());client.close()
        return result

    def start(self, sid=None, options=None, version=None):
        sid=sid or str(uuid.uuid4());headers={}
        if options is not None: headers['X-Dictation-Options']=base64.b64encode(json.dumps(options).encode()).decode()
        if version is not None: headers['X-Cleanup-Prompt-Version']=version
        status,value=self.request('POST','/stream/start',{'session_id':sid},headers)
        self.assertEqual(status,200,value);return sid

    def append(self, sid, data, offset=0):
        return self.request('POST',f'/stream/{sid}/audio',data,
                            {'Content-Type':'application/octet-stream','X-Audio-Offset':str(offset)})

    def finish(self, sid, samples):
        return self.request('POST',f'/stream/{sid}/finish',{'total_samples':samples})

    def snapshot(self,sid): return self.request('GET',f'/stream/{sid}')[1]

    def test_health_admits_next_recording_but_prevents_model_replacement(self):
        before=self.request('GET','/health')[1]
        self.assertTrue(before['supports_streaming'] and before['accepts_streaming'])
        sid=self.start();health=self.request('GET','/health')[1]
        self.assertTrue(health['busy'] and health['accepts_streaming']);self.assertEqual(health['active_streams'],1)
        self.request('POST',f'/stream/{sid}/cancel',{})
        self.assertFalse(self.request('GET','/health')[1]['busy'])

    def test_short_recording_finishes_once_with_all_legacy_fields(self):
        sid=self.start();data=pcm(.2);self.assertEqual(self.append(sid,data)[0],200)
        self.assertEqual(self.models.asr_calls,[])
        status,result=self.finish(sid,len(data)//2);self.assertEqual(status,200)
        self.assertEqual(result['raw_text'],'片段1');self.assertEqual(result['text'],'整理：片段1')
        self.assertTrue(result['cleanup_applied'])
        for key in ('audio_seconds','asr_seconds','cleanup_seconds','total_seconds','asr_model','cleanup_profile'):
            self.assertIn(key,result)
        self.assertEqual(result['streaming_metrics']['asr_calls'],1)
        self.assertEqual(result['streaming_metrics']['processed_audio_before_stop_seconds'],0)
        self.assertEqual(len(self.models.cleanup_calls),1);self.assertEqual(self.snapshot(sid)['state'],'completed')

    def test_real_adapter_skips_nonzero_noise_tail_without_losing_audio_coverage(self):
        models=LocalModels(Path('asr'),Path('cleanup'),asr_backend='qwen')
        models.asr_ready=True;models.asr_model=Mock()
        models.asr_model.generate.side_effect=lambda samples,**kwargs: SimpleNamespace(
            text='正文完整保留。',generation_tokens=8,segments=[{'end':len(samples)/SAMPLE_RATE}])
        self.service.models=models
        rng=np.random.default_rng(54)
        tone=(3000*np.sin(np.arange(25*SAMPLE_RATE)*2*np.pi/80)).astype('<i2')
        noise=rng.integers(-20,21,size=round(9.3*SAMPLE_RATE),dtype='<i2')
        data=np.concatenate((tone,noise)).astype('<i2').tobytes()
        sid=self.start(options={'cleanup':False,'vocabulary':['FixtureAlpha','FixtureBeta','FixtureGamma']})
        self.assertEqual(self.append(sid,data)[0],200)
        status,result=self.finish(sid,len(data)//2)
        self.assertEqual(status,200,result)
        self.assertEqual(result['raw_text'],'正文完整保留。')
        self.assertEqual(result['streaming_metrics']['processed_samples'],len(data)//2)
        self.assertEqual(result['streaming_metrics']['asr_calls'],1)
        self.assertEqual(models.asr_model.generate.call_count,1)

    def test_context_verification_counts_model_calls_and_failure_is_not_partial_success(self):
        for fail in (False,True):
            models=LocalModels(Path('asr'),Path('cleanup'),asr_backend='qwen')
            models.asr_ready=True;models.asr_model=Mock()
            models.cleanup=Mock(return_value='must not run')
            terms=['FixtureAlpha','FixtureBeta','FixtureGamma']
            def generate(samples,**kwargs):
                if kwargs['hotwords']:
                    text='正文。 '+','.join(terms)
                elif fail:
                    raise RuntimeError('verification unavailable')
                else:
                    text='正文完整保留。'
                return SimpleNamespace(text=text,generation_tokens=8,segments=[{'end':len(samples)/SAMPLE_RATE}])
            models.asr_model.generate.side_effect=generate
            self.service.models=models
            tone=(128*np.sin(np.arange(3200)*2*np.pi/80)).astype('<i2').tobytes()
            sid=self.start(options={'cleanup':False,'vocabulary':terms})
            self.assertEqual(self.append(sid,tone)[0],200)
            status,result=self.finish(sid,len(tone)//2)
            self.assertEqual(status,502 if fail else 200,result)
            self.assertEqual(models.asr_model.generate.call_count,2)
            models.cleanup.assert_not_called()
            if fail:
                self.assertNotIn('text',result)
                self.assertEqual(self.snapshot(sid)['state'],'failed')
                self.assertEqual(self.finish(sid,len(tone)//2)[0],502)
                self.assertEqual(models.asr_model.generate.call_count,2)
            else:
                self.assertEqual(result['raw_text'],'正文完整保留。')
                self.assertEqual(result['streaming_metrics']['asr_calls'],2)
                self.assertEqual(self.service.streams.sessions[sid].tokens,16)

    def test_all_near_silent_input_has_zero_model_calls_and_complete_coverage(self):
        models=LocalModels(Path('asr'),Path('cleanup'),asr_backend='qwen')
        models.asr_ready=True;models.asr_model=Mock();self.service.models=models
        data=np.random.default_rng(54).integers(-20,21,size=28800,dtype='<i2').tobytes()
        sid=self.start(options={'cleanup':False,'vocabulary':['FixtureAlpha','FixtureBeta']})
        self.assertEqual(self.append(sid,data)[0],200)
        status,result=self.finish(sid,len(data)//2)
        self.assertEqual(status,200,result)
        self.assertEqual(result['raw_text'],'')
        self.assertEqual(result['streaming_metrics']['asr_calls'],0)
        self.assertEqual(result['streaming_metrics']['processed_samples'],28800)
        models.asr_model.generate.assert_not_called()

    def test_transport_accepts_audio_while_asr_blocked(self):
        self.models.asr_release.clear();sid=self.start()
        self.assertEqual(self.append(sid,pcm(35))[0],200);self.assertTrue(self.models.asr_entered.wait(2))
        self.assertEqual(self.append(sid,pcm(1),35*SAMPLE_RATE)[0],200)
        self.assertEqual(self.snapshot(sid)['received_samples'],36*SAMPLE_RATE)
        self.assertEqual(self.models.cleanup_calls,[])

    def test_recording_asr_and_tail_cover_audio_exactly_once(self):
        sid=self.start();whole=pcm(37)
        self.append(sid,whole[:35*SAMPLE_RATE*2]);wait_for(lambda:self.snapshot(sid)['processed_samples']>0)
        processed=self.snapshot(sid)['processed_samples']
        self.assertEqual(len(self.models.asr_calls),1);self.assertEqual(self.models.cleanup_calls,[])
        self.append(sid,whole[35*SAMPLE_RATE*2:],35*SAMPLE_RATE)
        status,result=self.finish(sid,37*SAMPLE_RATE);self.assertEqual(status,200)
        self.assertEqual(b''.join(call[0].frames for call in self.models.asr_calls),whole)
        self.assertEqual(result['raw_text'],'片段1 片段2')
        self.assertEqual(result['streaming_metrics']['processed_audio_before_stop_seconds'],round(processed/SAMPLE_RATE,3))
        self.assertEqual(self.models.cleanup_calls[0][0],result['raw_text'])
        self.assertEqual(len(self.models.cleanup_calls),1)
        self.assertEqual([call[2] for call in self.models.asr_calls],[8192,8182])

    def test_first_edit_does_not_block_second_session_transport(self):
        self.models.edit_release.clear();first=self.start();self.append(first,pcm(1))
        pending=self.requests.submit(self.finish,first,SAMPLE_RATE)
        self.assertTrue(self.models.edit_entered.wait(2));second=self.start()
        self.assertEqual(self.append(second,pcm(35))[0],200)
        self.assertEqual(self.snapshot(first)['state'],'editing');self.assertEqual(self.snapshot(second)['state'],'queued')
        self.assertEqual(len(self.models.asr_calls),1)
        self.models.edit_release.set();self.assertEqual(pending.result(3)[0],200)
        wait_for(lambda:self.snapshot(second)['processed_samples']>0)
        self.assertEqual(len(set(self.models.threads)),1)

    def test_audio_duplicate_idempotent_mismatch_and_gap_rejected(self):
        sid=self.start();data=pcm(1);first=self.append(sid,data)
        self.assertEqual(first[0],200);self.assertEqual(self.append(sid,data),first)
        self.assertEqual(self.append(sid,pcm(1,701))[0],409)
        self.assertEqual(self.append(sid,pcm(.5),SAMPLE_RATE//2)[0],409)
        self.assertEqual(self.append(sid,data,3*SAMPLE_RATE)[0],409)
        self.assertEqual(self.snapshot(sid)['received_samples'],SAMPLE_RATE)
        self.assertEqual(self.finish(sid,SAMPLE_RATE)[0],200);self.assertEqual(len(self.models.asr_calls),1)

    def test_concurrent_and_repeated_finish_share_result(self):
        self.models.asr_release.clear();sid=self.start();self.append(sid,pcm(1))
        a=self.requests.submit(self.finish,sid,SAMPLE_RATE);self.assertTrue(self.models.asr_entered.wait(2))
        b=self.requests.submit(self.finish,sid,SAMPLE_RATE);self.models.asr_release.set()
        first,second=a.result(3),b.result(3)
        self.assertEqual(first,second);self.assertEqual(self.finish(sid,SAMPLE_RATE),first)
        self.assertEqual(len(self.models.asr_calls),1);self.assertEqual(len(self.models.cleanup_calls),1)

    def test_wrong_total_does_not_finish_and_completed_session_rejects_append(self):
        sid=self.start();self.append(sid,pcm(1))
        self.assertEqual(self.finish(sid,SAMPLE_RATE+1)[0],409);self.assertEqual(self.snapshot(sid)['state'],'recording')
        self.assertEqual(self.append(sid,pcm(1),SAMPLE_RATE)[0],200)
        self.assertEqual(self.finish(sid,2*SAMPLE_RATE)[0],200)
        self.assertEqual(self.append(sid,pcm(1),2*SAMPLE_RATE)[0],409)

    def test_cancel_during_asr_discards_late_text_without_cleanup(self):
        self.models.asr_release.clear();sid=self.start();self.append(sid,pcm(35))
        self.assertTrue(self.models.asr_entered.wait(2));self.request('POST',f'/stream/{sid}/cancel',{})
        self.assertEqual(self.finish(sid,35*SAMPLE_RATE)[0],410)
        self.assertTrue(self.request('GET','/health')[1]['busy'])
        self.models.asr_release.set();wait_for(lambda:not self.request('GET','/health')[1]['busy'])
        self.assertEqual(self.snapshot(sid)['raw_text'],'');self.assertEqual(self.models.cleanup_calls,[])

    def test_cancel_during_cleanup_rejects_final(self):
        self.models.edit_release.clear();sid=self.start();self.append(sid,pcm(1))
        pending=self.requests.submit(self.finish,sid,SAMPLE_RATE);self.assertTrue(self.models.edit_entered.wait(2))
        self.request('POST',f'/stream/{sid}/cancel',{});self.assertEqual(pending.result(2)[0],410)
        self.models.edit_release.set();wait_for(lambda:not self.request('GET','/health')[1]['busy'])
        self.assertEqual(self.snapshot(sid)['state'],'cancelled')

    def test_options_and_prompt_frozen_at_start(self):
        profile=self.service.prompts.active_version_id
        sid=self.start(options={'vocabulary':['BOM','SalesPart'],'language':'auto'})
        from server import default_prompt_draft
        draft=default_prompt_draft();draft['name']='另外一版'
        created=self.service.prompts.create(draft,self.models.cleanup_path.name)
        self.service.prompts.activate(created.id)
        self.assertEqual(self.start(sid,options={'vocabulary':['BOM','SalesPart'],'language':'auto'}),sid)
        self.append(sid,pcm(1));result=self.finish(sid,SAMPLE_RATE)[1]
        self.assertEqual(result['cleanup_profile']['version_id'],profile)
        used=self.models.asr_calls[0][1]
        self.assertEqual(used.vocabulary,('BOM','SalesPart'));self.assertEqual(used.language,'auto')
        self.assertEqual(self.models.cleanup_calls[0][1].cleanup_profile.id,profile)
        header=base64.b64encode(b'{"cleanup":false}').decode()
        self.assertEqual(self.request('POST','/stream/start',{'session_id':sid},{'X-Dictation-Options':header})[0],409)

    def test_cleanup_disabled_preserves_raw(self):
        sid=self.start(options={'cleanup':False});self.append(sid,pcm(1));result=self.finish(sid,SAMPLE_RATE)[1]
        self.assertEqual(result['text'],result['raw_text']);self.assertFalse(result['cleanup_applied'])
        self.assertIsNone(result['cleanup_profile']);self.assertEqual(self.models.cleanup_calls,[])

    def test_confirmed_corrections_are_frozen_and_part_of_retry_identity(self):
        mapping=[{'original':'SalesPrat','corrected':'SalesPart'}]
        options={'vocabulary':['SalesPart'],'corrections':mapping}
        sid=self.start(options=options)
        self.assertEqual(self.start(sid,options=options),sid)
        changed={'vocabulary':['SalesPart'],'corrections':[{'original':'SalesPrat','corrected':'SalesItem'}]}
        header=base64.b64encode(json.dumps(changed).encode()).decode()
        self.assertEqual(self.request('POST','/stream/start',{'session_id':sid},
            {'X-Dictation-Options':header})[0],409)
        self.append(sid,pcm(1));result=self.finish(sid,SAMPLE_RATE)[1]
        self.assertTrue(result['cleanup_applied'])
        expected=(('SalesPrat','SalesPart'),)
        self.assertEqual(self.models.asr_calls[0][1].corrections,expected)
        self.assertEqual(self.models.cleanup_calls[0][1].corrections,expected)
        self.assertEqual(len(self.models.cleanup_calls),1)

    def test_asr_failure_never_returns_partial_final_or_retries_on_finish(self):
        self.models.failure=RequestError(422,'语音识别达到文字长度上限。')
        sid=self.start();self.append(sid,pcm(1));first=self.finish(sid,SAMPLE_RATE)
        self.assertEqual(first[0],422);self.assertEqual(self.finish(sid,SAMPLE_RATE),first)
        self.assertEqual(self.snapshot(sid)['state'],'failed')
        self.assertEqual(len(self.models.asr_calls),1);self.assertEqual(self.models.cleanup_calls,[])

    def test_missing_editor_or_unreadable_prompt_keeps_complete_asr(self):
        from prompt_store import PromptStoreError
        for failure in ('editor','prompt'):
            with self.subTest(failure=failure):
                self.models.cleanup_ready = failure != 'editor'
                if failure == 'prompt':
                    with patch.object(self.service.prompts,'resolve',side_effect=PromptStoreError('规则文件不可用')):
                        sid=self.start()
                else:
                    sid=self.start()
                self.append(sid,pcm(1));status,result=self.finish(sid,SAMPLE_RATE)
                self.assertEqual(status,200);self.assertFalse(result['cleanup_applied'])
                self.assertEqual(result['text'],result['raw_text']);self.assertIn('warning',result)
        self.assertEqual(self.models.cleanup_calls,[])

    def test_internal_failure_does_not_expose_or_log_transcript(self):
        self.models.failure=RuntimeError('private dictated material')
        sid=self.start();self.append(sid,pcm(1))
        with self.assertLogs('local-dictation',level='ERROR') as logs:
            status,result=self.finish(sid,SAMPLE_RATE)
        self.assertEqual(status,500)
        self.assertNotIn('private dictated material',json.dumps(result))
        self.assertNotIn('private dictated material',' '.join(logs.output))

    def test_expiring_inflight_job_remains_busy_until_actual_return(self):
        now=[100.];self.service.streams.clock=lambda:now[0]
        self.models.asr_release.clear();sid=self.start();self.append(sid,pcm(35))
        self.assertTrue(self.models.asr_entered.wait(2));now[0]+=IDLE_TIMEOUT+1
        self.assertTrue(self.request('GET','/health')[1]['busy'])
        self.assertEqual(self.snapshot(sid)['state'],'failed')
        self.models.asr_release.set();wait_for(lambda:not self.request('GET','/health')[1]['busy'])
        self.assertEqual(self.models.cleanup_calls,[])

    def test_audio_and_part_limits_reject_without_mutating_received(self):
        sid=self.start()
        with patch('streaming.MAX_SAMPLES',2*SAMPLE_RATE):
            self.assertEqual(self.append(sid,pcm(3))[0],413)
        with patch('streaming.MAX_PARTS',1):
            self.assertEqual(self.append(sid,pcm(1))[0],200)
            self.assertEqual(self.append(sid,pcm(1),SAMPLE_RATE)[0],413)
        self.assertEqual(self.snapshot(sid)['received_samples'],SAMPLE_RATE)

    def test_load_failure_rejects_start(self):
        self.service.load_error='model unavailable'
        self.assertFalse(self.request('GET','/health')[1]['accepts_streaming'])
        self.assertEqual(self.request('POST','/stream/start',{'session_id':str(uuid.uuid4())})[0],503)

    def test_abandoned_session_expires_releases_busy_and_is_evicted(self):
        now=[100.];self.service.streams.clock=lambda:now[0]
        sid=self.start();self.append(sid,pcm(1));now[0]+=IDLE_TIMEOUT+1
        self.assertFalse(self.request('GET','/health')[1]['busy']);self.assertEqual(self.snapshot(sid)['state'],'failed')
        self.assertEqual(self.finish(sid,SAMPLE_RATE)[0],410)
        now[0]+=RESULT_RETENTION+1;self.assertEqual(self.request('GET',f'/stream/{sid}')[0],404)

    def test_session_capacity_recovers_after_cancel(self):
        sessions=[self.start() for _ in range(MAX_SESSIONS)]
        self.assertFalse(self.request('GET','/health')[1]['accepts_streaming'])
        self.assertEqual(self.request('POST','/stream/start',{'session_id':str(uuid.uuid4())})[0],429)
        self.request('POST',f'/stream/{sessions[0]}/cancel',{})
        self.assertTrue(self.request('GET','/health')[1]['accepts_streaming']);self.start()

    def test_legacy_and_stream_admission_share_mutex(self):
        sid=self.start()
        from test_server import wav_bytes
        self.assertEqual(self.request('POST','/dictate',wav_bytes(),{'Content-Type':'audio/wav'})[0],409)
        self.request('POST',f'/stream/{sid}/cancel',{});self.service.inference_lock.acquire()
        try:
            self.assertFalse(self.request('GET','/health')[1]['accepts_streaming'])
            self.assertEqual(self.request('POST','/stream/start',{'session_id':str(uuid.uuid4())})[0],503)
        finally: self.service.inference_lock.release()

    def test_protocol_rejects_browser_bad_uuid_json_and_pcm(self):
        self.assertEqual(self.request('POST','/stream/start',{'session_id':str(uuid.uuid4())},{'Origin':'https://example.test'})[0],403)
        self.assertEqual(self.request('POST','/stream/start',{'session_id':'not-a-uuid'})[0],400)
        self.assertEqual(self.request('POST','/stream/start',[])[0],400)
        sid=self.start();self.assertEqual(self.append(sid,b'odd')[0],413)
        self.assertEqual(self.append(sid,b'\0\0',-1)[0],400)
        self.assertEqual(self.finish(sid,True)[0],400);self.assertEqual(self.finish(sid,0)[0],400)
        self.assertEqual(self.request('POST',f'/stream/{sid}/cancel',{'unexpected':True})[0],400)
        self.assertEqual(self.request('POST',f'/stream/{sid}/audio',b'\0\0',{'Content-Type':'audio/wav','X-Audio-Offset':'0'})[0],415)

    def test_cross_finish_asr_is_wholly_post_stop_compute(self):
        self.models.asr_release.clear();sid=self.start();self.append(sid,pcm(35))
        self.assertTrue(self.models.asr_entered.wait(2));pending=self.requests.submit(self.finish,sid,35*SAMPLE_RATE)
        wait_for(lambda:self.service.streams.sessions[sid].finish_at is not None)
        time.sleep(.02);self.models.asr_release.set();result=pending.result(3)[1];m=result['streaming_metrics']
        self.assertEqual(m['asr_before_stop_seconds'],0);self.assertEqual(m['processed_audio_before_stop_seconds'],0)
        self.assertGreaterEqual(m['asr_after_stop_seconds'],.02);self.assertGreaterEqual(m['stop_to_result_seconds'],.02)
        self.assertAlmostEqual(result['total_seconds'],result['asr_seconds']+result['cleanup_seconds'],delta=.002)


class SegmentationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Compile only the installed splitter AST, avoiding a real MLX import.
        source=Path(__file__).parents[1]/'LocalDictation.app/Contents/Resources/Python/lib/python3.11/site-packages/mlx_audio/stt/models/qwen3_asr/qwen3_asr.py'
        if not source.exists(): raise unittest.SkipTest('Pinned mlx-audio source absent')
        tree=ast.parse(source.read_text())
        nodes=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='split_audio_into_chunks']
        from typing import List,Tuple
        ns={'np':np,'List':List,'Tuple':Tuple}
        exec(compile(ast.Module(body=nodes,type_ignores=[]),str(source),'exec'),ns)
        cls.reference=staticmethod(ns['split_audio_into_chunks'])

    def check_equivalent(self, frames, packet):
        count=len(frames)//2;pending=b'';output=[]
        for offset in range(0,count,packet):
            pending+=frames[offset*2:min(count,offset+packet)*2]
            while len(pending)//2>=35*SAMPLE_RATE:
                cut=next_cut(pending[:35*SAMPLE_RATE*2],False)
                output.append(pending[:cut*2]);pending=pending[cut*2:]
        while pending:
            cut=next_cut(pending,True);output.append(pending[:cut*2]);pending=pending[cut*2:]
        samples=np.frombuffer(frames,dtype='<i2').astype(np.float32)/32768.
        expected=self.reference(samples,SAMPLE_RATE,chunk_duration=30.,min_chunk_duration=1.)
        self.assertEqual(len(output),len(expected));self.assertEqual(b''.join(output),frames)
        offset=0
        for actual,(chunk,start) in zip(output,expected):
            self.assertEqual(start,offset/SAMPLE_RATE)
            converted=np.frombuffer(actual,dtype='<i2').astype(np.float32)/32768.;offset+=len(actual)//2
            if len(converted)<SAMPLE_RATE: converted=np.pad(converted,(0,SAMPLE_RATE-len(converted)))
            np.testing.assert_array_equal(converted,chunk)

    def test_equivalent_to_pinned_batch_for_lengths_and_transport_boundaries(self):
        generator=np.random.default_rng(24)
        for seconds in (.2,1,30,30.1,35,63.7,95.3):
            for packet in (32000,16000*36):
                with self.subTest(seconds=seconds,packet=packet):
                    frames=generator.integers(-12000,12000,round(seconds*SAMPLE_RATE),dtype=np.int16).astype('<i2').tobytes()
                    self.check_equivalent(frames,packet)

    def test_silence_ties_and_pauses_match_batch(self):
        for frames in (pcm(71,0),pcm(28)+pcm(1,0)+pcm(30)+pcm(1,0)+pcm(12)):
            self.check_equivalent(frames,16000)

    def test_requires_right_context_before_stop(self):
        self.assertIsNone(next_cut(pcm(34.9),False));self.assertIsNotNone(next_cut(pcm(34.9),True))
        self.assertIsNotNone(next_cut(pcm(35),False))


class ModelSegmentTests(unittest.TestCase):
    def test_extent_not_resplit_budget_and_coverage_checked(self):
        models=LocalModels(Path('asr'),Path('cleanup'),asr_backend='qwen');models.asr_model=Mock()
        models.asr_model.generate.return_value=SimpleNamespace(text='第一段',generation_tokens=12,segments=[{'end':34.}])
        # Audible alternating PCM, not a DC offset that the silence guard
        # deliberately rejects before model inference.
        audio=np.resize(np.array([700,-700],dtype='<i2'),34*SAMPLE_RATE).tobytes()
        recording=Recording(audio,16000,1,34.)
        self.assertEqual(models.transcribe_segment(recording,DictationOptions(),max_tokens=44),('第一段',12,1))
        kwargs=models.asr_model.generate.call_args.kwargs
        self.assertGreater(kwargs['chunk_duration'],34.);self.assertEqual(kwargs['max_tokens'],44)
        models.asr_model.generate.return_value.generation_tokens=44
        with self.assertRaises(RequestError) as caught: models.transcribe_segment(recording,DictationOptions(),max_tokens=44)
        self.assertEqual(caught.exception.status,422)
        models.asr_model.generate.return_value=SimpleNamespace(text='截断',generation_tokens=10,segments=[{'end':30.}])
        with self.assertRaises(RequestError): models.transcribe_segment(recording,DictationOptions())


if __name__=='__main__': unittest.main()
