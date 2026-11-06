import unittest
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from math_skill_catalogue import catalogue_for, catalogue_pages, catalogue_fingerprint, snapshot_bytes
from math_skills import SkillError, snapshots_for


def row(i, body="正文"):
    return {"id": str(i), "version_id": "v1", "title": "方法", "category": "补充", "instructions": body}


class CatalogueTests(unittest.TestCase):
    def test_large_inventory_pages_preserve_every_complete_body(self):
        raw = [row(i, "中文\\\n" * 18000) for i in range(4)]
        with self.assertRaises(SkillError):
            snapshots_for(raw)
        snapshots = catalogue_for(raw)
        pages = catalogue_pages(snapshots)
        self.assertGreater(len(pages), 1)
        self.assertEqual([r for page in pages for r in page], list(snapshots))
        for page in pages:
            self.assertLessEqual(sum(len(snapshot_bytes(r)) for r in page), 300000)
        self.assertEqual([r["instructions"] for r in snapshots], [r["instructions"] for r in raw])

    def test_cross_page_duplicate_identity_and_name_rejected(self):
        for raw in ([row(1), row(1)], [dict(row(1), skill_name="same"), dict(row(2), skill_name="same")]):
            with self.assertRaises(SkillError):
                catalogue_for(raw)

    def test_individual_limit_is_not_raised(self):
        with self.assertRaises(SkillError):
            catalogue_for([row(1, "界" * 100001)])
        with self.assertRaises(SkillError):
            catalogue_for([row(i) for i in range(513)])

    def test_fingerprint_binds_version_body_and_inventory_order(self):
        original = catalogue_for([row(1), row(2)])
        fingerprint = catalogue_fingerprint(original)
        for changed in ([row(2), row(1)], [dict(row(1), version_id="v2"), row(2)], [row(1, "更改"), row(2)]):
            self.assertNotEqual(fingerprint, catalogue_fingerprint(catalogue_for(changed)))
        self.assertEqual(fingerprint, catalogue_fingerprint(catalogue_for([row(1), row(2)])))

    def test_exact_byte_boundary_and_empty_inventory(self):
        base = row(1, "a")
        length = len(snapshot_bytes(snapshots_for([base])[0]))
        exact = row(1, "a" * (300000 - length + 1))
        snapshots = catalogue_for([exact, row(2)])
        self.assertEqual(len(snapshot_bytes(snapshots[0])), 300000)
        self.assertEqual([len(p) for p in catalogue_pages(snapshots)], [1, 1])
        self.assertEqual(catalogue_pages(catalogue_for([])), ())


class CatalogueTransportTests(unittest.IsolatedAsyncioTestCase):
    async def test_catalogue_is_rejected_outside_background_coverage(self):
        import question_engine as engine
        async def emit(event):
            self.fail("Invalid catalogue must not reach an output/model")
        for payload in (
            {"teaching_catalogue": []},
            {"task": "math_method_selection", "teaching_catalogue": []},
            {"task": "math_skill_learning", "learning": {}, "teaching_catalogue": [], "teaching_skills": []},
            {"task": "math_skill_learning", "learning": {"profile_review": {}}, "teaching_catalogue": []},
            {"task": "math_skill_learning", "learning": None, "teaching_catalogue": []},
        ):
            with self.assertRaises(engine.EngineError):
                await engine.stream_answer(payload, emit)
