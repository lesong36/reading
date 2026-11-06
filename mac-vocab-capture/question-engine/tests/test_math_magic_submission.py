import json
import unittest
from math_diagram_tools import normalize_tool_arguments, tool_schemas
from math_magic_submission import TOOL_NAME
from math_solution_contract import SolutionContractError


class MagicSubmissionTests(unittest.TestCase):
    def value(self):
        return dict(method_id=None,visual_method_ids=[],grid=[[None,9,None,None,None],[3,7,8,2,None],[None,3,8,4,6],[8,4,None,2,3],[None,None,0,8,7]],diagonals=True,target={'row':1,'column':4},source_evidence='原图重复数字五阶方格，行列两对角线等和')

    def test_source_submission_generates_exact_answer_and_all_line_checks(self):
        for strict in (False,True):
            schema=next(t for t in tool_schemas(strict) if t['function']['name']==TOOL_NAME)
            self.assertNotIn('answer',schema['function']['parameters']['properties'])
            output=normalize_tool_arguments(TOOL_NAME,json.dumps(self.value()),strict=strict)
            self.assertEqual(set(output),{'schemaVersion','mode','method_id','visual_method_ids','answer','diagrams','diagram_omission'})
            self.assertEqual(output['diagram_omission']['status'],'no_helpful_diagram')
            self.assertIn(output['diagram_omission']['reason'],output['answer'])
            for text in ['唯一确定为：10','公共和为：26','各行和：26、26、26、26、26','各列和：26、26、26、26、26','两条主对角线和：26、26','尚未经过人工教学审核']:
                self.assertIn(text,output['answer'])
            for text in ['等和线的算术推理','比较第2行与第5列','20−（16）＝4','26−（16）＝10']:
                self.assertIn(text,output['answer'])
            self.assertNotIn('基础算术步骤尚未推出所问格',output['answer'])

    def test_underdetermined_and_inconsistent_do_not_claim_unique_answer(self):
        value=self.value()|dict(grid=[[None,None],[None,None]],target={'row':1,'column':1})
        output=normalize_tool_arguments(TOOL_NAME,json.dumps(value))
        self.assertIn('另一份有效示例',output['answer'])
        self.assertIn('基础算术步骤尚未推出所问格',output['answer'])
        output=normalize_tool_arguments(TOOL_NAME,json.dumps(value|dict(grid=[[1,2],[3,4]])))
        self.assertIn('互相冲突，不能给出答案',output['answer'])
        self.assertNotIn('完整表唯一确定',output['answer'])

    def test_invalid_grid_cannot_preserve_fabricated_model_answer(self):
        for patch in [dict(grid=[[1,2],[3]]),dict(answer='星号9'),dict(common_sum=25),dict(target={'row':6,'column':1})]:
            with self.subTest(patch=patch),self.assertRaises(SolutionContractError):
                normalize_tool_arguments(TOOL_NAME,json.dumps(self.value()|patch),preserve_general_answer=True)
