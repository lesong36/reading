"""Trust-boundary tests for project skill packs, using isolated catalogue copies."""
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("math_skills_validator", Path(__file__).resolve().parents[1] / "validate-math-skills.py")
validator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validator)


class MathSkillsValidatorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "MathSkills"
        shutil.copytree(validator.DEFAULT_ROOT, self.root)
        self.manifest = json.loads((self.root / "index.json").read_text())

    def write_manifest(self):
        (self.root / "index.json").write_text(json.dumps(self.manifest, ensure_ascii=False))

    def replace_skill(self, name, transform):
        entry = next(e for e in self.manifest["skills"] if e["name"] == name)
        path = self.root / entry["path"]
        path.write_bytes(transform(path.read_bytes()))
        entry["sha256"] = validator.sha256(path.read_bytes())
        self.write_manifest()

    def fails(self, text):
        with self.assertRaisesRegex(validator.ValidationError, text):
            validator.validate(self.root)

    def test_complete_project_catalogue(self):
        self.assertEqual(validator.validate(self.root), len(self.manifest["skills"]))

    def test_runtime_budget_counts_utf8_snapshots_including_metadata(self):
        snapshot = {"id": "method", "version_id": "version", "instructions": "字" * 100_000}
        with self.assertRaisesRegex(validator.ValidationError, "runtime snapshots"):
            validator.validate_runtime_budget([snapshot])
        snapshot["instructions"] = "small"
        validator.validate_runtime_budget([snapshot])

    def test_catalogue_may_exceed_request_budget_without_truncating_skills(self):
        rows = [{"id": str(i), "instructions": "完整方法与排除条件" * 2000} for i in range(12)]
        self.assertGreater(sum(len(json.dumps(row, ensure_ascii=False).encode()) for row in rows), 300_000)
        original = json.dumps(rows, ensure_ascii=False)
        validator.validate_catalogue_serviceability(rows)
        self.assertEqual(json.dumps(rows, ensure_ascii=False), original)
        with self.assertRaisesRegex(validator.ValidationError, "runtime snapshots"):
            validator.validate_runtime_budget(rows)

    def test_complete_single_skill_over_budget_is_rejected(self):
        row = {"id": "custom", "instructions": "界" * 100_001}
        original = row.copy()
        with self.assertRaisesRegex(validator.ValidationError, "runtime snapshots"):
            validator.validate_catalogue_serviceability([row])
        self.assertEqual(row, original)

    def test_request_budget_counts_exact_chinese_metadata_and_keeps_512_limit(self):
        row = {"id": "x", "instructions": "正文", "description": "中文权限说明"}
        base = len(json.dumps(row, ensure_ascii=False).encode())
        row["description"] += "a" * (300_000 - base)
        validator.validate_runtime_budget([row])
        row["description"] += "a"
        with self.assertRaisesRegex(validator.ValidationError, "runtime snapshots"):
            validator.validate_runtime_budget([row])
        validator.validate_runtime_budget([{"id": str(i)} for i in range(512)])
        with self.assertRaisesRegex(validator.ValidationError, "512"):
            validator.validate_runtime_budget([{"id": str(i)} for i in range(513)])

    def test_skill_edit_requires_manifest_hash(self):
        path = self.root / self.manifest["skills"][0]["path"]
        path.write_bytes(path.read_bytes() + b"\nChanged instruction\n")
        self.fails("SKILL.md hash mismatch")

    def test_manifest_rehash_does_not_hide_body_edit(self):
        self.replace_skill("sum-and-difference", lambda b: b + b"\nChanged instruction\n")
        self.fails("source digest mismatch")

    def test_untrusted_yaml_tag_is_not_executed(self):
        self.replace_skill("sum-and-difference", lambda b: b.replace(b'name: "sum-and-difference"', b'name: !!python/object:example {}'))
        self.fails("JSON-quoted string")

    def test_duplicate_frontmatter_rejected(self):
        self.replace_skill("sum-and-difference", lambda b: b.replace(b"metadata:\n", b'name: "sum-and-difference"\nmetadata:\n'))
        self.fails("duplicate frontmatter")

    def test_duplicate_json_key_rejected(self):
        (self.root / "index.json").write_text('{"schema_version":1,"schema_version":1,"skills":[]}')
        self.fails("duplicate JSON key")

    def test_duplicate_alias_rejected(self):
        alias = "0E3D9229-E5D9-4A2E-BEB9-48999815B3DF"
        self.manifest["skills"][0]["legacy_alias_ids"] = [alias]
        self.write_manifest()
        self.fails("duplicate source identity or alias")

    def test_duplicate_skill_name_rejected(self):
        self.manifest["skills"].append(self.manifest["skills"][0].copy())
        self.write_manifest()
        self.fails("duplicate skill name")

    def test_manifest_traversal_rejected(self):
        self.manifest["skills"][0]["path"] = "../outside/SKILL.md"
        self.write_manifest()
        self.fails("unexpected skill path")

    def test_symlink_rejected_even_when_unused(self):
        (self.root / "outside").symlink_to(Path(self.temp.name))
        self.fails("symlink is forbidden")

    def test_manifest_frontmatter_disagreement_rejected(self):
        self.manifest["skills"][0]["description"] = "different applicability"
        self.write_manifest()
        self.fails("discovery metadata mismatch")

    def test_missing_project_method_rejected(self):
        self.manifest["skills"].pop()
        self.write_manifest()
        self.fails("unreferenced files")

    def test_erratum_original_reference_tamper_rejected(self):
        path = self.root / "snail-climb/references/source.md"
        path.write_bytes(path.read_bytes() + b"\nTampered\n")
        self.fails("source digest mismatch")

    def test_erratum_body_tamper_rejected_independently(self):
        self.replace_skill("snail-climb", lambda b: b + b"\nTampered\n")
        self.fails("body digest mismatch")

    def test_reference_traversal_rejected(self):
        self.replace_skill("snail-climb", lambda b: b.replace(b'source_reference: "references/source.md"', b'source_reference: "../source.md"'))
        self.fails("unsafe relative path")

    def test_broken_wiki_link_rejected(self):
        def edit(data):
            top, metadata, body = validator.parse_skill(data)
            modified = body.replace("[[量率问题]]".encode(), "[[不存在方法]]".encode())
            return data.replace(metadata["source_sha256"].encode(), validator.sha256(modified).encode()).replace(body, modified)
        self.replace_skill("reverse-operations", edit)
        self.fails("unresolved wiki method link")

    def test_unreferenced_extra_skill_rejected(self):
        extra = self.root / "extra-method"
        extra.mkdir()
        (extra / "SKILL.md").write_text("unknown")
        self.fails("unreferenced files")

    def test_manifest_order_deterministic(self):
        self.manifest["skills"].reverse()
        self.write_manifest()
        self.fails("sorted by skill name")

    def test_schema_number_not_boolean(self):
        self.manifest["schema_version"] = True
        self.write_manifest()
        self.fails("integer 1")


if __name__ == "__main__":
    unittest.main()
