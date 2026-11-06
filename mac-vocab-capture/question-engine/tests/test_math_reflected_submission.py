import unittest
import json
from math_diagram_tools import normalize_tool_arguments
from math_solution_contract import SolutionContractError


class ReflectedSubmissionTests(unittest.TestCase):
    def submit(self,starts,a=40,b=10):
        return normalize_tool_arguments('solve_reflected_meetings',json.dumps(dict(method_id=None,visual_method_ids=[],starts=starts,a=a,b=b,evidence='原题距离及端点条件')))

    def test_source_answers_arithmetic_and_ledgers(self):
        for starts,expected in [('same','70 或 90'),('opposite','55 或 65')]:
            answer=self.submit(starts)['answer']
            self.assertIn(expected,answer)
            self.assertIn('真正第二次迎面',answer)
            self.assertNotIn('L',answer)
            self.assertIn('没有更早的迎面相遇',answer)
        self.assertIn('|200|2|60|60|向右|',self.submit('same')['answer'])

    def test_transfer_and_reject_scope(self):
        self.assertIn('42 或 54',self.submit('same',24,6)['answer'])
        self.assertIn('33 或 39',self.submit('opposite',24,6)['answer'])
        with self.assertRaises(SolutionContractError):self.submit('same',10,10)

    def test_table_only_tool_rejects_unperformed_visual_method(self):
        value=dict(method_id=None,visual_method_ids=['line-diagram'],starts='opposite',a=40,b=10,evidence='原题')
        with self.assertRaises(SolutionContractError) as caught:
            normalize_tool_arguments('solve_reflected_meetings',json.dumps(value))
        self.assertEqual(caught.exception.diagnostic['path'],'$.visual_method_ids')
        self.assertEqual(caught.exception.diagnostic['rule'],'maxItems')
