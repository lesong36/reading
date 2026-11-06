"""Safe schema paths and malformed tool JSON, not mathematical correctness."""
import json
from pathlib import Path
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from langchain_core.messages import AIMessage
from langchain_openai import ChatOpenAI
from pydantic import ValidationError
from unittest.mock import patch
from math_skills import SkillError, SnapshotBackend, prerequisite_requirements, prerequisite_schema, select_skills, snapshots_for, validation_issue, wrapped_protocol_error
from test_math_skills import MESSAGES, ScriptModel, answer, skills, truth_answer
from test_math_tool_strategy import decision, read, truth_decision


class ValidationDiagnosticsBoundaryTests(unittest.TestCase):
    def test_nested_arithmetic_schema_fields_have_safe_paths(self):
        from test_math_prerequisite_computed import draft, review, snapshots
        schema = prerequisite_schema(prerequisite_requirements(draft()), snapshots())
        cases = []
        value = review(); del value['methods'][0]['conditions'][0]['arithmetic']['operands'][0]['origin']
        cases.append((value, 'review.methods[0].conditions[0].arithmetic.operands[0].origin:missing_field'))
        value = review(); value['methods'][0]['conditions'][0]['arithmetic']['operands'][0]['value'] = 14
        cases.append((value, 'review.methods[0].conditions[0].arithmetic.operands[0].value:field_type'))
        value = review(); value['methods'][0]['conditions'][0]['arithmetic']['expression'] = 'private_question_secret'*10
        cases.append((value, 'review.methods[0].conditions[0].arithmetic.expression:field_limit'))
        for value, issue in cases:
            with self.subTest(issue=issue), self.assertRaises(ValidationError) as captured:
                schema.model_validate(value)
            self.assertEqual(validation_issue(captured.exception, 'review'), issue)
            self.assertEqual(SkillError('skillsOutput', issue=issue).issue, issue)

    def test_unknown_locations_error_types_and_payloads_never_enter_diagnostics(self):
        for loc, expected in ((('methods',0,'conditions',0,'private_question_secret'), 'review.methods[0].conditions[0]:extra_field'),
            (('private_question_secret',), 'review:extra_field'),
            (('methods',999,'private_question_secret'), 'review.methods:extra_field')):
            error = ValidationError.from_exception_data('private_question_secret', [{'type':'extra_forbidden','loc':loc,'input':'private_question_secret'}])
            self.assertEqual(validation_issue(error,'review'),expected)
        error = ValidationError.from_exception_data('private_question_secret', [{'type':'value_error','loc':('private_question_secret',),'input':'private_question_secret','ctx':{'error':ValueError('private_question_secret')}}])
        self.assertEqual(validation_issue(error,'review'),'selection:invalid')
        for issue in ('review.methods[999].conditions[0]:missing_field',
            'review.methods[0].conditions[0].private_question_secret:missing_field',
            'review.methods[0].conditions[0].arithmetic.condition_id:missing_field',
            'review.methods['+'9'*5000+']:missing_field'):
            self.assertIsNone(SkillError('skillsOutput',issue=issue).issue)

    def test_wrapped_existing_skill_error_has_priority(self):
        error = ValidationError.from_exception_data('private_question_secret', [{'type':'missing','loc':('methods',),'input':{}}])
        original = SkillError('skillsOutput',issue='selection.method_id:unknown_identity')
        error.__cause__ = original
        self.assertIs(wrapped_protocol_error(error,'review'),original)


