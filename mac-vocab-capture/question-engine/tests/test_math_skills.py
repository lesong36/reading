import hashlib
import asyncio
import json
import os
from pathlib import Path
import sys
import threading
import subprocess
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import question_engine as engine
from math_skills import APPLICABILITY_PROMPT, SkillFinalizationMiddleware, SnapshotBackend, SkillError, complete_selection, select_skills, selection_from, snapshots_for
from langchain_core.language_models.chat_models import BaseChatModel
from langchain_core.messages import AIMessage, HumanMessage, SystemMessage, ToolMessage
from langchain_core.outputs import ChatGeneration, ChatResult
from pydantic import PrivateAttr
from deepagents import create_deep_agent


def declared_policy(row, minimum=4, equation="none", extension="none"):
    return json.dumps({"schema_version": 2, "source": "user_profile", "method_id": row["id"],
        "version_id": row["version_id"], "instructions_sha256": hashlib.sha256(row["instructions"].encode()).hexdigest(),
        "skill_name": "", "skill_version": "", "skill_sha256": "", "minimum_grade": minimum,
        "grade4_policy": extension, "equation_policy": equation}, ensure_ascii=False)


def skills(count=2):
    rows = [{"id": "id-" + str(i), "version_id": "version-" + str(i), "title": "和差方法" + str(i),
             "category": "数量关系", "instructions": "FULL_PRIVATE_BODY_" + str(i) + " 必须是同一组数量的和与差。"}
            for i in range(count)]
    # These routing protocol fixtures represent explicitly declared native permissions.
    for row in rows:
        row["teaching_policy"] = declared_policy(row)
    return rows


def answer(identifier="id-0", visuals=None):
    chosen = ([identifier] if identifier is not None else []) + (visuals or [])
    assessments = [{"method_id": item, "status": "applicable", "conditions": [
        {"requirement": "同一对数量给出和与差", "evidence": "原图给出两量和72、差18", "status": "met"}]} for item in chosen]
    return json.dumps({"method_id": identifier, "visual_method_ids": visuals or [],
                       "reason": "原图给出两量的和与差。", "applicability": assessments}, ensure_ascii=False)


def truth_answer(identifier="id-0", visuals=None, *, selection=None, truth=True, coverage=True, branch_excerpt="必须是同一组数量的和与差。"):

    value = json.loads(answer(identifier, visuals)) if selection is None else selection
    methods, index = [], 0
    selected = {value["method_id"], *value["visual_method_ids"]} - {None}
    for assessment in value["applicability"]:
        if assessment["method_id"] not in selected:
            continue
        conditions = []
        for condition in assessment["conditions"]:
            index += 1
            conditions.append({"condition_id": f"p{index}", "proposition": "本题原图直接给出同一组数量关系", "basis": "fact", "arithmetic": None, "truth": truth, "evidence": "独立检查原图的肯定必要前提。"})
        methods.append({"method_id": assessment["method_id"], "current_branch": {"skill_excerpt": branch_excerpt, "evidence": "原图事实支持本次使用的通用规则。"}, "conditions": conditions,
            "additional_prerequisites": [], "coverage_complete": coverage})
    return json.dumps({"methods": methods}, ensure_ascii=False)


def review_metadata(identifier="id-0", visuals=None):
    return {"precondition_review": "independent_truth", "prerequisite_review": {
        "status": "passed", "result": json.loads(truth_answer(identifier, visuals))}}


class ScriptModel(BaseChatModel):
    _calls: list = PrivateAttr(default_factory=list)
    _responses: list = PrivateAttr(default_factory=list)
    _bound: list = PrivateAttr(default_factory=list)
    _bindings: list = PrivateAttr(default_factory=list)
    _unsupported: bool = PrivateAttr(default=False)
    _wait: asyncio.Event | None = PrivateAttr(default=None)

    @property
    def _llm_type(self):
        return "skills-test-chat"

    def bind_tools(self, tools, **kwargs):
        if self._unsupported:
            raise NotImplementedError
        self._bound = [item.name for item in tools]
        self._bindings.append((list(self._bound), kwargs))
        return self

    def _generate(self, messages, stop=None, run_manager=None, **kwargs):
        self._calls.append(messages)
        value = self._responses.pop(0)
        if isinstance(value, Exception):
            raise value
        return ChatResult(generations=[ChatGeneration(message=value)])

    async def _agenerate(self, messages, stop=None, run_manager=None, **kwargs):
        if self._wait is not None:
            await self._wait.wait()
        return self._generate(messages, stop, run_manager, **kwargs)


