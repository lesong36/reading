import json
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from langchain_core.messages import AIMessage
from math_learning import learn_skills
from math_skills import SkillError
from test_math_learning import coverage, evidence, proposal, review


class StructuredModel:
    def __init__(self, outputs):
        self.outputs = list(outputs)
        self.calls = 0
        self.bindings = []
        self.text_calls = 0

    def with_structured_output(self, schema, **kwargs):
        self.bindings.append((schema, kwargs))
        owner = self
        class Bound:
            async def ainvoke(self, messages, config=None):
                owner.calls += 1
                value = owner.outputs.pop(0)
                if isinstance(value, Exception):
                    raise value
                if isinstance(value, AIMessage):
                    return {"raw": value, "parsed": coverage('covered', ['q-a']), "parsing_error": None}
                name = schema['title']
                return {"raw": AIMessage(content='', additional_kwargs={'tool_calls': [
                    {'id': 'one', 'type': 'function', 'function': {'name': name, 'arguments': json.dumps(value)}}]},
                    response_metadata={'finish_reason': 'tool_calls'}), 'parsed': {'wrong': True}, 'parsing_error': None}
        return Bound()

    async def ainvoke(self, messages, config=None):
        self.calls += 1
        self.text_calls += 1
        value = self.outputs.pop(0)
        if isinstance(value, Exception): raise value
        return AIMessage(content=json.dumps(value))


class Unsupported(Exception):
    status_code = 400
    body = {'error': {'param': 'tools', 'message': 'unsupported'}}


