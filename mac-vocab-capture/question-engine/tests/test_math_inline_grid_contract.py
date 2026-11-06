"""Inline grids are inert bounded answer content, not native diagrams or approval."""
import copy
import json
from pathlib import Path
import re
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from math_solution_contract import SolutionContractError, normalize_arguments, tool_schema
from math_diagram_tools import GENERAL_TOOL_NAME, normalize_tool_arguments, tool_schemas


def plan():
    return {"title": "阶梯分块", "unitWidth": 5, "unitHeight": 4,
            "source": [["A", "B"]], "target": [["A", "B"]]}


def answer(grid=None, fence="```"):
    return "先说明切线与各块去向。\n\n" + fence + "math-grid\n" + json.dumps(grid or plan(), ensure_ascii=False) + "\n" + fence


def value(text=None):
    return {"mode": "general", "method_id": None, "visual_method_ids": [],
            "answer": text if text is not None else answer(), "diagram_outcome": {"status": "inline_grid"}}


def normalize_tools(submission, **options):
    parameters = {key: item for key, item in submission.items() if key != "mode"}
    return normalize_tool_arguments(GENERAL_TOOL_NAME, json.dumps(parameters, ensure_ascii=False), **options)


def original_grid_blocks():
    skill = Path(__file__).resolve().parents[2] / "Sources/VocabCapture/Resources/MathSkills/rectangle-staircase-reassembly/SKILL.md"
    return re.findall(r"```math-grid\n(.*?)\n```", skill.read_text(), re.S)


def outcome_statuses(schema):
    return [branch["properties"]["status"]["enum"]
            for branch in schema["properties"]["diagram_outcome"]["anyOf"]]


