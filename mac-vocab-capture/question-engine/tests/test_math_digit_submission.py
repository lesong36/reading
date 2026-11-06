import json
import unittest
from math_diagram_tools import normalize_tool_arguments
from math_solution_contract import SolutionContractError


class DigitSubmissionTests(unittest.TestCase):
    def value(self,**overrides):
        return dict(method_id=None,visual_method_ids=[],larger_hundreds=2,smaller_hundreds=1,
                    repeated_digits=True,turn_order='report_then_place',evidence='甲先报数，乙后填空；百位2、1，未禁止重复',**overrides)

    def submit(self,value):
        return normalize_tool_arguments('solve_reported_digit_game',json.dumps(value))

    def test_source_generated_complete_strategy_and_both_optimal_transcripts(self):
        result=self.submit(self.value())
        text=result['answer']
        self.assertIn('最后的差是140',text)
        self.assertIn('|被减数个位、减数十位|0、-1、-11、-21、-31、-41、-51、-61、-71、-81|0|0|',text.replace('$',''))
        self.assertIn('240－100＝140',text)
        self.assertIn('299－159＝140',text)
        self.assertIn('|9|被减数个位|9|81|90|',text)
        self.assertIn('|9|减数个位|-9|90|81|',text)
        self.assertIn('所有对手动作',text)
        self.assertEqual(result['diagrams'],[])
        self.assertEqual(result['visual_method_ids'],[])
        self.assertNotIn('10d',text)

    def test_transfer_hundreds_and_source_evidence_preserved(self):
        value=self.value();value.update(larger_hundreds=7,smaller_hundreds=3,method_id='source-method')
        result=self.submit(value)
        self.assertEqual(result['method_id'],'source-method')
        self.assertIn('最后的差是440',result['answer'])
        self.assertIn('740－300＝440',result['answer'])
        self.assertIn(value['evidence'],result['answer'])

    def test_rejects_unsupported_rules_types_and_visual_claims(self):
        for field,value in [('repeated_digits',False),('repeated_digits',1),('turn_order','place_then_report'),
                            ('larger_hundreds',True),('larger_hundreds',0),
                            ('smaller_hundreds',2),('visual_method_ids',['unperformed']),
                            ('answer','model-provided transcript')]:
            payload=self.value();payload[field]=value
            with self.subTest(field=field,value=value):
                with self.assertRaises(SolutionContractError):self.submit(payload)
