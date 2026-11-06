"""Center-cut declarations are bounded schematics, never source measurements."""
import json
import unittest
import test_math_inline_grid_contract as grid
import test_math_solution_transport as wire
from math_solution_contract import SolutionContractError, normalize_arguments, tool_schema
from math_diagram_tools import GENERAL_TOOL_NAME, normalize_tool_arguments, tool_schemas


def plan():
    return {"title": "中心切割示意", "outerWidth": 10, "outerHeight": 8,
            "hole": {"x": 1, "y": 2, "width": 2, "height": 3}}


def answer(value=None, fence="```"):
    return "仅为归一化示意，仍须核对原题。\n" + fence + "math-center-cut\n" + json.dumps(plan() if value is None else value, ensure_ascii=False) + "\n" + fence


def submission(text=None):
    return {"mode": "general", "method_id": None, "visual_method_ids": [],
            "answer": answer() if text is None else text, "diagram_outcome": {"status": "inline_geometry"}}


def tools(value, **options):
    return normalize_tool_arguments(GENERAL_TOOL_NAME,
        json.dumps({key: item for key, item in value.items() if key != "mode"}, ensure_ascii=False), **options)


class CenterCutContractTests(unittest.TestCase):
    def test_schemas_expose_separate_status_only_in_general_full_scope(self):
        loose = tool_schema()["function"]["parameters"]
        branch = next(item for item in loose["properties"]["diagram_outcome"]["anyOf"]
                      if item["properties"]["status"]["enum"] == ["inline_geometry"])
        self.assertEqual(set(branch["properties"]), {"status"})
        native, general = tool_schema(True)["function"]["parameters"]["properties"]["solution"]["anyOf"]
        self.assertNotIn("inline_geometry", json.dumps(native))
        self.assertIn(["inline_geometry"], grid.outcome_statuses(general))
        for strict in (False, True):
            full = tool_schemas(strict)[-1]["function"]["parameters"]
            self.assertIn(["inline_geometry"], grid.outcome_statuses(full))
            scoped = tool_schemas(strict, diagram_scope="native_only")[-1]["function"]["parameters"]
            for status in ("inline_geometry", "renderable"):
                self.assertNotIn([status], grid.outcome_statuses(scoped))

    def test_normalization_preserves_complete_fence_without_omission_or_approval(self):
        for text in (answer(), answer(fence="~~~"), answer() + "`", answer().replace("\n", "\r\n")):
            value = submission(text)
            for strict in (False, True):
                result = normalize_arguments(json.dumps({"solution": value} if strict else value), strict=strict)
                self.assertEqual(set(result), {"schemaVersion", "mode", "method_id", "visual_method_ids", "answer", "diagrams"})
                self.assertEqual(result["answer"], text)
                self.assertEqual(result["diagrams"], [])
                self.assertEqual(tools(value, strict=strict), result)

    def test_minimum_coordinate_and_aspect_boundaries_are_accepted(self):
        value = {"title": "边界示意", "outerWidth": 0.2, "outerHeight": 0.01,
                 "hole": {"x": 0.001, "y": 0.001, "width": 0.001, "height": 0.001}}
        self.assertEqual(tools(submission(answer(value)))["answer"], answer(value))

    def test_native_and_extra_outcome_fields_reject(self):
        value = submission(); value["mode"] = "native_recipe"
        with self.assertRaises(SolutionContractError) as caught:
            normalize_arguments(json.dumps(value))
        self.assertEqual(caught.exception.issue, "submission_mode")
        for extra in ({"reason": "schematic"}, {"primary_diagram": {}}, {"additional_diagrams": []}):
            value = submission(); value["diagram_outcome"].update(extra)
            with self.assertRaises(SolutionContractError):
                tools(value)

    def test_malformed_and_unmatched_fences_fail_without_leaking_payload(self):
        texts = ["text", answer().rsplit("\n", 1)[0], "```math-center-cut\n{}\n```",
                 "```math-center-cut\n{SECRET\n```", "````text\n" + answer() + "\n````",
                 answer() + "\n~~~math-center-cut\n{}", grid.answer(),
                 "```math-center-cut\n" + " " * 2001 + "\n```"]
        for text in texts:
            with self.subTest(text=text[:100]):
                with self.assertRaises(SolutionContractError) as caught:
                    tools(submission(text))
                self.assertEqual(caught.exception.issue, "submission_inline_geometry")
                self.assertEqual(caught.exception.diagnostic["path"], "$.answer")
                self.assertNotIn("SECRET", str(caught.exception))

    def test_geometry_is_finite_positive_strictly_inside_and_exact_shape(self):
        bad = []
        for key, values in {"outerWidth": [0, 0.0001, -1, True, 1001, float("inf"), float("nan")],
                            "outerHeight": [0, 5, 1000], "title": ["", "x" * 121, "bad\nline", "<b>title</b>", "😀" * 61]}.items():
            for value in values:
                item = plan(); item[key] = value; bad.append(item)
        for key, values in {"x": [0, 0.0001, -1, True, 8], "y": [0, -1, 5], "width": [0, -1, 9],
                            "height": [0, -1, 6]}.items():
            for value in values:
                item = plan(); item["hole"][key] = value; bad.append(item)
        for field in ("cut", "outerX", "evidence"):
            item = plan(); item[field] = "SECRET"; bad.append(item)
        item = plan(); item["hole"]["label"] = "SECRET"; bad.append(item)
        for item in bad:
            with self.subTest(item=item):
                with self.assertRaises(SolutionContractError) as caught:
                    tools(submission(answer(item)))
                self.assertEqual(caught.exception.issue, "submission_inline_geometry")
        for raw in [answer().replace('"outerWidth": 10', '"outerWidth": 10,"outerWidth": 9'),
                    answer().replace('"outerWidth": 10', '"outerWidth": 1e999')]:
            with self.assertRaises(SolutionContractError):
                tools(submission(raw))

    def test_failed_geometry_preserves_usable_answer_with_no_omission(self):
        for scope, text in [("full", "完整解答。\n```math-center-cut\n{SECRET\n```"),
                            ("native_only", answer())]:
            for strict in (False, True):
                result = tools(submission(text), strict=strict, diagram_scope=scope, preserve_general_answer=True)
                self.assertEqual(result["answer"], text)
                self.assertEqual(result["diagrams"], [])
                self.assertEqual(result["diagram_submission_failure"], "submission_shape")
                self.assertNotIn("diagram_omission", result)


