import json
import unittest
from math_diagram_tools import normalize_tool_arguments, tool_schemas
from math_solution_contract import SolutionContractError
from math_path_submission import TOOL_NAME


class PathSubmissionTests(unittest.TestCase):
    def value(self):
        return dict(method_id=None, visual_method_ids=[], nodes=['A', 'B', 'C'],
                    node_locations=[{'node': n, 'location': '原图位置'+n, 'x': (0,800,0)[i], 'y': (0,0,800)[i]} for i,n in enumerate('ABC')],
                    edges=[{'from': 'A', 'to': 'B'}, {'from': 'A', 'to': 'C'}, {'from': 'C', 'to': 'B'}],
                    start='A', end='B', directed=False, source_evidence='三点两两连接', crossing_convention='无交叉')

    def test_public_tool_and_portable_native_envelope(self):
        for strict in (False, True):
            for scope in ('full', 'native_only'):
                schema = next(s for s in tool_schemas(strict, diagram_scope=scope) if s['function']['name'] == TOOL_NAME)
                self.assertNotIn('answer', schema['function']['parameters']['properties'])
                result = normalize_tool_arguments(TOOL_NAME, json.dumps(self.value()), strict=strict, diagram_scope=scope)
                self.assertEqual(set(result), {'schemaVersion', 'mode', 'method_id', 'visual_method_ids', 'answer', 'diagrams'})
                self.assertIn('合计：2条', result['answer'])
                self.assertIn('仍须核对原题', result['answer'])
                self.assertIn('尚未经过人工审核', result['answer'])
                self.assertIn('A—B；A—C；C—B', result['answer'])
                self.assertEqual(result['diagrams'], [])

    def test_invalid_graph_never_preserves_model_text(self):
        for patch in [dict(edges=[{'from':'A','to':'A'}]), dict(answer='999条'), dict(nodes=['A','A']), dict(directed=1)]:
            with self.subTest(patch=patch), self.assertRaises(SolutionContractError):
                normalize_tool_arguments(TOOL_NAME, json.dumps(self.value() | patch), preserve_general_answer=True)

    def test_locations_must_match_every_node_once_and_remain_distinct(self):
        locations = self.value()['node_locations']
        for invalid in [locations[:2], locations + [locations[0]],
                        [locations[0], locations[1], locations[2] | {'node': 'D'}],
                        [locations[0], locations[1], locations[2] | {'x': 0, 'y': 0}],
                        [locations[0], locations[1], locations[2] | {'location': ' '}],
                        [locations[0], locations[1], locations[2] | {'x': 1001}]]:
            with self.subTest(invalid=invalid), self.assertRaises(SolutionContractError):
                normalize_tool_arguments(TOOL_NAME, json.dumps(self.value() | {'node_locations': invalid}), preserve_general_answer=True)

    def test_edge_cannot_skip_declared_collinear_junction(self):
        value = self.value()
        value['node_locations'] = [{'node':n, 'location':n, 'x':x, 'y':0} for n,x in [('A',0),('B',1000),('C',500)]]
        with self.assertRaises(SolutionContractError) as error:
            normalize_tool_arguments(TOOL_NAME, json.dumps(value), preserve_general_answer=True)
        self.assertEqual(error.exception.diagnostic['rule'], 'edge_skips_declared_vertex')
