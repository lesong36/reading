import json
import unittest
from math_diagram_tools import GENERAL_TOOL_NAME, normalize_tool_arguments
from math_solution_contract import SolutionContractError

class InlineHexagonContractTests(unittest.TestCase):
    def submit(self, blocks, **kwargs):
        answer = '解答保留。\n' + '\n'.join('```math-hexagon-partition\n'+b+'\n```' for b in blocks)
        value = {'method_id': None, 'visual_method_ids': [], 'answer': answer,
                 'diagram_outcome': {'status': 'inline_hexagon'}}
        return normalize_tool_arguments(GENERAL_TOOL_NAME, json.dumps(value, ensure_ascii=False), diagram_scope='native_only', **kwargs)

    def test_all_presets_are_preserved(self):
        result = self.submit(['{"sides":3}', '{"sides":4}', '{"sides":5}'])
        self.assertIn('{"sides":4}', result['answer'])
        self.assertEqual(result['diagrams'], [])

    def test_invalid_preserves_text_without_accepting_plan(self):
        for block in ['{}', '{"sides":6}', '{"sides":true}', '{"sides":5,"sides":13}', '{"sides":5,"svg":"x"}']:
            with self.subTest(block=block):
                with self.assertRaises(SolutionContractError): self.submit([block])
                output = self.submit([block], preserve_general_answer=True)
                self.assertIn('解答保留', output['answer'])
                self.assertIn(output['diagram_submission_failure'], ('submission_inline_hexagon', 'submission_shape'))