class StructuredLearningTests(unittest.IsolatedAsyncioTestCase):
    async def run_graph(self, model, learning=None):
        output, execution = await learn_skills(model, [], [{'id': 'known'}], learning or {'evidence': evidence()})
        return json.loads(output), execution

    async def test_single_schema_call_uses_raw_not_parsed(self):
        model = StructuredModel([coverage('covered', ['q-a'])])
        result, execution = await self.run_graph(model)
        self.assertEqual(result['coverage'], 'covered')
        self.assertEqual(model.calls, 1)
        self.assertEqual(model.bindings[0][1], {'method': 'function_calling', 'include_raw': True})
        self.assertEqual(execution['output_protocols'], ['function_calling'])

    async def test_invalid_tool_envelopes_and_duplicate_arguments_rejected(self):
        name = 'math_learning_coverage'
        valid = {'id': 'one', 'type': 'function', 'function': {'name': name, 'arguments': json.dumps(coverage('covered', ['q-a']))}}
        variants = [AIMessage(content='', additional_kwargs={'tool_calls': [valid, {**valid, 'id': 'two'}]}, response_metadata={'finish_reason':'tool_calls'}),
            AIMessage(content='', additional_kwargs={'tool_calls': [{**valid, 'function': {**valid['function'], 'name':'other'}}]}, response_metadata={'finish_reason':'tool_calls'}),
            AIMessage(content='', additional_kwargs={'tool_calls': [{**valid, 'function': {**valid['function'], 'arguments':'{"coverage":"covered","coverage":"uncovered"}'}}]}, response_metadata={'finish_reason':'tool_calls'}),
            AIMessage(content='', invalid_tool_calls=[{'name':name, 'args':'{', 'id':'bad', 'error':'invalid'}], response_metadata={'finish_reason':'tool_calls'})]
        for raw in variants:
            with self.subTest(raw=raw):
                model = StructuredModel([raw, raw])
                with self.assertRaises(SkillError): await self.run_graph(model)
                self.assertEqual(model.calls, 2)

    async def test_unsupported_fallback_spends_only_shared_repair(self):
        model = StructuredModel([Unsupported(), coverage(), proposal(), review()])
        result, execution = await self.run_graph(model)
        self.assertEqual(result['status'], 'awaiting_human')
        self.assertEqual(model.calls, 4)
        self.assertEqual(execution['output_protocols'], ['function_calling', 'text_compatibility', 'text_compatibility', 'text_compatibility'])
        bad = StructuredModel([Unsupported(), '{bad'])
        with self.assertRaises(SkillError): await self.run_graph(bad)
        self.assertEqual(bad.calls, 2)

    async def test_timeout_never_falls_back(self):
        model = StructuredModel([TimeoutError('private provider timeout')])
        with self.assertRaises(TimeoutError): await self.run_graph(model)
        self.assertEqual(model.calls, 1)
        self.assertEqual(model.text_calls, 0)

    async def test_truncation_is_terminal_and_text_cannot_use_tool_stop(self):
        raw = AIMessage(content='', additional_kwargs={'tool_calls':[{'id':'one', 'type':'function', 'function':{'name':'math_learning_coverage', 'arguments':json.dumps(coverage())}}]}, response_metadata={'finish_reason':'length'})
        model = StructuredModel([raw])
        with self.assertRaisesRegex(SkillError, 'learningTruncated'): await self.run_graph(model)
        self.assertEqual(model.calls, 1)

    async def test_human_resume_does_not_bind_or_invoke_model(self):
        result, _ = await self.run_graph(StructuredModel([coverage(), proposal(), review()]))
        fresh = StructuredModel([])
        resumed, execution = await self.run_graph(fresh, {'workflow_state':result['workflow_state'], 'decision':{'action':'approve', 'reviewer':'user', 'note':'Checked original examples'}})
        self.assertEqual(resumed['status'], 'approved')
        self.assertEqual(fresh.calls, 0)
        self.assertEqual(fresh.bindings, [])
        self.assertEqual(execution['output_protocols'], [])

    async def test_stop_with_single_raw_call_and_responses_arguments(self):
        name = 'math_learning_coverage'
        args = json.dumps(coverage('covered', ['q-a']))
        for raw in [AIMessage(content='', additional_kwargs={'tool_calls':[{'id':'one', 'type':'function', 'function':{'name':name, 'arguments':args}}]}, response_metadata={'finish_reason':'stop'}),
                    AIMessage(content=[{'type':'function_call', 'name':name, 'arguments':args, 'call_id':'one'}])]:
            result, execution = await self.run_graph(StructuredModel([raw]))
            self.assertEqual(result['coverage'], 'covered')
            self.assertEqual(execution['model_calls'], 1)

    async def test_parsed_only_input_falls_back_truthfully_once(self):
        raw = AIMessage(content=[{'type':'tool_use', 'id':'one', 'name':'math_learning_coverage', 'input':coverage('covered', ['q-a'])}], response_metadata={'stop_reason':'tool_use'})
        model = StructuredModel([raw, coverage('covered', ['q-a'])])
        _, execution = await self.run_graph(model)
        self.assertEqual(model.calls, 2)
        self.assertEqual(execution['output_protocols'], ['function_calling', 'text_compatibility'])

    async def test_unimplemented_binding_costs_no_extra_request(self):
        class BindingUnsupported(StructuredModel):
            def with_structured_output(self, *args, **kwargs): raise NotImplementedError()
        model = BindingUnsupported([coverage('covered', ['q-a'])])
        _, execution = await self.run_graph(model)
        self.assertEqual(model.calls, 1)
        self.assertEqual(execution['output_protocols'], ['text_compatibility'])

    async def test_text_fallback_rejects_tool_termination_and_payload(self):
        from test_math_learning import Model
        class TextToolModel(Model):
            async def ainvoke(self, *args, **kwargs):
                self.calls += 1
                return AIMessage(content=json.dumps(coverage('covered', ['q-a'])), response_metadata={'finish_reason':'tool_calls'})
        model = TextToolModel()
        with self.assertRaisesRegex(SkillError, 'learningTruncated'): await self.run_graph(model)
        self.assertEqual(model.calls, 1)

    async def test_profile_review_single_schema_and_bounded_compatibility(self):
        from test_profile_review import profile
        for outputs, calls in [([review()], 1), ([Unsupported(), review()], 2)]:
            model = StructuredModel(outputs)
            result, execution = await self.run_graph(model, {'profile_review':profile()})
            self.assertEqual(result['version_id'], 'exact-version')
            self.assertNotIn('human_decision', result)
            self.assertEqual(model.calls, calls)
            self.assertEqual(model.bindings[0][0]['title'], 'math_learning_profile_review')
            self.assertEqual(execution['model_calls'], calls)

    async def openai_stream(self, arguments):
        import httpx
        from langchain_openai import ChatOpenAI
        requests = []
        async def respond(request):
            body = json.loads(request.content)
            requests.append(body)
            self.assertTrue(body['stream'])
            name = body['tools'][0]['function']['name']
            self.assertEqual(name, 'math_learning_coverage')
            split = len(arguments) // 2
            chunks = [
                {'role':'assistant', 'tool_calls':[{'index':0, 'id':'one', 'type':'function', 'function':{'name':name, 'arguments':arguments[:split]}}]},
                {'tool_calls':[{'index':0, 'function':{'arguments':arguments[split:]}}]}, {}]
            events = []
            for i, delta in enumerate(chunks):
                events.append('data: ' + json.dumps({'id':'isolated', 'object':'chat.completion.chunk', 'created':1, 'model':'test-model',
                    'choices':[{'index':0, 'finish_reason':'tool_calls' if i == 2 else None, 'delta':delta}]}) + '\n\n')
            return httpx.Response(200, headers={'content-type':'text/event-stream'}, content=''.join(events) + 'data: [DONE]\n\n')
        async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
            model = ChatOpenAI(model='test-model', api_key='isolated-test-key', base_url='https://isolated.invalid/v1', max_retries=0, http_async_client=client, http_socket_options=())
            try:
                return await self.run_graph(model), requests
            except SkillError as error:
                return error, requests

    async def test_actual_openai_stream_keeps_original_arguments_one_call(self):
        (result, execution), requests = await self.openai_stream(json.dumps(coverage('covered', ['q-a'])))
        self.assertEqual(result['coverage'], 'covered')
        self.assertEqual(len(requests), 1)
        self.assertEqual(execution['model_calls'], 1)
        self.assertEqual(execution['output_protocols'], ['function_calling'])

    async def test_actual_openai_stream_rejects_duplicate_wire_keys(self):
        arguments = json.dumps(coverage('covered', ['q-a']))
        arguments = arguments[:-1] + ', "coverage": "covered"}'
        error, requests = await self.openai_stream(arguments)
        self.assertIsInstance(error, SkillError)
        self.assertEqual(error.issue, 'json_duplicate_keys')
        self.assertEqual(len(requests), 2)
        self.assertTrue(all(request.get('tools') for request in requests))


    async def test_actual_openai_stream_oversized_arguments_stop_without_repair(self):
        value = coverage('covered', ['q-a'])
        value['reason'] = 'x' * 32001
        error, requests = await self.openai_stream(json.dumps(value))
        self.assertIsInstance(error, SkillError)
        self.assertEqual(error.issue, 'json_size')
        self.assertEqual(error.model_calls, 1)
        self.assertEqual(len(requests), 1)

    async def test_stream_limit_precedes_aggregation_and_closes_iterator(self):
        from langchain_core.messages import AIMessageChunk
        from math_learning import LearningOutputTransport, LearningStreamSizeError
        class StreamModel:
            closed = False
            consumed = 0
            def with_structured_output(self, *args, **kwargs): return self
            async def astream(self, messages, config=None):
                try:
                    self.consumed += 1
                    yield {'raw':AIMessageChunk(content='', tool_call_chunks=[{'name':'math_learning_coverage', 'args':json.dumps({'reason':'x' * 32001}), 'id':'one', 'index':0}])}
                    self.consumed += 1
                    raise AssertionError('Oversized result must not consume another chunk')
                finally:
                    self.closed = True
        model = StreamModel()
        with self.assertRaises(LearningStreamSizeError):
            await LearningOutputTransport(model).invoke([], 'coverage')
        self.assertEqual(model.consumed, 1)
        self.assertTrue(model.closed)

    async def test_stream_size_counts_utf8_wire_arguments_only_once(self):
        from types import SimpleNamespace
        from math_learning import raw_chunk_bytes
        arguments = '{"reason":"中文原始参数"}'
        name = 'math_learning_coverage'
        raw = SimpleNamespace(additional_kwargs={'tool_calls':[{'function':{'name':name, 'arguments':arguments}}]},
            tool_call_chunks=[{'name':name, 'args':arguments}],
            content=[{'type':'function_call', 'name':name, 'arguments':arguments}])
        self.assertEqual(raw_chunk_bytes(raw), len(name.encode()) + len(arguments.encode()))