MESSAGES = [SystemMessage("只判断适用方法，输出完整 JSON，不解题。"), HumanMessage("两量和72，差18。")]


class SelectionParsingTests(unittest.TestCase):
    def test_one_terminal_selection_object_accepts_provider_prose_and_fences(self):
        snapshots = snapshots_for(skills())
        decision = answer("id-0", ["id-1"])
        for text in (decision, "The main method is applicable.\n\n" + decision,
                     "```json\n" + decision + "\n```",
                     "选择已读取的两个方法。\n```json\n" + decision + "\n```"):
            with self.subTest(text=text):
                self.assertEqual(selection_from(text, snapshots), json.loads(decision))

    def test_wrapping_cannot_hide_ambiguous_or_invalid_decisions(self):
        snapshots = snapshots_for(skills())
        valid = answer()
        for text in (valid + "\n" + valid, "first " + valid + "\nsecond " + valid,
                     "说明\n" + valid + " trailing commentary", "[" + valid + "]",
                     json.dumps(valid), '"plain string"\n```json\n' + valid + '\n```',
                     "null\n" + valid, "42\n```json\n" + valid + "\n```", "```json\n" + valid + "\n" + valid + "\n```",
                     "说明\n" + answer("invented"), "说明\n" + answer("id-0", ["id-0"]),
                     "````json\n" + valid + "\n````", "{broken prefix}\n" + valid):
            with self.subTest(text=text), self.assertRaises(SkillError):
                selection_from(text, snapshots)

    def test_verbose_reason_is_bounded_metadata_without_changing_valid_identities(self):
        snapshots = snapshots_for(skills())
        reason = " \n" + "原题数量关系明确，应比较差数和倍数。" * 18 + "\t "
        for primary, visuals in [("id-0", ["id-1"]), (None, [])]:
            value = {"method_id": primary, "visual_method_ids": visuals, "reason": reason}
            content = json.dumps(value, ensure_ascii=False)
            self.assertLess(len(content.encode()), 4000)
            result = selection_from(content, snapshots)
            self.assertEqual(result["method_id"], primary)
            self.assertEqual(result["visual_method_ids"], visuals)
            self.assertEqual(result["reason"], reason.strip()[:200])
            self.assertEqual(len(result["reason"]), 200)

    def test_reason_bounding_keeps_output_budget_identities_types_and_fields_strict(self):
        baseline = {"method_id": "id-0", "visual_method_ids": ["id-1"], "reason": "关系明确。" * 50}
        changes = [
            {"method_id": "invented"}, {"method_id": True},
            {"visual_method_ids": ["invented"]}, {"visual_method_ids": ["id-1", "id-1"]},
            {"visual_method_ids": ["id-0"]}, {"visual_method_ids": ["id-1", "id-0", "id-2"]},
            {"visual_method_ids": "id-1"}, {"reason": 200}, {"reason": None},
            {"reason": " \n\t"}, {"reason": "大" * 2000}, {"answer": 8},
        ]
        for change in changes:
            with self.subTest(change=change), self.assertRaises(SkillError) as error:
                selection_from(json.dumps({**baseline, **change}, ensure_ascii=False), snapshots_for(skills()))
            self.assertEqual(error.exception.code, "skillsOutput")

    def test_complete_selection_still_rejects_provider_truncation_with_valid_long_reason(self):
        value = {"method_id": None, "visual_method_ids": [], "reason": "无需数学方法。" * 40}
        for metadata in [{"finish_reason": "length"}, {"status": "incomplete"}]:
            with self.subTest(metadata=metadata), self.assertRaises(SkillError) as error:
                complete_selection(AIMessage(json.dumps(value, ensure_ascii=False), response_metadata=metadata), snapshots_for(skills()))
            self.assertEqual(error.exception.code, "skillsTruncated")