class ValidationDiagnosticsGraphTests(unittest.IsolatedAsyncioTestCase):
    async def check(self, invalid, expected):
        rows = snapshots_for(skills()); path = next(iter(SnapshotBackend(rows).files))
        for transport in (truth_decision(invalid), AIMessage(json.dumps(invalid))):
            with self.subTest(transport=bool(transport.tool_calls)):
                model = ScriptModel(); model._responses = [read(path), decision(), transport, truth_decision()]
                raw, details = await select_skills(model, MESSAGES, rows)
                self.assertEqual(json.loads(raw), json.loads(answer()))
                self.assertEqual(details['protocol_repairs'], [expected])
                self.assertEqual(details['model_calls'], 4)
                feedback = model._calls[-1][-1].text
                self.assertIn(expected, feedback)
                self.assertNotIn('private_question_secret', feedback)

    async def test_missing_field_is_named_without_error_inputs(self):
        invalid = json.loads(truth_answer()); del invalid['methods'][0]['conditions'][0]['evidence']
        await self.check(invalid, 'review.methods[0].conditions[0].evidence:missing_field')

    async def test_wrong_scalar_and_limit_are_fixed_types(self):
        invalid = json.loads(truth_answer()); invalid['methods'][0]['conditions'][0]['truth'] = 'private_question_secret'
        await self.check(invalid, 'review.methods[0].conditions[0].truth:field_type')
        invalid = json.loads(truth_answer()); invalid['methods'][0]['conditions'][0]['proposition'] = 'private_question_secret'*20
        await self.check(invalid, 'review.methods[0].conditions[0].proposition:field_limit')

    async def test_unknown_extra_field_reports_only_known_parent(self):
        invalid = json.loads(truth_answer()); invalid['methods'][0]['conditions'][0]['private_question_secret'] = 'private_question_secret'
        await self.check(invalid, 'review.methods[0].conditions[0]:extra_field')

    async def test_malformed_tool_arguments_are_invalid_not_truncated_in_both_phases(self):
        rows = snapshots_for(skills()); path = next(iter(SnapshotBackend(rows).files))
        for phase, name in (('selection', 'SkillSelection'), ('truth', 'PrerequisiteTruth')):
            invalid = AIMessage('', response_metadata={'finish_reason': 'tool_calls'}, invalid_tool_calls=[{'name': name, 'args': '{private_question_secret', 'id': 'invalid', 'error': 'private_question_secret', 'type': 'invalid_tool_call'}])
            model = ScriptModel()
            model._responses = ([read(path), invalid, decision(), truth_decision()] if phase == 'selection' else [read(path), decision(), invalid, truth_decision()])
            raw, details = await select_skills(model, MESSAGES, rows)
            self.assertEqual(json.loads(raw), json.loads(answer()))
            self.assertEqual(details['protocol_repairs'], ['selection.json:property_name'])
            self.assertEqual(details['model_calls'], 4)
            self.assertNotIn('private_question_secret', model._calls[2 if phase == 'selection' else 3][-1].text)

    async def test_mixed_malformed_tool_and_read_is_rejected_without_disclosure(self):
        rows = snapshots_for(skills()); path = next(iter(SnapshotBackend(rows).files))
        invalid = read(path).model_copy(update={'invalid_tool_calls':[{'name':'SkillSelection','args':'{private_question_secret','id':'bad','error':'private_question_secret','type':'invalid_tool_call'}]})
        model = ScriptModel(); model._responses = [invalid,decision()]
        with patch.object(SnapshotBackend,'load_for_model') as loader:
            with self.assertRaises(SkillError) as captured:
                await select_skills(model,MESSAGES,rows)
        self.assertEqual(captured.exception.code,'skillsOutput')
        self.assertEqual(captured.exception.issue,'selection.json:property_name')
        loader.assert_not_called()
        self.assertEqual(len(model._calls),1)

    async def test_real_length_with_malformed_tool_arguments_stays_incomplete(self):
        rows = snapshots_for(skills()); path = next(iter(SnapshotBackend(rows).files))
        invalid = AIMessage('', response_metadata={'finish_reason': 'length'}, invalid_tool_calls=[{'name':'PrerequisiteTruth','args':'{private_question_secret','id':'invalid','error':'private_question_secret','type':'invalid_tool_call'}])
        model = ScriptModel(); model._responses = [read(path), decision(), invalid, truth_decision()]
        _, details = await select_skills(model, MESSAGES, rows)
        self.assertEqual(details['protocol_repairs'], ['selection.json:incomplete'])


class ScriptedGateway(BaseHTTPRequestHandler):
    messages = []
    requests = []
    def log_message(self, *_): pass
    def do_POST(self):
        self.requests.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
        message, reason = self.messages.pop(0)
        raw = json.dumps({'id':'mock','object':'chat.completion','created':1,'model':'test-model',
            'choices':[{'index':0,'message':message,'finish_reason':reason}],
            'usage':{'prompt_tokens':1,'completion_tokens':1,'total_tokens':2}}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(raw))); self.end_headers(); self.wfile.write(raw)


def gateway_tool(name, arguments, index):
    return ({'role':'assistant','content':None,'tool_calls':[{'id':str(index),'type':'function','function':{'name':name,'arguments':arguments}}]}, 'tool_calls')


class ValidationDiagnosticsSDKTests(unittest.IsolatedAsyncioTestCase):
    async def test_actual_chat_sdk_malformed_json_and_schema_missing_use_safe_repair(self):
        rows = snapshots_for(skills()); path = next(iter(SnapshotBackend(rows).files))
        for bad_arguments, issue in (('{private_question_secret','selection.json:property_name'),
            (json.dumps({'methods':[{'method_id':'id-0','private_question_secret':'private_question_secret'}]}), 'review.methods[0].current_branch:missing_field')):
            ScriptedGateway.requests = []
            ScriptedGateway.messages = [gateway_tool('read_file',json.dumps({'file_path':path}),0), gateway_tool('SkillSelection',answer(),1),gateway_tool('PrerequisiteTruth',bad_arguments,2),gateway_tool('PrerequisiteTruth',truth_answer(),3)]
            server = ThreadingHTTPServer(('127.0.0.1',0),ScriptedGateway); threading.Thread(target=server.serve_forever,daemon=True).start()
            model = ChatOpenAI(model='test-model',api_key='fake-local-key',base_url=f'http://127.0.0.1:{server.server_port}/v1',max_retries=0)
            try:
                raw, details = await select_skills(model, MESSAGES, rows)
                self.assertEqual(json.loads(raw),json.loads(answer()))
                self.assertEqual(details['protocol_repairs'],[issue])
                self.assertEqual(details['model_calls'],4)
                self.assertEqual(len(ScriptedGateway.requests),4)
                feedback=ScriptedGateway.requests[-1]['messages'][-1]['content']
                self.assertIn(issue,feedback)
                self.assertNotIn('private_question_secret',feedback)
            finally:
                server.shutdown(); server.server_close()


if __name__ == '__main__': unittest.main()
