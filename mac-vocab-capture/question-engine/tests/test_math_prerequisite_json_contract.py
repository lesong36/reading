"""Strict JSON failure feedback and current-branch coverage contracts."""
import json
from pathlib import Path
import sys
import threading
import unittest
from http.server import ThreadingHTTPServer
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from langchain_core.messages import AIMessage
from langchain_openai import ChatOpenAI
from math_skills import PREREQUISITE_TRUTH_PROMPT, SkillError, SnapshotBackend, invalid_tool_json_issue, json_syntax_issue, prerequisite_requirements, prerequisite_schema, select_skills, snapshots_for
from test_math_skills import MESSAGES, ScriptModel, answer, skills, truth_answer
from test_math_tool_strategy import decision, read, truth_decision
from test_math_prerequisite_validation_diagnostics import ScriptedGateway, gateway_tool

CASES = [
    ('{"private_question_secret":0}x', 'extra_data'),
    ('{"private_question_secret":0 "x":1}', 'comma'),
    ('{"private_question_secret" 0}', 'colon'),
    ('{private_question_secret:0}', 'property_name'),
    ('{"private_question_secret":}', 'value'),
    ('{"private_question_secret":"unfinished}', 'unterminated_string'),
    ('{"private_question_secret":"line\ntext"}', 'control_character'),
    (r'{"private_question_secret":"\q"}', 'escape'),
    (r'{"private_question_secret":"\uZZZZ"}', 'escape'),
]


def malformed(args, name='PrerequisiteTruth', reason='tool_calls'):
    return AIMessage('', response_metadata={'finish_reason':reason}, invalid_tool_calls=[{'name':name,'args':args,'id':'bad','error':'private_question_secret','type':'invalid_tool_call'}])


class JsonContractBoundaryTests(unittest.TestCase):
    def test_only_allowlisted_decoder_messages_produce_safe_codes(self):
        error=json.JSONDecodeError('private_question_secret', 'private_question_secret',0)
        self.assertEqual(json_syntax_issue(error),'selection.json:unknown')
        self.assertEqual(json_syntax_issue(ValueError('private_question_secret')),'selection.json:unknown')
        for args in ('{"private_question_secret":0}',None):
            self.assertEqual(invalid_tool_json_issue(malformed(args)),'selection.json:unknown')
        with patch('math_skills.json.loads',side_effect=RecursionError('private_question_secret')):
            self.assertEqual(invalid_tool_json_issue(malformed('{}')),'selection.json:unknown')
        for _,code in CASES:
            issue='selection.json:'+code
            self.assertEqual(SkillError('skillsOutput',issue=issue).issue,issue)
        for issue in ('selection.json:extra_data:private_question_secret','selection.json:private_question_secret','selection.reason:extra_data'):
            self.assertIsNone(SkillError('skillsOutput',issue=issue).issue)

    def test_current_coverage_and_additional_fields_are_explicit_in_prompt_and_schema(self):
        from test_math_prerequisite_scope import draft,snapshot
        schema=prerequisite_schema(prerequisite_requirements(draft()),snapshot()).model_json_schema()
        method=schema['$defs']['MethodPrerequisiteTruth']['properties']
        additional=schema['$defs']['AdditionalPrerequisite']
        self.assertFalse(additional['additionalProperties'])
        self.assertNotIn('condition_id',additional['properties'])
        self.assertIn('every fixed pN',method['coverage_complete']['description'])
        self.assertIn('current-branch',method['coverage_complete']['description'])
        self.assertIn('no condition_id',method['additional_prerequisites']['description'])
        self.assertIn('不要求把其他分支或例题条件逐条枚举',PREREQUISITE_TRUTH_PROMPT)
        self.assertIn('additional_prerequisites不得包含condition_id',PREREQUISITE_TRUTH_PROMPT)


