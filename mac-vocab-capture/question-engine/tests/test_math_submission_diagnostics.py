"""Diagnostics identify schema failures without recording provider values or keys."""
import json
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from math_diagram_tools import GENERAL_TOOL_NAME, normalize_tool_arguments
from math_solution_contract import SolutionContractError
from test_math_diagram_tools import native, general


class SubmissionDiagnosticTests(unittest.TestCase):
    def rejected(self, name, value, **kwargs):
        with self.assertRaises(SolutionContractError) as caught:
            normalize_tool_arguments(name, json.dumps(value), **kwargs)
        return caught.exception

    def test_missing_nested_field_names_exact_required_path(self):
        value = native()
        del value['diagram']['difference']['evidence']
        error = self.rejected('render_difference_ratio', value)
        self.assertEqual(error.issue, 'submission_shape')
        self.assertEqual(error.diagnostic, {'tool': 'render_difference_ratio',
            'path': '$.diagram.difference.evidence', 'rule': 'required'})

    def test_array_index_and_matching_discriminator_survive_anyof(self):
        value = general()
        value['diagram_outcome']['primary_diagram']['quantities'][0]['unknown'] = 'PRIVATE_VALUE'
        error = self.rejected(GENERAL_TOOL_NAME, value)
        self.assertEqual(error.diagnostic['path'], '$.diagram_outcome.primary_diagram.quantities[0].unknown')
        self.assertEqual(error.diagnostic['rule'], 'enum')
        self.assertNotIn('PRIVATE_VALUE', json.dumps(error.diagnostic))

    def test_unknown_keys_and_tool_names_never_enter_diagnostic(self):
        value = native()
        value['diagram']['PRIVATE_KEY'] = 'PRIVATE_VALUE'
        error = self.rejected('render_difference_ratio', value)
        self.assertEqual(error.diagnostic['path'], '$.diagram')
        self.assertEqual(error.diagnostic['rule'], 'additionalProperties')
        self.assertNotIn('PRIVATE', json.dumps(error.diagnostic))
        error = self.rejected('PRIVATE_TOOL', value)
        self.assertEqual(error.issue, 'submission_tool')
        self.assertIsNone(error.diagnostic)

    def test_number_rule_retains_existing_issue(self):
        value = native()
        value['diagram']['multiplier']['value'] = 1
        error = self.rejected('render_difference_ratio', value)
        self.assertEqual(error.issue, 'submission_number')
        self.assertEqual(error.diagnostic['path'], '$.diagram.multiplier.value')
        self.assertEqual(error.diagnostic['rule'], 'minimum')

    def test_salvage_success_preserves_existing_response_envelope(self):
        value = general()
        del value['diagram_outcome']['primary_diagram']['title']
        result = normalize_tool_arguments(GENERAL_TOOL_NAME, json.dumps(value), preserve_general_answer=True)
        self.assertEqual(result['answer'], value['answer'])
        self.assertEqual(result['diagram_submission_failure'], 'submission_shape')
        self.assertNotIn('diagram_submission_diagnostic', result)

    def test_control_failure_diagnostic_remains_available_in_strict_validation(self):
        value = general()
        value['visual_method_ids'] = 'PRIVATE_VALUE'
        error = self.rejected(GENERAL_TOOL_NAME, value)
        self.assertEqual(error.diagnostic, {'tool': GENERAL_TOOL_NAME,
            'path': '$.visual_method_ids', 'rule': 'type'})

    def test_legacy_submission_has_known_tool_name(self):
        from math_solution_contract import normalize_arguments
        with self.assertRaises(SolutionContractError) as caught:
            normalize_arguments('{}')
        self.assertEqual(caught.exception.diagnostic, {'tool': 'submit_math_solution',
            'path': '$.mode', 'rule': 'required'})

    def test_invalid_json_contains_no_values(self):
        with self.assertRaises(SolutionContractError) as caught:
            normalize_tool_arguments('render_difference_ratio', '{PRIVATE_VALUE')
        self.assertEqual(caught.exception.issue, 'submission_json')
        self.assertIsNone(caught.exception.diagnostic)


class SubmissionDiagnosticEventTests(unittest.IsolatedAsyncioTestCase):
    async def test_existing_error_event_retains_safe_diagnostic(self):
        import question_engine as engine
        from test_engine import request
        from test_math_failure_timings import Model, Pool
        payload = request()
        payload.update(response_mode='math_solution', solution_protocol='renderer_tools')
        events = []
        await engine.run_request(payload, events.append, Pool(Model()))
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]['submission_issue'], 'submission_shape')
        self.assertEqual(events[0]['submission_diagnostic'], {'tool': 'render_difference_ratio',
            'path': '$.method_id', 'rule': 'required'})
        self.assertIn('timings', events[0])
