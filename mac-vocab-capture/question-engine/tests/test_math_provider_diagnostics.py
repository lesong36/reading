import json
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import unittest
from unittest.mock import AsyncMock, patch
import httpx
import openai
import question_engine as engine


class MathProviderDiagnosticsTests(unittest.IsolatedAsyncioTestCase):
    def error(self, message, status=400):
        return openai.BadRequestError('secret provider prose', response=httpx.Response(status,
            request=httpx.Request('POST', 'https://example.invalid/v1/chat/completions')),
            body={'error': {'message': message, 'param': 'tools[0].function.parameters'}})

    def payload(self):
        return {'id': 'probe', 'response_mode': 'math_solution', 'solution_protocol': 'renderer_tools'}

    async def test_error_event_retains_only_allowlisted_field_names(self):
        events = []
        error = self.error('tools schema $ref failed: sk-sensitive-secret user@example.invalid')
        with patch.object(engine, 'stream_answer', AsyncMock(side_effect=error)):
            await engine.run_request(self.payload(), events.append)
        self.assertEqual(len(events), 1)
        event = dict(events[0])
        self.assertEqual(event.pop('failure_phase'), 'preparation')
        clocks = event.pop('timings')
        self.assertEqual(set(clocks), {'engine_total'})
        self.assertGreaterEqual(clocks['engine_total'], 0)
        self.assertEqual(event, {'id': 'probe', 'type': 'error', 'code': 'server', 'status': 400,
            'request_fields': ['$ref', 'tools']})
        self.assertNotIn('sensitive', json.dumps(events))
        self.assertNotIn('example', json.dumps(events))

    def test_english_authentication_and_unknown_vocabulary_expose_nothing(self):
        for payload in [{}, {'response_mode': 'math_solution'},
                        self.payload() | {'solution_protocol': 'single_submission'}]:
            self.assertEqual(engine.math_request_fields(self.error('tools'), payload), [])
        self.assertEqual(engine.math_request_fields(self.error('tools', 401), self.payload()), [])
        error = self.error('arbitrary_secret')
        error.body = {'message': 'arbitrary_secret'}
        self.assertEqual(engine.math_request_fields(error, self.payload()), [])
        error.body = {'message': 'tools ' + 'x' * 8192}
        self.assertEqual(engine.math_request_fields(error, self.payload()), [])

    def test_field_boundaries_and_malformed_bodies(self):
        error = self.error('tools')
        error.body = {'message': 'mytools unknown_tools tool_choices'}
        self.assertEqual(engine.math_request_fields(error, self.payload()), [])
        for body in [None, [], {'error': []}]:
            error.body = body
            self.assertEqual(engine.math_request_fields(error, self.payload()), [])
