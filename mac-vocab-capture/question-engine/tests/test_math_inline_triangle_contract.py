import json
import unittest
from math_diagram_tools import GENERAL_TOOL_NAME, normalize_tool_arguments
from math_solution_contract import SolutionContractError

class InlineTriangleContractTests(unittest.TestCase):
    def submit(self, blocks, **kwargs):
        answer = '解答保留。\n' + '\n'.join('```math-triangle-dissection\n'+b+'\n```' for b in blocks)
        value = {'method_id': None, 'visual_method_ids': [], 'answer': answer,
                 'diagram_outcome': {'status': 'inline_triangle'}}
        return normalize_tool_arguments(GENERAL_TOOL_NAME, json.dumps(value, ensure_ascii=False), diagram_scope='native_only', **kwargs)

    def test_both_presets_are_preserved(self):
        result = self.submit(['{"pieces":5}', '{"pieces":13}'])
        self.assertIn('{"pieces":13}', result['answer'])
        self.assertEqual(result['diagrams'], [])

    def test_invalid_preserves_text_without_accepting_plan(self):
        for block in ['{}', '{"pieces":6}', '{"pieces":true}', '{"pieces":5,"pieces":13}', '{"pieces":5,"svg":"x"}']:
            with self.subTest(block=block):
                with self.assertRaises(SolutionContractError): self.submit([block])
                output = self.submit([block], preserve_general_answer=True)
                self.assertIn('解答保留', output['answer'])
                self.assertIn(output['diagram_submission_failure'], ('submission_inline_triangle', 'submission_shape'))

    def test_accepts_fixed_404_e03_case(self):
        result = self.submit(['{"case":"404-e03"}'])
        self.assertIn('"case":"404-e03"', result['answer'])

    def test_rejects_unknown_triangle_case(self):
        with self.assertRaises(SolutionContractError):
            self.submit(['{"case":"404-e99"}'])
