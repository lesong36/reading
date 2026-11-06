"""Transport opt-in stays bounded and cannot weaken normal or learning requests."""
import asyncio
import base64
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from langchain_core.messages import AIMessage
import question_engine as engine
import math_fast_selection as fast
from test_math_fast_selection import custom


def payload():
    return {"id": "fast", "task": "math_method_selection", "selection_protocol": "single_call",
            "instructions": "OLD read_file protocol", "question": "四年级，不用方程",
            "context": {"text": "同一组数量的和差", "image_data": base64.b64encode(b"\x89PNG\r\n\x1a\noriginal").decode()},
            "configuration": {"api": "chatCompletions", "endpoint": "https://api.deepseek.com/chat/completions",
                              "api_key": "test", "model": "deepseek-flash", "thinking": "high"},
            "teaching_skills": [custom()]}


class Model:
    def __init__(self, wait=False, response=None):
        self.calls = []
        self.wait = wait
        self.cancelled = False
        self.response = response or AIMessage('{"primary":1,"visual":[],"reason":"同组数量符合条件"}',
                                            response_metadata={"finish_reason": "stop"})

    async def ainvoke(self, messages, **kwargs):
        self.calls.append(messages)
        try:
            if self.wait:
                await asyncio.Event().wait()
            return self.response
        except asyncio.CancelledError:
            self.cancelled = True
            raise


class Pool:
    def __init__(self, model, wait=False):
        self.model = model
        self.configurations = []
        self.released = []
        self.wait = wait
        self.cancelled = False

    async def acquire(self, configuration):
        self.configurations.append(configuration)
        try:
            if self.wait:
                await asyncio.Event().wait()
            return "key", self.model
        except asyncio.CancelledError:
            self.cancelled = True
            raise

    def release(self, key):
        self.released.append(key)


class FastTransportTests(unittest.IsolatedAsyncioTestCase):
    async def test_opt_in_one_call_retains_original_image_and_forces_off_without_mutating_payload(self):
        value = payload(); model = Model(); pool = Pool(model); events = []
        with patch.object(engine, "select_skills", AsyncMock(side_effect=AssertionError("legacy fallback"))):
            await engine.run_request(value, events.append, pool)
        self.assertEqual(len(model.calls), 1)
        self.assertNotIn("OLD", model.calls[0][0].content)
        self.assertEqual(model.calls[0][1].content[1]["image_url"]["url"],
                         "data:image/png;base64," + value["context"]["image_data"])
        self.assertEqual(pool.configurations[0]["thinking"], "off")
        self.assertEqual(value["configuration"]["thinking"], "high")
        self.assertEqual(json.loads(events[-1]["text"])["method_id"], "a")
        self.assertFalse(events[-1]["skills_execution"]["mathematical_certification"])
        self.assertEqual(events[-1]["skills_execution"]["precondition_review"], "not_independently_verified")
        self.assertEqual(pool.released, ["key"])
        self.assertEqual(engine.FAST_SELECTION_TIMEOUT, 5)

    async def test_deadline_cancels_model_and_acquisition_without_retry(self):
        for acquisition in (False, True):
            model = Model(wait=True); pool = Pool(model, wait=acquisition); events = []
            with self.subTest(acquisition=acquisition), patch.object(engine, "FAST_SELECTION_TIMEOUT", .01), \
                    patch.object(engine, "select_skills", AsyncMock(side_effect=AssertionError("fallback"))):
                await engine.run_request(payload(), events.append, pool)
                self.assertEqual(events, [{"id": "fast", "type": "error", "code": "timeout"}])
                self.assertEqual(len(pool.configurations), 1)
                self.assertEqual(len(model.calls), 0 if acquisition else 1)
                self.assertTrue(pool.cancelled if acquisition else model.cancelled)
                self.assertEqual(pool.released, [] if acquisition else ["key"])

    async def test_unknown_protocol_and_other_tasks_fail_before_acquisition(self):
        for protocol, task in ((None, "math_method_selection"), ("strict", "math_method_selection"),
                               ("single_call", None), ("single_call", "math_skill_learning")):
            value = payload(); value.update(selection_protocol=protocol, task=task)
            pool = Pool(Model()); events = []
            await engine.run_request(value, events.append, pool)
            self.assertEqual(events[-1]["code"], "invalid")
            self.assertEqual(pool.configurations, [])

    async def test_default_daily_unchanged_and_explicit_daily_supported(self):
        for explicit in (False, True):
            value = payload()
            if explicit: value["selection_protocol"] = "daily"
            else: del value["selection_protocol"]
            pool = Pool(Model()); events = []
            with patch.object(engine, "select_skills", AsyncMock(return_value=("legacy", {"mode": "daily"}))) as legacy, \
                    patch.object(engine, "select_fast", AsyncMock(side_effect=AssertionError("new route"))):
                await engine.run_request(value, events.append, pool)
            self.assertEqual(legacy.await_args.kwargs, {"prerequisite_protocol": "daily"})
            self.assertEqual(pool.configurations[0]["thinking"], "high")
            self.assertEqual(events[-1]["text"], "legacy")

    async def test_permissions_and_invalid_output_never_trigger_second_call(self):
        value = payload(); value["question"] = "四年级，不用方程"
        value["teaching_skills"] = [custom(minimum=6)]
        pool = Pool(Model()); events = []
        await engine.run_request(value, events.append, pool)
        self.assertEqual(pool.model.calls, [])
        self.assertIsNone(json.loads(events[-1]["text"])["method_id"])
        pool = Pool(Model(response=AIMessage('{"primary":999,"visual":[],"reason":"不应信任编号"}',
                                           response_metadata={"finish_reason": "stop"})))
        events = []; await engine.run_request(payload(), events.append, pool)
        self.assertEqual(events[-1]["code"], "skillsOutput")
        self.assertEqual(len(pool.model.calls), 1)

    async def test_integrity_failure_happens_before_model_and_payload_cannot_pick_asset_paths(self):
        value = payload(); value.update(profiles_path="/untrusted/profiles.json", skill_index_path="/untrusted/index.json")
        real = fast.project_card_paths(); pool = Pool(Model()); events = []
        with patch.object(engine, "build_cards", side_effect=engine.SkillError("skillsInvalid")) as build:
            await engine.run_request(value, events.append, pool)
        self.assertEqual(build.call_args.args[1:], real)
        self.assertEqual(events[-1]["code"], "skillsInvalid")
        self.assertEqual(pool.configurations, [])

    def test_dev_and_frozen_paths_are_package_owned(self):
        profiles, index = fast.project_card_paths()
        self.assertTrue(profiles.is_file()); self.assertTrue(index.is_file())
        with patch.object(fast.sys, "frozen", True, create=True), patch.object(fast.sys, "_MEIPASS", "/frozen/runtime", create=True):
            self.assertEqual(fast.project_card_paths(), (Path("/frozen/runtime/MathTeachingReview/profiles.json"),
                                                        Path("/frozen/runtime/MathSkills/index.json")))


if __name__ == "__main__":
    unittest.main()
