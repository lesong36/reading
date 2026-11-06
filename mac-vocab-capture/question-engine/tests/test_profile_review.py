import hashlib
import json
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from langchain_core.messages import HumanMessage
from math_learning import learn_skills
from math_skills import SkillError
from test_math_learning import Model, evidence, review


def profile():
    return {'method_id': 'known', 'version_id': 'exact-version', 'binding_digest': 'a' * 64,
            'instructions': '  完整方法：先求总差，再除以单位差，核对原题全部条件。\n',
            'trigger': '同总量两次分配', 'constraints': '四年级算术不用方程',
            'exclusions': ['总数不同不能用'], 'prerequisites': ['整数乘除'],
            'diagram_templates': ['table'], 'evidence': evidence(),
            'source_references': [{'locator': 'known/SKILL.md', 'sha256': 'b' * 64}]}


class ProfileReviewTests(unittest.IsolatedAsyncioTestCase):
    async def run_review(self, value, outputs):
        model = Model(outputs)
        output, execution = await learn_skills(model, [HumanMessage('审校精确版本')], [], {'profile_review': value})
        return json.loads(output), execution, model

    async def test_exact_source_and_binding_preserved_without_approval(self):
        value = profile()
        result, execution, model = await self.run_review(value, [review()])
        self.assertEqual(result['binding_digest'], value['binding_digest'])
        self.assertEqual(result['source_sha256'], hashlib.sha256(value['instructions'].encode()).hexdigest())
        self.assertEqual(result['status'], 'awaiting_human')
        self.assertEqual(result['version_id'], value['version_id'])
        self.assertNotIn('human_decision', result)
        self.assertNotIn('workflow_state', result)
        self.assertFalse(execution['human_interrupt'])
        self.assertEqual(execution['mode'], 'langgraph_profile_review')
        self.assertEqual(model.calls, 1)

    async def test_missing_evidence_cannot_receive_all_passes(self):
        value = profile(); value['evidence'] = []; value['exclusions'] = []
        result, _, _ = await self.run_review(value, [review()])
        self.assertEqual(result['status'], 'review_required')
        failed = {c['dimension'] for c in result['review']['checks'] if not c['passed']}
        self.assertEqual(failed, {'mathematics', 'counterexamples', 'conditions'})
        self.assertEqual(result['review']['recommendation'], 'needs_revision')

    async def test_positive_sources_do_not_substitute_for_counterexample(self):
        value = profile(); value['evidence'] = value['evidence'][:3]
        result, _, _ = await self.run_review(value, [review()])
        self.assertEqual(result['review']['recommendation'], 'needs_revision')
        self.assertFalse(next(c for c in result['review']['checks'] if c['dimension'] == 'counterexamples')['passed'])

    async def test_single_repair_budget(self):
        result, execution, model = await self.run_review(profile(), ['bad JSON', review(False)])
        self.assertEqual(model.calls, 2)
        self.assertEqual(execution['model_calls'], 2)
        self.assertEqual(result['status'], 'review_required')
        model = Model(['bad', 'bad', review()])
        with self.assertRaises(SkillError):
            await learn_skills(model, [], [], {'profile_review': profile()})
        self.assertEqual(model.calls, 2)

    async def test_invalid_inputs_rejected_before_call_and_no_resume(self):
        for key, invalid in [('instructions', '原' * 32_001), ('binding_digest', 'x' * 64),
                             ('diagram_templates', ['unsupported']), ('evidence', None),
                             ('source_references', [{'locator': 'source', 'sha256': 'bad'}])]:
            value = profile(); value[key] = invalid
            model = Model([review()])
            with self.assertRaises(SkillError):
                await learn_skills(model, [], [], {'profile_review': value})
            self.assertEqual(model.calls, 0)
        with self.assertRaises(SkillError):
            await learn_skills(Model(), [], [], {'profile_review': profile(), 'decision': {'action': 'approve'}})

    async def test_bad_dimensions_or_fabricated_approval_cannot_pass(self):
        malformed = review(); malformed['checks'][1] = dict(malformed['checks'][0])
        with self.assertRaises(SkillError):
            await self.run_review(profile(), [malformed, malformed])
        malformed = review(); malformed['approved'] = True
        with self.assertRaises(SkillError):
            await self.run_review(profile(), [malformed, malformed])

    async def test_truncated_response_never_retried(self):
        class Truncated(Model):
            async def ainvoke(self, messages, config=None):
                from langchain_core.messages import AIMessage
                self.calls += 1
                return AIMessage(content=json.dumps(review()), response_metadata={'finish_reason': 'length'})
        model = Truncated()
        with self.assertRaisesRegex(SkillError, 'learningTruncated'):
            await learn_skills(model, [], [], {'profile_review': profile()})
        self.assertEqual(model.calls, 1)

    async def test_existing_method_format_failure_identifies_stage(self):
        model = Model(['bad JSON', 'bad JSON'])
        with self.assertRaises(SkillError) as caught:
            await learn_skills(model, [], [], {'profile_review': profile()})
        self.assertEqual((caught.exception.code, caught.exception.stage, caught.exception.issue,
                          caught.exception.model_calls), ('learningOutput', 'profile_review', 'json_invalid', 2))
        self.assertIn('json_invalid', model.prompts[1])


if __name__ == '__main__': unittest.main()
