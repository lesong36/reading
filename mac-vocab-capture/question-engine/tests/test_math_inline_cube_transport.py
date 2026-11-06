"""Exercise the one-call provider transport for inline cube paths."""
import json
import unittest
import test_math_solution_transport as wire
import test_math_inline_grid_contract as grid
from math_diagram_tools import GENERAL_TOOL_NAME

class InlineCubeWireTests(unittest.IsolatedAsyncioTestCase):
    setUpClass = classmethod(wire.SingleSubmissionWireTests.setUpClass.__func__)
    tearDownClass = classmethod(wire.SingleSubmissionWireTests.tearDownClass.__func__)
    setUp = wire.SingleSubmissionWireTests.setUp
    payload = wire.SingleSubmissionWireTests.payload
    invoke = wire.SingleSubmissionWireTests.invoke

    async def test_valid_and_invalid_cube_one_call_preserves_answer(self):
        for edge, valid in [(2, True), (6, False)]:
            with self.subTest(edge=edge):
                wire.SubmissionHandler.requests.clear()
                wire.SubmissionHandler.tool_name = GENERAL_TOOL_NAME
                text = '沿表面经过共同棱中点。\n```math-cube-path\n' + json.dumps({'title':'路线示意','edge':edge}, ensure_ascii=False) + '\n```'
                args = {'method_id':None, 'visual_method_ids':[], 'answer':text,
                        'diagram_outcome':{'status':'inline_cube'}}
                wire.SubmissionHandler.arguments = json.dumps(args, ensure_ascii=False)
                events = await self.invoke(self.payload() | {'solution_protocol':'renderer_tools','diagram_scope':'native_only'})
                self.assertEqual([event['type'] for event in events], ['done'], events)
                output = json.loads(events[-1]['text'])
                self.assertEqual(output['answer'], text)
                self.assertEqual(output['diagrams'], [])
                self.assertEqual(len(wire.SubmissionHandler.requests), 1)
                request = wire.SubmissionHandler.requests[0][2]
                general = next(t for t in request['tools'] if t['function']['name'] == GENERAL_TOOL_NAME)
                self.assertIn(['inline_cube'], grid.outcome_statuses(general['function']['parameters']))
                if valid:
                    self.assertNotIn('diagram_submission_failure', output)
                else:
                    self.assertIn(output['diagram_submission_failure'], ('submission_shape','submission_inline_cube'))

if __name__ == '__main__':
    unittest.main()
