import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'verify-frozen-math-contract.py'
spec = importlib.util.spec_from_file_location('gate', SCRIPT)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class FakeArchive:
    def __init__(self, mutation=False, missing=False, stale_behavior=False):
        self.mutation, self.missing, self.stale_behavior = mutation, missing, stale_behavior

    def open_embedded_archive(self, name):
        return self

    def extract(self, name):
        if self.missing and name == 'math_simple_paths':
            raise KeyError(name)
        source = (gate.PROJECT / 'question-engine' / (name + '.py')).read_text()
        if self.stale_behavior and name == 'math_path_submission':
            source = source.replace("and (x-ax)*(x-bx) + (y-ay)*(y-by) < 0", "and False")
        if self.mutation and name == 'math_diagram_tools':
            source += '\n_original_tool_schemas = tool_schemas\ndef tool_schemas(*a, **kw):\n    return [s for s in _original_tool_schemas(*a, **kw) if s["function"]["name"] != "count_simple_graph_paths"]\n'
        return compile(source, name, 'exec')


class FrozenRendererGateTests(unittest.TestCase):
    def check(self, archive):
        with tempfile.NamedTemporaryFile() as executable, patch.object(gate, 'CArchiveReader', return_value=archive):
            return gate.check(Path(executable.name))

    def test_matching_all_six_schema_variants(self):
        result = self.check(FakeArchive())
        self.assertTrue(result['passed'])
        self.assertEqual(len(result['schemas']), 6)

    def test_legacy_schema_match_does_not_mask_missing_renderer_tool(self):
        result = self.check(FakeArchive(mutation=True))
        self.assertFalse(result['passed'])
        self.assertTrue(result['schemas']['normal']['matchesSource'])
        self.assertFalse(result['schemas']['renderer_normal_native_only']['matchesSource'])

    def test_missing_executable_dependency_fails_closed(self):
        with self.assertRaises(KeyError):
            self.check(FakeArchive(missing=True))

    def test_equal_schemas_do_not_mask_stale_executable_validation(self):
        result = self.check(FakeArchive(stale_behavior=True))
        self.assertTrue(all(item['matchesSource'] for item in result['schemas'].values()))
        self.assertFalse(result['graphBehavior']['frozen']['skippedVertexRejected'])
        self.assertFalse(result['passed'])