class SnapshotTests(unittest.TestCase):
    def test_project_skill_names_and_descriptions_reach_framework_without_body_disclosure(self):
        rows = skills()
        rows[0].update(skill_name="sum-difference", description="适用于同一对数量给出和与差，不能把不同时刻的量混用。")
        backend = SnapshotBackend(snapshots_for(rows))
        document = backend.files["/teaching-skills/sum-difference/SKILL.md"]
        self.assertIn("name: sum-difference\n", document)
        self.assertIn(rows[0]["description"], document.split("\n---\n")[0])
        self.assertNotIn("FULL_PRIVATE_BODY", document.split("\n---\n")[0])
        self.assertIn("FULL_PRIVATE_BODY_0", backend.load_for_model("/teaching-skills/sum-difference/SKILL.md"))

    def test_project_names_reject_traversal_injection_and_duplicates(self):
        for name in ("../secret", "Bad Name", "valid\nname: injected", "a" * 65, "-bad", "bad--name", ""):
            rows = skills()
            rows[0]["skill_name"] = name
            with self.subTest(name=name), self.assertRaises(SkillError):
                snapshots_for(rows)
        rows = skills()
        for row in rows:
            row["skill_name"] = "sum-difference"
        with self.assertRaises(SkillError):
            snapshots_for(rows)

    def test_full_standard_description_budget_remains_available_with_long_identities(self):
        rows = skills()
        rows[0].update(id="i" * 256, version_id="v" * 256, description="适用条件" * 256)
        rows[0]["teaching_policy"] = declared_policy(rows[0])
        backend = SnapshotBackend(snapshots_for(rows))
        header = next(iter(backend.files.values())).split("\n---\n")[0]
        self.assertIn(json.dumps(rows[0]["description"], ensure_ascii=False), header)
        self.assertEqual(json.loads(backend.identities)[0]["method_id"], rows[0]["id"])
        self.assertNotIn("FULL_PRIVATE_BODY", backend.identities)
        rows[0]["description"] += "超"
        with self.assertRaises(SkillError):
            snapshots_for(rows)

    def test_validation_bounds_versions_and_duplicate_ids(self):
        for value in (None, [], [{"id": "bad"}], skills() + [skills()[0]], skills(513)):
            with self.assertRaises(SkillError):
                snapshots_for(value)
        rows = skills()
        rows[0]["instructions"] = "大" * 100_001
        with self.assertRaises(SkillError):
            snapshots_for(rows)

    def test_backend_read_only_and_immutable_request_snapshot(self):
        rows = skills()
        backend = SnapshotBackend(snapshots_for(rows))
        rows[0]["instructions"] = "changed"
        first = next(iter(backend.files))
        self.assertIn("FULL_PRIVATE_BODY_0", backend.load_for_model(first))
        self.assertNotIn("changed", backend.files[first])
        self.assertIn("version-0", backend.files[first])
        for path in ("/etc/passwd", first.replace("/SKILL.md", "/../SKILL.md"), "/teaching-skills//SKILL.md"):
            self.assertEqual(backend.download_files([path])[0].error, "permission_denied")
        with self.assertRaises(NotImplementedError):
            backend.write(first, "changed")