class JsonContractGraphTests(unittest.IsolatedAsyncioTestCase):
    async def test_text_and_tool_syntax_failures_get_only_fixed_reasons(self):
        rows = snapshots_for(skills()); path = next(iter(SnapshotBackend(rows).files))
        for args, code in CASES:
            for response in (AIMessage(args), malformed(args)):
                with self.subTest(code=code, tool=bool(response.invalid_tool_calls)):
                    model=ScriptModel();model._responses=[read(path),decision(),response,truth_decision()]
                    raw,details=await select_skills(model,MESSAGES,rows)
                    self.assertEqual(json.loads(raw),json.loads(answer()))
                    self.assertEqual(details['protocol_repairs'],['selection.json:'+code])
                    self.assertEqual(details['model_calls'],4)
                    feedback=model._calls[-1][-1].text
                    self.assertIn('selection.json:'+code,feedback)
                    self.assertNotIn('private_question_secret',feedback)

    async def test_complete_object_plus_extra_character_is_not_trimmed(self):
        rows=snapshots_for(skills());path=next(iter(SnapshotBackend(rows).files))
        for response in (AIMessage(truth_answer()+'}'),malformed(truth_answer()+'}')):
            model=ScriptModel();model._responses=[read(path),decision(),response,truth_decision()]
            _,details=await select_skills(model,MESSAGES,rows)
            self.assertEqual(details['protocol_repairs'],['selection.json:extra_data'])
            self.assertEqual(len(model._calls),4)
            self.assertIn('唯一完整JSON',model._calls[-1][-1].text)

    async def test_second_error_and_final_budget_never_get_another_repair(self):
        rows=snapshots_for(skills());path=next(iter(SnapshotBackend(rows).files))
        bad=malformed(truth_answer()+'}')
        for responses,count in (([read(path),decision(),bad,bad,truth_decision()],4),
            ([read(path,i) for i in range(3)]+[decision(),bad,truth_decision()],5)):
            model=ScriptModel();model._responses=responses
            with self.assertRaises(SkillError) as captured: await select_skills(model,MESSAGES,rows)
            self.assertEqual(captured.exception.code,'skillsOutput')
            self.assertEqual(captured.exception.issue,'selection.json:extra_data')
            self.assertEqual(len(model._calls),count)
            self.assertEqual(len(model._responses),1)

    async def test_current_general_coverage_can_pass_without_unrelated_extras_but_unknowns_block(self):
        from test_math_prerequisite_scope import reviewed,extra,snapshot,draft
        rows=snapshot();path=next(iter(SnapshotBackend(rows).files))
        value=reviewed()
        model=ScriptModel();model._responses=[read(path),decision(draft()),truth_decision(value)]
        _,details=await select_skills(model,MESSAGES,rows)
        self.assertEqual(details['prerequisite_review']['status'],'passed')
        self.assertEqual(details['prerequisite_review']['result'],value)
        # The same current branch cannot claim successful application with incomplete
        # coverage, fixed unknown truth, or a missing active prerequisite.
        for kind in ('coverage','fixed','additional'):
            value=reviewed()
            if kind=='coverage': value['methods'][0]['coverage_complete']=False
            elif kind=='fixed': value['methods'][0]['conditions'][0]['truth']=None
            else: value['methods'][0]['additional_prerequisites']=[extra(scope='required',truth=None,guard_truth=True)]
            model=ScriptModel();model._responses=[read(path),decision(draft()),truth_decision(value),truth_decision(reviewed())]
            with self.subTest(kind=kind),self.assertRaises(SkillError) as captured: await select_skills(model,MESSAGES,rows)
            self.assertEqual(captured.exception.code,'skillsPrerequisite')
            self.assertEqual(captured.exception.details['prerequisite_review']['result'],value)
            self.assertEqual(len(model._calls),3)
            self.assertEqual(len(model._responses),1)

    async def test_extra_additional_condition_id_is_rejected_after_only_syntax_repair(self):
        from test_math_prerequisite_scope import reviewed, extra, snapshot, draft
        rows=snapshot();path=next(iter(SnapshotBackend(rows).files))
        invalid=reviewed(extras=[extra()]);invalid['methods'][0]['additional_prerequisites'][0]['condition_id']='private_question_secret'
        model=ScriptModel();model._responses=[read(path),decision(draft()),malformed(json.dumps(reviewed())+'}'),truth_decision(invalid),truth_decision(reviewed())]
        with self.assertRaises(SkillError) as captured: await select_skills(model,MESSAGES,rows)
        self.assertEqual(captured.exception.issue,'review.methods[0].additional_prerequisites[0]:extra_field')
        self.assertEqual(len(model._calls),4)
        self.assertEqual(len(model._responses),1)


class JsonContractSDKTests(unittest.IsolatedAsyncioTestCase):
    async def test_actual_chat_sdk_extra_data_requires_full_replacement(self):
        rows=snapshots_for(skills());path=next(iter(SnapshotBackend(rows).files))
        ScriptedGateway.requests=[];ScriptedGateway.messages=[gateway_tool('read_file',json.dumps({'file_path':path}),0),gateway_tool('SkillSelection',answer(),1),gateway_tool('PrerequisiteTruth',truth_answer()+'}',2),gateway_tool('PrerequisiteTruth',truth_answer(),3)]
        server=ThreadingHTTPServer(('127.0.0.1',0),ScriptedGateway);threading.Thread(target=server.serve_forever,daemon=True).start()
        model=ChatOpenAI(model='test-model',api_key='fake-local-key',base_url=f'http://127.0.0.1:{server.server_port}/v1',max_retries=0)
        try:
            raw,details=await select_skills(model,MESSAGES,rows)
            self.assertEqual(json.loads(raw),json.loads(answer()))
            self.assertEqual(details['protocol_repairs'],['selection.json:extra_data'])
            self.assertEqual(len(ScriptedGateway.requests),4)
            self.assertIn('唯一完整JSON',ScriptedGateway.requests[-1]['messages'][-1]['content'])
        finally:
            server.shutdown();server.server_close()


if __name__=='__main__': unittest.main()