class InlineGridContractTests(unittest.TestCase):
    def test_general_and_strict_wire_schemas_have_status_without_fake_reason(self):
        loose = tool_schema()["function"]["parameters"]
        branches = loose["properties"]["diagram_outcome"]["anyOf"]
        inline = next(branch for branch in branches if branch["properties"]["status"]["enum"] == ["inline_grid"])
        self.assertEqual(set(inline["properties"]), {"status"})
        strict = tool_schema(strict=True)["function"]["parameters"]
        native, general = strict["properties"]["solution"]["anyOf"]
        self.assertNotIn("inline_grid", json.dumps(native))
        self.assertIn(["inline_grid"], outcome_statuses(general))
        for strict_mode in (False, True):
            tool = next(tool for tool in tool_schemas(strict=strict_mode) if tool["function"]["name"] == GENERAL_TOOL_NAME)
            self.assertIn(["inline_grid"], outcome_statuses(tool["function"]["parameters"]))
            scoped = tool_schemas(strict=strict_mode, diagram_scope="native_only")[-1]["function"]["parameters"]
            self.assertIn(["inline_grid"], outcome_statuses(scoped))
            self.assertNotIn(["renderable"], outcome_statuses(scoped))
            self.assertNotIn("$defs", scoped)
            self.assertNotIn("$def", scoped)

    def test_actual_source_figures_round_trip_six_field_envelope_and_no_second_submission(self):
        fixtures = original_grid_blocks()
        self.assertEqual(len(fixtures), 2)
        for fixture in fixtures:
            submitted = value("实际切线：\n```math-grid\n" + fixture + "\n```")
            for strict in (False, True):
                raw = json.dumps({"solution": submitted} if strict else submitted, ensure_ascii=False)
                output = normalize_arguments(raw, strict=strict)
                self.assertEqual(set(output), {"schemaVersion", "mode", "method_id", "visual_method_ids", "answer", "diagrams"})
                self.assertEqual(output["answer"], submitted["answer"])
                self.assertEqual(output["diagrams"], [])
                self.assertIsNone(output["method_id"])
                self.assertNotIn("图解说明", output["answer"])
                self.assertEqual(normalize_tools(submitted, strict=strict), output)
                self.assertEqual(json.loads(json.dumps(output, ensure_ascii=False)), output)

    def test_native_recipe_and_extra_inline_fields_reject(self):
        native = value(); native["mode"] = "native_recipe"
        with self.assertRaises(SolutionContractError) as caught:
            normalize_arguments(json.dumps(native))
        self.assertEqual(caught.exception.issue, "submission_mode")
        for extra in ({"reason": "not an omission"}, {"primary_diagram": {}}, {"additional_diagrams": []}):
            submitted = value(); submitted["diagram_outcome"].update(extra)
            with self.assertRaises(SolutionContractError):
                normalize_tools(submitted)

    def test_malformed_incomplete_or_non_grid_answers_reject_without_leaking_input(self):
        for text in ["只有文字。", "```math-grid\n{}", "```math-grid\n{}\n```",
                     "```math-grid\nnot JSON SECRET\n```", "```math-grid\n[]\n```",
                     "````text\n" + answer() + "\n````", answer() + "\n```math-grid\n{}"]:
            with self.subTest(text=text):
                with self.assertRaises(SolutionContractError) as caught:
                    normalize_tools(value(text))
                self.assertEqual(caught.exception.issue, "submission_inline_grid")
                self.assertNotIn("SECRET", str(caught.exception))
                self.assertEqual(caught.exception.diagnostic["path"], "$.answer")

    def test_complete_tilde_and_longer_closing_fences_and_crlf_are_supported(self):
        for text in [answer(fence="~~~"), answer() + "`", answer().replace("\n", "\r\n")]:
            self.assertEqual(normalize_tools(value(text))["answer"], text)

    def test_bad_grid_keeps_complete_answer_only_through_existing_failure_isolation(self):
        submitted = value("完整文字解答保留。\n```math-grid\n{SECRET\n```")
        for strict in (False, True):
            output = normalize_tools(submitted, strict=strict, preserve_general_answer=True)
            self.assertEqual(output["answer"], submitted["answer"])
            self.assertEqual(output["diagrams"], [])
            self.assertEqual(output["diagram_submission_failure"], "submission_shape")
            self.assertNotIn("diagram_omission", output)
            self.assertNotIn("图解说明", output["answer"])
        # Fast scope accepts valid bounded grid; malformed grid preserves text.
        fast = normalize_tools(value(), diagram_scope="native_only")
        self.assertEqual(fast["answer"], value()["answer"])
        broken = value("文字解答。\n```math-grid\n{}\n```")
        preserved = normalize_tools(broken, diagram_scope="native_only", preserve_general_answer=True)
        self.assertIn(preserved["diagram_submission_failure"], ("submission_inline_grid", "submission_shape"))
        self.assertIn("文字解答", preserved["answer"])

    def test_inert_bounds_reject_bad_units_rows_labels_unknown_keys_and_size(self):
        bad = []
        for field, item in [("unitWidth", 0), ("unitHeight", True), ("unitWidth", 1001), ("unitHeight", 0.0000001),
                            ("unitHeight", 0.1234567), ("title", ""), ("title", "bad\nline"), ("title", "x" * 121),
                            ("source", []), ("source", [["A"], ["A", "B"]]), ("source", [[""]]),
                            ("source", [["A" * 13]]), ("source", [[" A"]]), ("source", [["A\n"]]),
                            ("source", [["A"]] * 17)]:
            grid = plan(); grid[field] = item; bad.append(answer(grid))
        grid = plan(); grid["script"] = "SECRET"; bad.append(answer(grid))
        bad.append(answer().replace('"unitWidth": 5', '"unitWidth": 1e999'))
        bad.append(answer().replace('"unitWidth": 5', '"unitWidth": NaN'))
        bad.append(answer().replace('"unitWidth": 5', '"unitWidth": 5,"unitWidth": 6'))
        bad.append("```math-grid\n" + " " * 30001 + "\n```")
        for text in bad:
            with self.subTest(text=text[:100]):
                with self.assertRaises(SolutionContractError) as caught:
                    normalize_tools(value(text))
                self.assertEqual(caught.exception.issue, "submission_inline_grid")

    def test_transport_presence_does_not_claim_geometry_valid_or_approve_anything(self):
        grid = plan(); grid["source"] = [["A", "A"]]; grid["target"] = [["A"], ["A"]]
        # This anisotropic quarter-turn is shape-valid inert data but will fail WebView rigid checks.
        output = normalize_tools(value(answer(grid)))
        self.assertEqual(output["diagrams"], [])
        self.assertEqual(set(output), {"schemaVersion", "mode", "method_id", "visual_method_ids", "answer", "diagrams"})
        self.assertNotIn("approved", json.dumps(output))
        for status in ("no_helpful_diagram", "unreadable_or_insufficient"):
            submitted = value("文字解答。")
            submitted["diagram_outcome"] = {"status": status, "reason": "没有适用的图。"}
            result = normalize_tools(submitted)
            self.assertEqual(result["diagrams"], [])
            self.assertIn("图解说明：没有适用的图。", result["answer"])


if __name__ == "__main__":
    unittest.main()