class FrameworkTests(unittest.IsolatedAsyncioTestCase):
    async def test_last_budget_call_error_cannot_trigger_a_sixth_compatibility_call(self):
        class UnsupportedToolError(Exception):
            status_code = 400
            body = {"error": {"param": "tools", "message": "tools unsupported"}}
        snapshots = snapshots_for(skills())
        path = next(iter(SnapshotBackend(snapshots).files))
        model = ScriptModel()
        model._responses = [AIMessage(content="", tool_calls=[{"name": "read_file", "args": {"file_path": path}, "id": "read-error-" + str(i), "type": "tool_call"}]) for i in range(3)] + [AIMessage(answer()), UnsupportedToolError(), AIMessage(answer())]
        with self.assertRaises(UnsupportedToolError):
            await select_skills(model, MESSAGES, snapshots)
        self.assertEqual(len(model._calls), 5)
        self.assertEqual(len(model._responses), 1)

    async def test_last_budget_call_finalizes_without_extra_model_calls(self):
        snapshots = snapshots_for(skills())
        path = next(iter(SnapshotBackend(snapshots).files))
        for identifier in ("id-0", "id-1"):
            model = ScriptModel()
            model._responses = [AIMessage(content="", tool_calls=[{"name": "read_file", "args": {"file_path": path}, "id": "read-final-" + str(i), "type": "tool_call"}]) for i in range(3)] + [AIMessage(answer(identifier))]
            if identifier == "id-0":
                model._responses.append(AIMessage(truth_answer(identifier)))
            if identifier == "id-0":
                output, details = await select_skills(model, MESSAGES, snapshots)
                self.assertEqual(json.loads(output)["method_id"], identifier)
                self.assertEqual(details["loaded_skill_ids"], [identifier])
            else:
                with self.assertRaises(SkillError):
                    await select_skills(model, MESSAGES, snapshots)
            self.assertEqual(len(model._calls), 5 if identifier == "id-0" else 4)
            self.assertIn("读取工具已关闭", model._calls[3][0].text)
            self.assertIn('已读编号：["id-0"]', model._calls[3][0].text)
            self.assertEqual(model._responses, [])

    async def test_last_budget_call_removes_tools_but_preserves_original_request(self):
        from langchain.agents.middleware import ModelRequest
        from langchain_core.tools import tool
        @tool
        def read_file(file_path: str) -> str:
            """Read skill test fixture."""
            return file_path
        backend = SnapshotBackend(snapshots_for(skills()))
        middleware = SkillFinalizationMiddleware(backend)
        request = ModelRequest(model=ScriptModel(), system_message=SystemMessage("Original rules"), messages=[], tools=[read_file], tool_choice="auto", state={"run_model_call_count": 4})
        async def capture(updated):
            self.assertEqual(updated.tools, [])
            self.assertIsNone(updated.tool_choice)
            self.assertIn("Original rules", updated.system_message.text)
            self.assertIn("不能选择未读方法", updated.system_message.text)
            return "captured"
        self.assertEqual(await middleware.awrap_model_call(request, capture), "captured")
        self.assertEqual(request.tools, [read_file])
        self.assertEqual(request.tool_choice, "auto")

    async def test_provider_prose_keeps_loaded_identity_and_normalizes_only_output(self):
        snapshots = snapshots_for(skills())
        path = next(iter(SnapshotBackend(snapshots).files))
        model = ScriptModel()
        model._responses = [AIMessage(content="", tool_calls=[{"name": "read_file", "args": {"file_path": path}, "id": "read-prose", "type": "tool_call"}]), AIMessage("The selected method is applicable.\n\n" + answer()), AIMessage(truth_answer())]
        output, details = await select_skills(model, MESSAGES, snapshots)
        self.assertEqual(json.loads(output), json.loads(answer()))
        self.assertEqual(details, {"mode": "deepagents_skills", "loaded_skill_ids": ["id-0"], "model_calls": 3, **review_metadata()})
        self.assertEqual(len(model._calls), 3)

    async def test_verbose_reason_preserves_actual_loaded_skill_and_honest_fallback(self):
        snapshots = snapshots_for(skills())
        path = next(iter(SnapshotBackend(snapshots).files))
        value = json.loads(answer())
        value["reason"] = "原题数量关系明确，方法适用。" * 25
        content = json.dumps(value, ensure_ascii=False)
        model = ScriptModel()
        model._responses = [AIMessage(content="", tool_calls=[{"name": "read_file", "args": {"file_path": path}, "id": "read-long-reason", "type": "tool_call"}]), AIMessage(content), AIMessage(truth_answer())]
        output, details = await select_skills(model, MESSAGES, snapshots)
        self.assertEqual(json.loads(output)["method_id"], "id-0")
        self.assertEqual(len(json.loads(output)["reason"]), 200)
        self.assertEqual(details, {"mode": "deepagents_skills", "loaded_skill_ids": ["id-0"], "model_calls": 3, **review_metadata()})
        self.assertEqual(len(model._calls), 3)
        fallback = ScriptModel()
        fallback._unsupported = True
        fallback._responses = [AIMessage(content), AIMessage(truth_answer())]
        output, details = await select_skills(fallback, MESSAGES, snapshots)
        self.assertEqual(json.loads(output)["method_id"], "id-0")
        self.assertEqual(len(json.loads(output)["reason"]), 200)
        self.assertTrue(json.loads(output)["reason"].startswith("本次为全文兼容选择（未按需调用技能）。"))
        self.assertEqual(details["mode"], "full_snapshot_fallback")
        self.assertEqual(details["fallback_reason"], "tool_protocol_unsupported")
        self.assertEqual(details["loaded_skill_ids"], [])

    async def test_canonical_project_skill_uses_full_description_budget_in_real_middleware(self):
        rows = skills()
        rows[0].update(skill_name="sum-difference", description="适用条件" * 256)
        snapshots = snapshots_for(rows)
        path = "/teaching-skills/sum-difference/SKILL.md"
        model = ScriptModel()
        model._responses = [AIMessage(content="", tool_calls=[{"name": "read_file", "args": {"file_path": path}, "id": "read-project", "type": "tool_call"}]), AIMessage(answer()), AIMessage(truth_answer())]
        output, details = await select_skills(model, MESSAGES, snapshots)
        self.assertEqual(json.loads(output)["method_id"], "id-0")
        self.assertEqual(details["loaded_skill_ids"], ["id-0"])
        self.assertIn(rows[0]["description"], model._calls[0][0].text)
        self.assertIn('"method_id": "id-0"', model._calls[0][0].text)
        self.assertNotIn("FULL_PRIVATE_BODY", model._calls[0][0].text)

    async def test_full_deep_agent_exposes_unneeded_harness_tools(self):
        model = ScriptModel()
        model._responses = [AIMessage(answer(None))]
        agent = create_deep_agent(model=model, backend=SnapshotBackend(snapshots_for(skills())), skills=["/teaching-skills/"])
        await agent.ainvoke({"messages": [HumanMessage("只选方法，不解题。没有适用方法。")]} , config={"callbacks": []})
        self.assertIn("write_file", model._bound)
        self.assertIn("task", model._bound)
        self.assertIn("edit_file", model._bound)
        self.assertIn("read_file", model._bound)

    async def test_real_middleware_progressive_disclosure_47_and_500_skills(self):
        for count in (47, 500):
            snapshots = snapshots_for(skills(count))
            backend = SnapshotBackend(snapshots)
            path = next(iter(backend.files))
            model = ScriptModel()
            model._responses = [AIMessage(content="", tool_calls=[{"name": "read_file", "args": {"file_path": path}, "id": "read-1", "type": "tool_call"}]), AIMessage(answer()), AIMessage(truth_answer())]
            output, details = await select_skills(model, MESSAGES, snapshots)
            self.assertEqual(json.loads(output)["method_id"], "id-0")
            self.assertEqual(model._bound, ["PrerequisiteTruth"])
            self.assertEqual(details, {"mode": "deepagents_skills", "loaded_skill_ids": ["id-0"], "model_calls": 3, **review_metadata()})
            self.assertIn("和差方法" + str(count - 1), model._calls[0][0].text)
            self.assertNotIn("FULL_PRIVATE_BODY", model._calls[0][0].text)
            reads = [message.text for message in model._calls[1] if isinstance(message, ToolMessage)]
            self.assertEqual(len(reads), 1)
            self.assertIn("FULL_PRIVATE_BODY_0", reads[0])
            self.assertIn("version-0", reads[0])
            self.assertNotIn("FULL_PRIVATE_BODY_1", reads[0])

    async def test_explicit_unsupported_tools_and_silent_unread_are_honest_fallbacks(self):
        for unsupported in (True, False):
            model = ScriptModel()
            model._unsupported = unsupported
            model._responses = [AIMessage(answer()), AIMessage(truth_answer())] if unsupported else [AIMessage(answer()), AIMessage(answer()), AIMessage(truth_answer())]
            output, details = await select_skills(model, MESSAGES, snapshots_for(skills()))
            self.assertEqual(details["mode"], "full_snapshot_fallback")
            self.assertEqual(details["fallback_reason"], "tool_protocol_unsupported" if unsupported else "model_did_not_load_skills")
            self.assertEqual(details["loaded_skill_ids"], [])
            self.assertIn("未按需调用技能", json.loads(output)["reason"])
            self.assertIn("FULL_PRIVATE_BODY_1", model._calls[-2][0].text)
            self.assertNotIn("FULL_PRIVATE_BODY_1", model._calls[-1][0].text)
            self.assertEqual(details["model_calls"], len(model._calls))

    async def test_no_match_does_not_force_body_loading(self):
        model = ScriptModel()
        model._responses = [AIMessage(answer(None))]
        output, details = await select_skills(model, MESSAGES, snapshots_for(skills()))
        self.assertIsNone(json.loads(output)["method_id"])
        self.assertEqual(details["loaded_skill_ids"], [])
        self.assertEqual(len(model._calls), 1)

    async def test_invalid_selection_does_not_retry_or_claim_loading(self):
        for value in (answer("invented"), answer(visuals=["id-0"]), "not json"):
            model = ScriptModel()
            model._responses = [AIMessage(value)]
            with self.assertRaises(SkillError):
                await select_skills(model, MESSAGES, snapshots_for(skills()))
            self.assertEqual(len(model._calls), 1)

    async def test_truncated_valid_json_is_still_rejected(self):
        model = ScriptModel()
        model._responses = [AIMessage(answer(None), response_metadata={"finish_reason": "length"})]
        with self.assertRaises(SkillError) as captured:
            await select_skills(model, MESSAGES, snapshots_for(skills()))
        self.assertEqual(captured.exception.code, "skillsTruncated")

    async def test_outside_path_is_denied_and_never_marked_loaded(self):
        model = ScriptModel()
        model._responses = [AIMessage(content="", tool_calls=[{"name": "read_file", "args": {"file_path": "/etc/passwd"}, "id": "read-1", "type": "tool_call"}]), AIMessage(answer(None))]
        _, details = await select_skills(model, MESSAGES, snapshots_for(skills()))
        self.assertEqual(details["loaded_skill_ids"], [])
        self.assertIn("only exact paths", model._calls[1][-1].text)

    async def test_cancellation_propagates_and_no_fallback(self):
        model = ScriptModel()
        model._wait = asyncio.Event()
        task = asyncio.create_task(select_skills(model, MESSAGES, snapshots_for(skills())))
        await asyncio.sleep(0.02)
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task
        self.assertEqual(model._calls, [])

    async def test_model_loop_has_hard_budget(self):
        snapshots = snapshots_for(skills())
        path = next(iter(SnapshotBackend(snapshots).files))
        model = ScriptModel()
        model._responses = [AIMessage(content="", tool_calls=[{"name": "read_file", "args": {"file_path": path}, "id": "read-" + str(i), "type": "tool_call"}]) for i in range(10)]
        with self.assertRaises(SkillError) as captured:
            await select_skills(model, MESSAGES, snapshots)
        self.assertEqual(captured.exception.code, "skillsOutput")
        self.assertEqual(len(model._calls), 4)
        self.assertEqual(model._bindings[-1][0], ["SkillSelection"])