class CenterCutWireTests(unittest.IsolatedAsyncioTestCase):
    setUpClass = classmethod(wire.SingleSubmissionWireTests.setUpClass.__func__)
    tearDownClass = classmethod(wire.SingleSubmissionWireTests.tearDownClass.__func__)
    setUp = wire.SingleSubmissionWireTests.setUp
    payload = wire.SingleSubmissionWireTests.payload
    invoke = wire.SingleSubmissionWireTests.invoke

    async def test_valid_malformed_and_excluded_geometry_each_use_one_call(self):
        for scope, text, failed in [("full", answer(), False),
                                   ("full", "完整解答。\n```math-center-cut\n{SECRET\n```", True),
                                   ("native_only", answer(), True)]:
            with self.subTest(scope=scope, failed=failed):
                wire.SubmissionHandler.requests.clear()
                wire.SubmissionHandler.tool_name = GENERAL_TOOL_NAME
                value = submission(text)
                wire.SubmissionHandler.arguments = json.dumps(
                    {key: item for key, item in value.items() if key != "mode"}, ensure_ascii=False)
                events = await self.invoke(self.payload() | {"solution_protocol": "renderer_tools", "diagram_scope": scope})
                self.assertEqual([event["type"] for event in events], ["done"], events)
                output = json.loads(events[-1]["text"])
                self.assertEqual(output["answer"], text)
                self.assertEqual(output["diagrams"], [])
                self.assertEqual("diagram_submission_failure" in output, failed)
                self.assertNotIn("diagram_omission", output)
                self.assertEqual(len(wire.SubmissionHandler.requests), 1)
                self.assertEqual(wire.SubmissionHandler.requests[0][2]["tool_choice"], "required")


if __name__ == "__main__":
    unittest.main()
