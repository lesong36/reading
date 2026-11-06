"""Recorded one-call chat wire verifies inline grids are diagrams, not omissions."""
import json
import unittest
import test_math_solution_transport as wire
import test_math_inline_grid_contract as grid
from math_diagram_tools import GENERAL_TOOL_NAME


class InlineGridWireTests(unittest.IsolatedAsyncioTestCase):
    # Reuse the established local HTTP fixture without inheriting/rerunning its tests.
    setUpClass = classmethod(wire.SingleSubmissionWireTests.setUpClass.__func__)
    tearDownClass = classmethod(wire.SingleSubmissionWireTests.tearDownClass.__func__)
    setUp = wire.SingleSubmissionWireTests.setUp
    payload = wire.SingleSubmissionWireTests.payload
    invoke = wire.SingleSubmissionWireTests.invoke

    async def test_inline_grid_uses_one_wire_call_and_keeps_six_fields_without_omission(self):
        wire.SubmissionHandler.tool_name = GENERAL_TOOL_NAME
        submitted = grid.value("实际A3切线与接缝：\n```math-grid\n" + grid.original_grid_blocks()[1] + "\n```")
        arguments = {key: item for key, item in submitted.items() if key != "mode"}
        wire.SubmissionHandler.arguments = json.dumps(arguments, ensure_ascii=False)
        events = await self.invoke(self.payload() | {"solution_protocol": "renderer_tools", "diagram_scope": "full"})
        self.assertEqual([event["type"] for event in events], ["done"], events)
        output = json.loads(events[-1]["text"])
        self.assertEqual(set(output), {"schemaVersion", "mode", "method_id", "visual_method_ids", "answer", "diagrams"})
        self.assertEqual(output["answer"], arguments["answer"])
        self.assertEqual(output["diagrams"], [])
        self.assertEqual(len(wire.SubmissionHandler.requests), 1)
        self.assertEqual(wire.SubmissionHandler.requests[0][2]["tool_choice"], "required")
        tools = wire.SubmissionHandler.requests[0][2]["tools"]
        general = next(tool for tool in tools if tool["function"]["name"] == GENERAL_TOOL_NAME)
        self.assertIn(["inline_grid"], grid.outcome_statuses(general["function"]["parameters"]))

    async def test_fast_grid_is_delivered_in_one_call(self):
        wire.SubmissionHandler.requests.clear()
        wire.SubmissionHandler.tool_name = GENERAL_TOOL_NAME
        submitted = grid.value()
        wire.SubmissionHandler.arguments = json.dumps({k: v for k, v in submitted.items() if k != "mode"}, ensure_ascii=False)
        events = await self.invoke(self.payload() | {"solution_protocol": "renderer_tools", "diagram_scope": "native_only"})
        self.assertEqual([event["type"] for event in events], ["done"])
        output = json.loads(events[-1]["text"])
        self.assertEqual(output["answer"], submitted["answer"])
        self.assertNotIn("diagram_submission_failure", output)
        self.assertEqual(len(wire.SubmissionHandler.requests), 1)

    async def test_bad_or_out_of_scope_grid_keeps_answer_as_failed_submission_without_retry(self):
        for scope, text in [("full", "文字解答仍保留。\n```math-grid\n{SECRET\n```"),
                            ("native_only", "文字解答仍保留。\n```math-grid\n{SECRET\n```")]:
            with self.subTest(scope=scope):
                wire.SubmissionHandler.requests.clear()
                wire.SubmissionHandler.tool_name = GENERAL_TOOL_NAME
                submitted = grid.value(text)
                arguments = {key: item for key, item in submitted.items() if key != "mode"}
                wire.SubmissionHandler.arguments = json.dumps(arguments, ensure_ascii=False)
                events = await self.invoke(self.payload() | {"solution_protocol": "renderer_tools", "diagram_scope": scope})
                self.assertEqual([event["type"] for event in events], ["done"], events)
                output = json.loads(events[-1]["text"])
                self.assertEqual(output["answer"], text)
                self.assertEqual(output["diagrams"], [])
                self.assertIn(output["diagram_submission_failure"], ("submission_shape", "submission_inline_grid"))
                self.assertNotIn("diagram_omission", output)
                self.assertEqual(len(wire.SubmissionHandler.requests), 1)


if __name__ == "__main__":
    unittest.main()