class GatewayHandler(BaseHTTPRequestHandler):
    requests = []
    reject_tools = False
    structured_selection = False
    prerequisite_truth = True
    protocol_version = "HTTP/1.1"

    @staticmethod
    def daily_truth_answer():
        value = json.loads(truth_answer())
        for method in value["methods"]:
            del method["current_branch"]
        return json.dumps(value, ensure_ascii=False)

    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.requests.append(body)
        if self.reject_tools and "tools" in body:
            status = 400
            response = {"error": {"message": "tools unsupported", "param": "tools", "type": "invalid_request_error"}}
        else:
            status = 200
            api = "responses" if self.path.endswith("responses") else "anthropic" if self.path.endswith("messages") else "chat"
            serial = json.dumps(body, ensure_ascii=False)
            truth_needed = "待检查肯定命题及固定编号" in serial
            daily = truth_needed and "日常选法的独立前提检查员" in serial
            truth_payload = json.loads(truth_answer(truth=self.prerequisite_truth)) if truth_needed else None
            if daily:
                for method in truth_payload["methods"]:
                    del method["current_branch"]
            final_answer = json.dumps(truth_payload, ensure_ascii=False) if truth_needed else answer()
            final_tool_name = ("DailyPrerequisiteTruth" if daily else "PrerequisiteTruth") if truth_needed else "SkillSelection"
            read_needed = "read_file" in json.dumps(body.get("tools", [])) and not any(word in serial for word in ('"role": "tool"', '"type": "tool_result"', '"type": "function_call_output"'))
            if read_needed:
                path = next(iter(SnapshotBackend(snapshots_for(skills())).files))
                message = {"role": "assistant", "content": None, "tool_calls": [{"id": "read-1", "type": "function", "function": {"name": "read_file", "arguments": json.dumps({"file_path": path})}}]}
                reason = "tool_calls"
            else:
                message = {"role": "assistant", "content": final_answer}
                reason = "stop"
            select_tool = self.structured_selection and not read_needed and "tools" in body
            if select_tool:
                message = {"role": "assistant", "content": None, "tool_calls": [{"id": "select-1", "type": "function",
                    "function": {"name": final_tool_name, "arguments": final_answer}}]}
                reason = "tool_calls"
            response = {"id": "test-chat", "object": "chat.completion", "created": 1,
                        "model": "test-model", "choices": [{"index": 0, "message": message, "finish_reason": reason}],
                        "usage": {"prompt_tokens": 10, "completion_tokens": 20, "total_tokens": 30}}
            if api == "anthropic":
                content = ([{"type": "tool_use", "id": "read-1", "name": "read_file", "input": {"file_path": path}}]
                           if read_needed else [{"type": "text", "text": final_answer}])
                if select_tool:
                    content = [{"type": "tool_use", "id": "select-1", "name": final_tool_name, "input": json.loads(final_answer)}]
                response = {"id": "test-anthropic", "type": "message", "role": "assistant", "model": "test-model",
                            "content": content, "stop_reason": "tool_use" if read_needed or select_tool else "end_turn",
                            "usage": {"input_tokens": 10, "output_tokens": 20}}
            if api == "responses":
                output = ([{"type": "function_call", "id": "fc-1", "call_id": "read-1", "name": "read_file", "arguments": json.dumps({"file_path": path}), "status": "completed"}]
                          if read_needed else [{"type": "message", "id": "msg-1", "role": "assistant", "status": "completed", "content": [{"type": "output_text", "text": final_answer, "annotations": []}]}])
                if select_tool:
                    output = [{"type": "function_call", "id": "fc-select", "call_id": "select-1", "name": final_tool_name,
                               "arguments": final_answer, "status": "completed"}]
                response = {"id": f"resp-{len(self.requests)}", "object": "response", "created_at": 1, "status": "completed", "error": None,
                            "model": "test-model", "output": output, "usage": {"input_tokens": 10, "output_tokens": 20, "total_tokens": 30}}
        raw = json.dumps(response).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


class SDKMathTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        GatewayHandler.requests = []
        GatewayHandler.reject_tools = False
        GatewayHandler.structured_selection = False
        GatewayHandler.prerequisite_truth = True
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), GatewayHandler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.configuration = {"api": "chatCompletions", "endpoint": f"http://127.0.0.1:{self.server.server_port}/v1/chat/completions", "model": "test-model", "api_key": "fake-test-key"}

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    async def test_real_sdk_tool_serialization_and_explicit_gateway_fallback(self):
        for api, suffix, reject in [(api, suffix, reject) for api, suffix in (("chatCompletions", "chat/completions"), ("responses", "responses"), ("anthropicMessages", "messages")) for reject in (False, True)]:
            GatewayHandler.reject_tools = reject
            GatewayHandler.requests = []
            payload = {"id": "math", "question": "和72差18，选方法。", "instructions": MESSAGES[0].text,
                       "context": {"text": "两量和72差18"}, "configuration": {**self.configuration, "api": api, "endpoint": self.configuration["endpoint"].removesuffix("chat/completions") + suffix},
                       "task": "math_method_selection", "teaching_skills": skills()}
            events = []
            await engine.run_request(payload, events.append)
            self.assertEqual(len(events), 1)
            self.assertEqual(events[0]["type"], "done", (api, reject, events))
            execution = events[0]["skills_execution"]
            self.assertEqual(execution["mode"], "full_snapshot_fallback" if reject else "deepagents_skills")
            self.assertEqual(len(GatewayHandler.requests), 3)
            self.assertEqual(execution["precondition_review"], "independent_daily_truth")
            first = GatewayHandler.requests[0]
            self.assertIn("read_file", json.dumps(first["tools"]))
            self.assertNotIn("FULL_PRIVATE_BODY", json.dumps(first, ensure_ascii=False))
            self.assertIn("FULL_PRIVATE_BODY_0", json.dumps(GatewayHandler.requests[1], ensure_ascii=False))
            self.assertNotIn("fake-test-key", json.dumps(events))

    async def test_real_sdk_structured_selection_keeps_native_four_field_output(self):
        GatewayHandler.structured_selection = True
        for api, suffix in (("chatCompletions", "chat/completions"), ("responses", "responses"), ("anthropicMessages", "messages")):
            with self.subTest(api=api):
                GatewayHandler.requests = []
                payload = {"id": "structured-math", "question": "和72差18，选方法。", "instructions": MESSAGES[0].text,
                           "context": {"text": "两量和72差18"}, "configuration": {**self.configuration, "api": api,
                           "endpoint": self.configuration["endpoint"].removesuffix("chat/completions") + suffix},
                           "task": "math_method_selection", "teaching_skills": skills()}
                events = []
                await engine.run_request(payload, events.append)
                self.assertEqual(len(events), 1)
                self.assertEqual(events[0]["type"], "done", events)
                self.assertEqual(json.loads(events[0]["text"]), json.loads(answer()))
                self.assertEqual(events[0]["skills_execution"], {"mode": "deepagents_skills", "loaded_skill_ids": ["id-0"],
                    "model_calls": 3, "precondition_review": "independent_daily_truth", "prerequisite_protocol": "daily",
                    "prerequisite_review": {"status": "passed", "result": json.loads(GatewayHandler.daily_truth_answer())}})
                self.assertEqual(len(GatewayHandler.requests), 3)
                self.assertIn("SkillSelection", json.dumps(GatewayHandler.requests[0]["tools"]))
                self.assertNotIn("FULL_PRIVATE_BODY", json.dumps(GatewayHandler.requests[0]))
                choice = GatewayHandler.requests[0]["tool_choice"]
                self.assertEqual(choice, {"type": "any"} if api == "anthropicMessages" else "required")
                self.assertNotIn("fake-test-key", json.dumps(events))

    async def test_daily_sdk_unknown_prerequisite_blocks_without_user_verification(self):
        GatewayHandler.prerequisite_truth = None
        for api, suffix in (("chatCompletions", "chat/completions"), ("responses", "responses"), ("anthropicMessages", "messages")):
            with self.subTest(api=api):
                GatewayHandler.requests = []
                payload = {"id": "unknown-daily", "question": "和72差18，选方法。", "instructions": MESSAGES[0].text,
                    "context": {"text": "两量和72差18"}, "configuration": {**self.configuration, "api": api,
                        "endpoint": self.configuration["endpoint"].removesuffix("chat/completions") + suffix},
                    "task": "math_method_selection", "teaching_skills": skills()}
                events = []
                await engine.run_request(payload, events.append)
                self.assertEqual(events[0]["type"], "error", events)
                self.assertEqual(events[0]["code"], "skillsPrerequisite")
                self.assertEqual(events[0]["selection_review"]["precondition_review"], "independent_daily_truth")
                self.assertEqual(events[0]["selection_review"]["prerequisite_review"]["status"], "blocked")
                self.assertEqual(len(GatewayHandler.requests), 3)

    async def test_math_diagram_budget_isolated_from_english_pool_profile(self):
        pool = engine.ModelPool()
        try:
            normal_key, normal = await pool.acquire(self.configuration)
            diagram_key, diagram = await pool.acquire({**self.configuration, "response_mode": "math_diagrams"})
            self.assertNotEqual(normal_key, diagram_key)
            self.assertEqual(normal.max_tokens, 900)
            self.assertEqual(diagram.max_tokens, 8192)
            pool.release(normal_key)
            pool.release(diagram_key)
        finally:
            await pool.close()

    async def test_diagram_budget_survives_provider_thinking_overrides(self):
        pool = engine.ModelPool()
        try:
            providers = [
                {"api": "anthropicMessages", "model": "claude-sonnet-5-5", "endpoint": "https://api.anthropic.com/v1/messages"},
                {"api": "chatCompletions", "model": "deepseek-chat", "endpoint": "https://api.deepseek.com/v1/chat/completions"},
            ]
            for provider in providers:
                for thinking in ("off", "low"):
                    configuration = {**self.configuration, **provider, "thinking": thinking}
                    normal_key, normal = await pool.acquire(configuration)
                    figure_key, figure = await pool.acquire({**configuration, "response_mode": "math_diagrams"})
                    self.assertGreaterEqual(figure.max_tokens, 8192)
                    self.assertLess(normal.max_tokens, figure.max_tokens)
                    pool.release(normal_key)
                    pool.release(figure_key)
        finally:
            await pool.close()

    async def test_invalid_task_payload_is_rejected_before_any_model_call(self):
        events = []
        await engine.run_request({"id": "invalid", "task": "math_method_selection", "teaching_skills": []}, events.append)
        self.assertEqual(events, [{"id": "invalid", "type": "error", "code": "skillsInvalid"}])
        self.assertEqual(GatewayHandler.requests, [])

    async def test_helper_process_runs_skill_tools_and_isolates_stdout(self):
        executable = os.environ.get("QUESTION_ENGINE_EXECUTABLE")
        command = [executable] if executable else [sys.executable, str(Path(engine.__file__).resolve())]
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            ready = json.loads(process.stdout.readline())
            self.assertEqual(ready["type"], "ready")
            payload = {"op": "answer", "id": "process-math", "question": "选适用方法。", "instructions": MESSAGES[0].text,
                       "context": {"text": "两量和72差18"}, "configuration": self.configuration,
                       "task": "math_method_selection", "teaching_skills": skills()}
            process.stdin.write(json.dumps(payload, ensure_ascii=False) + "\n")
            process.stdin.flush()
            event = json.loads(process.stdout.readline())
            self.assertEqual(event["type"], "done", event)
            self.assertEqual(event["skills_execution"], {"mode": "deepagents_skills", "loaded_skill_ids": ["id-0"],
                "model_calls": 3, "precondition_review": "independent_daily_truth", "prerequisite_protocol": "daily",
                    "prerequisite_review": {"status": "passed", "result": json.loads(GatewayHandler.daily_truth_answer())}})
            self.assertEqual(json.loads(event["text"])["method_id"], "id-0")
            process.stdin.close()
            process.wait(timeout=10)
            self.assertEqual(process.returncode, 0)
            self.assertEqual(process.stdout.read(), "")
            self.assertNotIn("fake-test-key", process.stderr.read())
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            process.stdout.close()
            process.stderr.close()


if __name__ == "__main__":
    unittest.main()
