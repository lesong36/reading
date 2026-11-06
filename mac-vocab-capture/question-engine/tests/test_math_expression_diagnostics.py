"""Precise bounded feedback preserves rejected expressions and strict codes."""
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from math_prerequisite_arithmetic import ArithmeticWitnessError, evaluate_expression
from math_skills import SkillError, json_repair_guidance, daily_operand_origins
from langchain_core.messages import HumanMessage
from fractions import Fraction


class ExpressionDiagnosticsTests(unittest.TestCase):
    def test_rejected_shapes_have_fixed_details_without_echoing_expression(self):
        for expression, detail in [(' ', 'expression_empty'), ('q1×q2', 'expression_syntax'),
            ('q1+', 'expression_syntax'), ('SECRET_NAME', 'unknown_operand'),
            ('q1+8', 'literal_operand'), ('True', 'literal_operand'),
            ('q1//q2', 'unsupported_operator'), ('q1**2', 'unsupported_operator'),
            ('q1^q2', 'unsupported_operator'), ('q1.real', 'unsupported_expression'),
            ('q1<q2', 'unsupported_expression'), ("__import__('SECRET')", 'unsupported_expression')]:
            with self.subTest(expression=expression), self.assertRaises(ArithmeticWitnessError) as caught:
                evaluate_expression(expression, {'q1': Fraction(8), 'q2': Fraction(2)}, set())
            self.assertEqual(caught.exception.code, 'expression')
            self.assertEqual(caught.exception.detail, detail)
            self.assertNotIn('SECRET', str(caught.exception))
            issue='review.methods[0].conditions[0].arithmetic:'+detail
            self.assertEqual(SkillError('skillsOutput',issue=issue).issue,issue)
            self.assertTrue(json_repair_guidance(issue))

    def test_unknown_details_and_suffixes_are_not_forwarded(self):
        for detail in ['SECRET', {}, ['SECRET']]:
            self.assertEqual(ArithmeticWitnessError('expression',detail).detail,'expression')
        self.assertEqual(json_repair_guidance('review.methods[0].conditions[0].arithmetic:literal_operand:SECRET'),'')
        self.assertEqual(json_repair_guidance('selection.applicability:selected_identity_mismatch:SECRET'),'')

    def test_finite_source_arithmetic_is_unchanged(self):
        used=set()
        self.assertEqual(evaluate_expression('(q1*q1-q2)/(1+1)',{'q1':Fraction(3),'q2':Fraction(1)},used),Fraction(4))
        self.assertEqual(used,{'q1','q2'})

    def test_identity_and_source_feedback_require_real_resubmission(self):
        feedback=json_repair_guidance('selection.applicability:selected_identity_mismatch')
        self.assertIn('不得改成met',feedback)
        self.assertIn('同样可行但未采用',feedback)
        for code in ['problem_source','skill_source','source_value']:
            self.assertTrue(json_repair_guidance('review.methods[0].conditions[0].arithmetic:'+code))

    def test_daily_origin_schema_recognizes_explicit_chinese_numeric_sources(self):
        self.assertIn('problem_text', daily_operand_origins([HumanMessage('每行十棵，种了五行。')]))
        self.assertIn('problem_text', daily_operand_origins([HumanMessage('重5千克。')]))
        self.assertNotIn('problem_text', daily_operand_origins([HumanMessage('解释这个词语。')]))
        self.assertNotIn('problem_image', daily_operand_origins([HumanMessage('每行十棵。')]))

    def test_grade_metadata_does_not_make_image_numbers_user_text(self):
        image = HumanMessage([{'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,fixture'}}])
        for requirement in ('小学四年级，不使用方程。', '小学4年级；请验算。', '用户要求：四年级。'):
            self.assertEqual(daily_operand_origins([image, HumanMessage(requirement)]), ['skill', 'problem_image'])
        for actual in ('四年级有五个班。', '小学4年级，每班25人。', '四年级，原题三层，每层21级。'):
            self.assertIn('problem_text', daily_operand_origins([image, HumanMessage(actual)]))

    def test_native_request_header_is_not_a_literal_problem_quantity(self):
        image = HumanMessage([{'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,fixture'}}])
        header = '用户要求（按时间顺序，最后一条为本次要求）：\n'
        self.assertEqual(daily_operand_origins([image, HumanMessage(header + '不要使用方程，请使用小学生的知识领域解题，请验算确定答案的正确性。')]), ['skill', 'problem_image'])
        self.assertIn('problem_text', daily_operand_origins([image, HumanMessage(header + '每行十棵，五行。')]))


if __name__=='__main__':unittest.main()
