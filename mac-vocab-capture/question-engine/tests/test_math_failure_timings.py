"""A failed one-shot math request must retain clocks without provider content."""
import asyncio
import json
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import question_engine as engine
from langchain_core.messages import AIMessageChunk
from test_engine import request

class Model:
    def __init__(self, interrupt=False): self.interrupt = interrupt
    def bind_tools(self, *args, **kwargs): return self
    async def astream(self, *args, **kwargs):
        yield AIMessageChunk(content='', tool_call_chunks=[{'name':'render_difference_ratio','args':'{}','id':'one','index':0}], response_metadata={'finish_reason':'tool_calls'})
        if self.interrupt: raise engine.httpx.ReadTimeout('private-key-and-question')

class Pool:
    def __init__(self, model=None, error=None): self.model,self.error=model,error
    async def acquire(self, configuration):
        if self.error: raise self.error
        return 'one', self.model
    def release(self, key): pass

class FailureClockTests(unittest.IsolatedAsyncioTestCase):
    async def run_math(self, pool):
        p=request();p.update(response_mode='math_solution',solution_protocol='renderer_tools')
        events=[];await engine.run_request(p,events.append,pool)
        self.assertEqual([e['type'] for e in events],['error'])
        self.assertNotIn('private-key-and-question', json.dumps(events))
        return events[0]
    async def test_connection_during_acquisition_has_total_without_invented_stream(self):
        e=await self.run_math(Pool(error=engine.httpx.ConnectError('private-key-and-question')))
        self.assertEqual(e['failure_phase'],'model_acquisition')
        self.assertGreaterEqual(e['timings']['engine_total'], e['timings']['model_acquisition'])
        self.assertNotIn('first_sdk_chunk',e['timings'])
    async def test_interrupted_stream_retains_partial_clock(self):
        e=await self.run_math(Pool(Model(interrupt=True)))
        self.assertEqual(e['failure_phase'],'stream')
        self.assertEqual(e['code'],'timeout')
        self.assertGreaterEqual(e['timings']['stream_total'],e['timings']['first_sdk_chunk'])
        self.assertNotIn('submission_validation',e['timings'])
    async def test_invalid_arguments_retains_completed_stream_and_validation(self):
        e=await self.run_math(Pool(Model()))
        self.assertEqual(e['failure_phase'],'submission_validation')
        self.assertEqual(e['submission_issue'],'submission_shape')
        self.assertGreaterEqual(e['timings']['submission_validation'],0)
        self.assertGreaterEqual(e['timings']['engine_total'], e['timings']['stream_total'])

    async def test_concurrent_failures_do_not_share_clocks_or_leak_context(self):
        a,b=await asyncio.gather(self.run_math(Pool(Model())),
            self.run_math(Pool(error=engine.httpx.ConnectError('private-key-and-question'))))
        self.assertEqual(a['failure_phase'],'submission_validation')
        self.assertEqual(b['failure_phase'],'model_acquisition')
        self.assertIn('first_sdk_chunk',a['timings'])
        self.assertNotIn('first_sdk_chunk',b['timings'])
        self.assertIsNone(engine._math_observation.get())

    async def test_incomplete_stream_categories_are_safe_and_never_emit_answers(self):
        class EndingModel(Model):
            def __init__(self, reason): self.reason = reason
            async def astream(self, *args, **kwargs):
                yield AIMessageChunk(content='', tool_call_chunks=[{'name':'render_difference_ratio','args':'{}','id':'one','index':0}], response_metadata={} if self.reason is None else {'finish_reason':self.reason})
        for reason, category in [(None, 'missing_terminal'), ('length', 'token_limit'),
                                 ('content_filter', 'content_filter'),
                                 ('private-key-and-question', 'other_terminal')]:
            with self.subTest(reason=reason):
                e = await self.run_math(Pool(EndingModel(reason)))
                self.assertEqual(e['code'], 'truncated')
                self.assertEqual(e['submission_issue'], 'submission_truncated')
                self.assertEqual(e['stream_termination'], category)
                self.assertEqual(e['failure_phase'], 'submission_validation')
