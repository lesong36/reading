import json
import unittest
from math_diagram_tools import GENERAL_TOOL_NAME, normalize_tool_arguments
from math_solution_contract import SolutionContractError

class InlineCubeContractTests(unittest.TestCase):
    def submit(self, block, **kwargs):
        value = {'method_id': None, 'visual_method_ids': [], 'answer': '解答保留。\n```math-cube-path\n'+block+'\n```', 'diagram_outcome': {'status':'inline_cube'}}
        return normalize_tool_arguments(GENERAL_TOOL_NAME, json.dumps(value, ensure_ascii=False), diagram_scope='native_only', **kwargs)

    def test_all_six_edges_pass(self):
        for edge in range(6):
            with self.subTest(edge=edge):
                output=self.submit(json.dumps({'title':'路线示意','edge':edge}, ensure_ascii=False))
                self.assertIn('解答保留', output['answer'])
                self.assertEqual(output['diagrams'], [])

    def test_invalid_preserves_answer(self):
        for block in ['{}', '{"title":"路线","edge":6}', '{"title":"路线","edge":true}', '{"title":"<svg>","edge":1}', '{"title":"路线","edge":1,"svg":"x"}', '{"title":"路线","edge":1,"edge":2}']:
            with self.subTest(block=block):
                with self.assertRaises(SolutionContractError): self.submit(block)
                output=self.submit(block, preserve_general_answer=True)
                self.assertIn('解答保留', output['answer'])
                self.assertIn(output['diagram_submission_failure'], ('submission_inline_cube', 'submission_shape'))

if __name__ == '__main__': unittest.main()
