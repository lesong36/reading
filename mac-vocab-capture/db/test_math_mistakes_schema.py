"""Validate the proposed SQLite schema without modifying any application data."""

from pathlib import Path
import json
import sqlite3
import unittest


SCHEMA = Path(__file__).with_name("math-mistakes-v1.sql").read_text()
ORIGINAL = "a" * 64
FIGURE = "b" * 64
STEM = r"如图，$AB=3\,\mathrm{cm}$，$AC=4\,\mathrm{cm}$，$\angle A=90^\circ$。求 $BC$。{{figure:f1}}"


class MathSchemaTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(":memory:")
        self.db.executescript(SCHEMA)
        for hash_value, width, height in ((ORIGINAL, 1000, 800), (FIGURE, 300, 200)):
            self.db.execute(
                "INSERT INTO assets(sha256,media_type,pixel_width,pixel_height,byte_count) VALUES(?, 'image/png', ?, ?, 100)",
                (hash_value, width, height),
            )
        self.db.execute("INSERT INTO questions(id,stem_markup,question_type) VALUES('q1',?,'mixed')", (STEM,))
        self.source("q1", "s1")
        self.db.commit()

    def tearDown(self):
        self.db.close()

    def source(self, question, source, ordinal=0):
        self.db.execute(
            "INSERT INTO question_sources(id,question_id,asset_sha256,ordinal,region_x,region_y,region_width,region_height) VALUES(?,?,?,?,0,0,1000,800)",
            (source, question, ORIGINAL, ordinal),
        )

    def figure(self, question="q1", source="s1", crop=FIGURE, x=100):
        self.db.execute(
            "INSERT INTO question_figures(id,question_id,source_id,crop_asset_sha256,ordinal,region_x,region_y,region_width,region_height) VALUES('f1',?,?,?,?,?,100,300,200)",
            (question, source, crop, 0, x),
        )

    def test_math_options_subquestions_and_figure_round_trip(self):
        self.db.execute("INSERT INTO question_parts(id,question_id,label,ordinal,body_markup) VALUES('p1','q1','(1)',0,?)", (r"求 $BC=\sqrt{3^2+4^2}$。",))
        self.db.execute("INSERT INTO question_options(id,question_id,part_id,label,ordinal,body_markup) VALUES('o1','q1','p1','A',0,?)", (r"$5\,\mathrm{cm}$",))
        self.figure()
        self.db.execute("UPDATE questions SET review_state='confirmed',reviewed_at='2026-10-06T00:00:00Z' WHERE id='q1'")
        self.assertEqual(self.db.execute("SELECT stem_markup FROM questions").fetchone()[0], STEM)
        self.assertEqual(self.db.execute("SELECT body_markup FROM question_options").fetchone()[0], r"$5\,\mathrm{cm}$")
        self.assertEqual(self.db.execute("SELECT crop_asset_sha256,region_x,region_y FROM question_figures").fetchone(), (FIGURE, 100, 100))
        self.assertIsNone(self.db.execute("SELECT reference_answer_markup FROM questions").fetchone()[0])
        self.assertEqual(self.db.execute("PRAGMA foreign_key_check").fetchall(), [])

    def test_missing_images_and_other_question_figures_are_rejected(self):
        with self.assertRaises(sqlite3.IntegrityError):
            self.figure(crop="c" * 64)
        self.db.execute("INSERT INTO questions(id,stem_markup) VALUES('q2','另一题')")
        with self.assertRaises(sqlite3.IntegrityError):
            self.figure(question="q2", source="s1")

    def test_invalid_crops_cannot_be_silently_clipped(self):
        with self.assertRaises(sqlite3.IntegrityError):
            self.figure(x=900)
        with self.assertRaises(sqlite3.IntegrityError):
            self.figure(crop=ORIGINAL)
        self.figure()
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("UPDATE question_sources SET region_width=200 WHERE id='s1'")
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("UPDATE assets SET pixel_width=2 WHERE sha256=?", (ORIGINAL,))

    def test_scope_and_option_uniqueness(self):
        self.db.execute("INSERT INTO questions(id,stem_markup) VALUES('q2','另一题')")
        self.db.execute("INSERT INTO question_parts(id,question_id,label,ordinal,body_markup) VALUES('p1','q1','(1)',0,'小问')")
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("INSERT INTO question_options(id,question_id,part_id,label,ordinal) VALUES('bad','q2','p1','A',0)")
        self.db.execute("INSERT INTO question_options(id,question_id,label,ordinal) VALUES('o1','q1','A',0)")
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("INSERT INTO question_options(id,question_id,label,ordinal) VALUES('o2','q1','A',1)")
        self.db.execute("INSERT INTO question_options(id,question_id,part_id,label,ordinal) VALUES('o3','q1','p1','A',0)")

    def test_confirmation_requires_original_and_nonempty_stem(self):
        self.db.execute("INSERT INTO questions(id,stem_markup) VALUES('q2','另一题')")
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("UPDATE questions SET review_state='confirmed',reviewed_at='now' WHERE id='q2'")
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("INSERT INTO questions(id,stem_markup,review_state,reviewed_at) VALUES('q3','题目','confirmed','now')")
        self.db.execute("UPDATE questions SET review_state='confirmed',reviewed_at='now' WHERE id='q1'")
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("DELETE FROM question_sources WHERE id='s1'")
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("UPDATE questions SET stem_markup='' WHERE id='q1'")

    def test_transaction_rolls_back_partial_question(self):
        try:
            with self.db:
                self.db.execute("INSERT INTO questions(id,stem_markup) VALUES('q2','新题')")
                self.source("q2", "s2")
                self.db.execute("INSERT INTO question_options(id,question_id,part_id,label,ordinal) VALUES('bad','q2','missing','A',0)")
        except sqlite3.IntegrityError:
            pass
        self.assertEqual(self.db.execute("SELECT count(*) FROM questions WHERE id='q2'").fetchone()[0], 0)
        self.assertEqual(self.db.execute("SELECT count(*) FROM question_sources WHERE id='s2'").fetchone()[0], 0)

    def test_soft_delete_restores_and_shared_image_survives_purge(self):
        self.figure()
        self.db.execute("UPDATE questions SET review_state='confirmed',reviewed_at='now',deleted_at='now' WHERE id='q1'")
        self.db.execute("UPDATE questions SET deleted_at=NULL WHERE id='q1'")
        self.assertEqual(self.db.execute("SELECT count(*) FROM question_figures").fetchone()[0], 1)
        self.db.execute("INSERT INTO questions(id,stem_markup) VALUES('q2','共用原图')")
        self.source("q2", "s2")
        self.db.execute("DELETE FROM questions WHERE id='q1'")
        self.assertEqual(self.db.execute("SELECT count(*) FROM question_figures").fetchone()[0], 0)
        self.assertEqual(self.db.execute("SELECT count(*) FROM assets").fetchone()[0], 2)
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("DELETE FROM assets WHERE sha256=?", (ORIGINAL,))

    def test_attempts_and_ai_feedback_do_not_replace_reference_answer(self):
        self.db.execute("UPDATE questions SET reference_answer_markup='5 cm',reference_answer_origin='source' WHERE id='q1'")
        self.db.execute("INSERT INTO question_attempts(id,question_id,student_answer_markup,is_correct,feedback_markup,feedback_origin) VALUES('a1','q1','7 cm',0,'检查勾股定理','ai')")
        self.assertEqual(self.db.execute("SELECT reference_answer_markup FROM questions").fetchone()[0], "5 cm")
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("UPDATE questions SET reference_answer_origin=NULL WHERE id='q1'")

    def test_schema_version_and_extraction_issues(self):
        self.assertEqual(self.db.execute("PRAGMA user_version").fetchone()[0], 1)
        self.assertEqual(self.db.execute("PRAGMA foreign_keys").fetchone()[0], 1)
        issues = [{"field": "stem_markup", "reason": "上标模糊", "requires_review": True}]
        self.db.execute("INSERT INTO question_extractions(id,question_id,model,provider_host,prompt_version,response_schema_version,status,issues_json) VALUES('e1','q1','test-vision','example.test','math-v1',1,'needs_review',?)", (json.dumps(issues),))
        self.assertEqual(json.loads(self.db.execute("SELECT issues_json FROM question_extractions").fetchone()[0]), issues)
        with self.assertRaises(sqlite3.DatabaseError):
            self.db.execute("UPDATE questions SET knowledge_tags_json='invalid JSON' WHERE id='q1'")
        self.assertEqual(self.db.execute("PRAGMA integrity_check").fetchone()[0], "ok")


if __name__ == "__main__":
    unittest.main()
