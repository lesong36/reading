"""The fast request keeps native recipes, never silently restores general graphs."""
import json
import unittest
from test_math_diagram_tools import general, native
from math_diagram_tools import GENERAL_TOOL_NAME, normalize_tool_arguments, tool_schemas
from math_solution_contract import SolutionContractError


class NativeDiagramScopeTests(unittest.TestCase):
    def test_native_schemas_are_unchanged_including_strict_mode(self):
        for strict in (False, True):
            full = tool_schemas(strict=strict)
            fast = tool_schemas(strict=strict, diagram_scope="native_only")
            self.assertEqual(full[:-1], fast[:-1])
            # The native scope includes the four bounded non-rendering solvers
            # in addition to the thirteen native recipes and the fallback.
            self.assertEqual(len(fast), 18)
            self.assertEqual(
                [tool["function"]["name"] for tool in fast[-5:]],
                ["count_simple_graph_paths", "solve_equal_sum_grid",
                 "solve_reported_digit_game", "solve_reflected_meetings",
                 "submit_general_math_solution"],
            )
            fallback = fast[-1]["function"]["parameters"]
            self.assertNotIn("$defs", fallback)
            self.assertNotIn("$def", fallback)
            self.assertNotIn("quantity_plan", json.dumps(fallback))
            branches = fallback["properties"]["diagram_outcome"]["anyOf"]
            self.assertEqual(len(branches), 7)
            self.assertIn(["inline_grid"], [b["properties"]["status"]["enum"] for b in branches])
            self.assertIn(["inline_cube"], [b["properties"]["status"]["enum"] for b in branches])
            self.assertIn(["inline_triangle"], [b["properties"]["status"]["enum"] for b in branches])
            self.assertIn(["inline_hexagon"], [b["properties"]["status"]["enum"] for b in branches])
            self.assertIn(["inline_route"], [b["properties"]["status"]["enum"] for b in branches])
            self.assertIn(["inline_rectangle_dissection"], [b["properties"]["status"]["enum"] for b in branches])
            branches = [b for b in branches if b["properties"]["status"]["enum"] not in (["inline_grid"], ["inline_cube"], ["inline_triangle"])]
            self.assertEqual(branches[0]["properties"]["status"]["enum"],
                             ["unreadable_or_insufficient", "no_helpful_diagram", "user_requested_text_only"])
            self.assertEqual(set(branches[0]["properties"]), {"status", "reason"})
            self.assertLess(len(json.dumps(fast)), len(json.dumps(full)))
            self.assertEqual(tool_schemas(strict=strict, diagram_scope="full"), full)

    def test_native_recipe_still_normalizes_identically(self):
        for strict in (False, True):
            args = json.dumps(native())
            full = normalize_tool_arguments("render_difference_ratio", args, strict=strict)
            fast = normalize_tool_arguments("render_difference_ratio", args, strict=strict,
                                            diagram_scope="native_only")
            self.assertEqual(full, fast)

    def test_omission_branches_keep_complete_answer(self):
        for status in ("unreadable_or_insufficient", "no_helpful_diagram"):
            value = {"method_id": None, "visual_method_ids": [], "answer": "115×2×12=2760（元）。",
                     "diagram_outcome": {"status": status, "reason": "所列图解工具不适用，保留完整算术解答。"}}
            for strict in (False, True):
                output = normalize_tool_arguments(GENERAL_TOOL_NAME, json.dumps(value), strict=strict,
                                                  diagram_scope="native_only")
                self.assertTrue(output["answer"].startswith(value["answer"]))
                self.assertIn(value["diagram_outcome"]["reason"], output["answer"])
                self.assertEqual(output["diagrams"], [])
                self.assertNotIn("diagram_submission_failure", output)

    def test_text_only_status_still_requires_explicit_user_authorization(self):
        value = {"method_id": None, "visual_method_ids": [], "answer": "完整文字解答。",
                 "diagram_outcome": {"status": "user_requested_text_only", "reason": "用户要求只看文字。"}}
        raw = json.dumps(value)
        with self.assertRaises(SolutionContractError):
            normalize_tool_arguments(GENERAL_TOOL_NAME, raw, diagram_scope="native_only")
        result = normalize_tool_arguments(GENERAL_TOOL_NAME, raw, diagram_scope="native_only",
                                          text_only_authorized=True)
        self.assertEqual(result["diagrams"], [])
        self.assertTrue(result["answer"].startswith(value["answer"]))

    def test_general_graph_is_rejected_or_text_only_preserved_never_salvaged(self):
        for strict in (False, True):
            for broken_metadata in (False, True):
                value = general()
                if broken_metadata:
                    value["method_id"] = ["invalid"]
                raw = json.dumps(value)
                with self.assertRaises(SolutionContractError):
                    normalize_tool_arguments(GENERAL_TOOL_NAME, raw, strict=strict,
                                             diagram_scope="native_only")
                output = normalize_tool_arguments(GENERAL_TOOL_NAME, raw, strict=strict,
                    diagram_scope="native_only", preserve_general_answer=True)
                self.assertEqual(output["diagrams"], [])
                self.assertEqual(output["answer"], value["answer"])
                self.assertEqual(output["diagram_submission_failure"], "submission_shape")
        # The canonical opt-in/default path still accepts that same general graph.
        self.assertEqual(len(normalize_tool_arguments(GENERAL_TOOL_NAME, json.dumps(general()))["diagrams"]), 1)

    def test_native_invalid_recipe_preserves_incomplete_relation(self):
        value = native()
        del value["diagram"]["difference"]
        output = normalize_tool_arguments("render_difference_ratio", json.dumps(value),
            diagram_scope="native_only", preserve_general_answer=True)
        self.assertEqual(output["diagrams"], [])
        self.assertEqual(output["diagram_submission_failure"], "submission_relationship_only")

    def test_invalid_scope_does_not_fall_back_to_full(self):
        for invalid in (None, "", "native", [], {}):
            with self.assertRaises(ValueError):
                tool_schemas(diagram_scope=invalid)
