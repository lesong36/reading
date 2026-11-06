"""Real Anthropic SDK streams, isolated HTTP fixture; never a remote model."""
import json
from pathlib import Path
import sys
import threading
import unittest
from http.server import ThreadingHTTPServer

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import question_engine as engine
import test_engine as fixtures
from test_math_solution_responses_transport import renderer_arguments


class AnthropicSubmissionHandler(fixtures.Handler):
    requests = []
    client_ports = []
    behavior = "tool"
    arguments = json.dumps(renderer_arguments(), ensure_ascii=False)

    def messages(self):
        if self.behavior == "english":
            return super().messages()
        def event(kind, **values):
            self.send_event({"type": kind, **values}, kind)
        event("message_start", message={"id": "msg-tool", "type": "message", "role": "assistant",
              "content": [], "model": "claude-sonnet-5-5", "stop_reason": None,
              "stop_sequence": None, "usage": {"input_tokens": 11, "output_tokens": 0}})
        count = 2 if self.behavior == "multi" else 1
        for index in range(count):
            if self.behavior == "text":
                event("content_block_start", index=index, content_block={"type": "text", "text": "Outside tool"})
            else:
                name = "wrong_tool" if self.behavior == "wrong" else "render_difference_ratio"
                initial = renderer_arguments() if self.behavior == "parsed" else {}
                event("content_block_start", index=index,
                      content_block={"type": "tool_use", "id": f"tool-{index}", "name": name, "input": initial})
                for fragment in (self.arguments[:20], self.arguments[20:75], self.arguments[75:]):
                    event("content_block_delta", index=index, delta={"type": "input_json_delta", "partial_json": fragment})
            event("content_block_stop", index=index)
        if self.behavior == "prose":
            event("content_block_start", index=1, content_block={"type": "text", "text": "Outside tool"})
            event("content_block_stop", index=1)
        if self.behavior == "thinking":
            event("content_block_start", index=1, content_block={"type": "thinking", "thinking": "Private note", "signature": "sig"})
            event("content_block_stop", index=1)
        if self.behavior != "missing":
            reason = "max_tokens" if self.behavior == "length" else "end_turn" if self.behavior == "end-turn" else "tool_use"
            event("message_delta", delta={"stop_reason": reason, "stop_sequence": None}, usage={"output_tokens": 7})
            if self.behavior != "missing-stop":
                event("message_stop")


class AnthropicSubmissionWireTests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), AnthropicSubmissionHandler)
        cls.server.daemon_threads = True
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        AnthropicSubmissionHandler.requests.clear()
        AnthropicSubmissionHandler.behavior = "tool"
        AnthropicSubmissionHandler.arguments = json.dumps(renderer_arguments(), ensure_ascii=False)

    def payload(self):
        payload = fixtures.request("anthropicMessages", "/v1/messages")
        payload["configuration"].update(endpoint=f"http://127.0.0.1:{self.server.server_port}/v1/messages",
            model="claude-sonnet-5-5", thinking="off", direct_connection=True)
        payload.update(response_mode="math_solution", solution_protocol="renderer_tools")
        return payload

    async def invoke(self, payload=None):
        events = []
        await engine.run_request(payload or self.payload(), events.append)
        return events

    async def test_single_post_auto_choice_original_image_usage_and_native_result(self):
        events = await self.invoke()
        self.assertEqual([e["type"] for e in events], ["done"], events)
        self.assertEqual(len(AnthropicSubmissionHandler.requests), 1)
        path, _, body = AnthropicSubmissionHandler.requests[0]
        self.assertEqual(path, "/v1/messages")
        self.assertEqual(body["tool_choice"], {"type": "auto", "disable_parallel_tool_use": True})
        self.assertEqual(body["thinking"], {"type": "between_tools"})
        self.assertEqual(body["output_config"], {"effort": "low"})
        self.assertEqual(len(body["tools"]), 18)
        self.assertTrue(all("input_schema" in t for t in body["tools"]))
        self.assertIn(fixtures.PNG, json.dumps(body["messages"]))
        self.assertIn("First answer", json.dumps(body["messages"]))
        value = json.loads(events[0]["text"])
        self.assertIsNone(value["method_id"])
        self.assertEqual(value["diagrams"][0]["difference"]["value"], 72)
        self.assertEqual(events[0]["usage"], {"input_tokens": 11, "output_tokens": 7})
        clock = events[0]["timings"]
        self.assertLessEqual(clock["first_sdk_chunk"], clock["first_tool_arguments"])
        self.assertAlmostEqual(clock["first_tool_arguments"] + clock["arguments_to_stream_end"], clock["stream_total"])

    async def test_invalid_incomplete_or_extra_output_rejected_without_retry(self):
        for behavior in ("multi", "wrong", "text", "parsed", "prose", "missing", "missing-stop", "length", "end-turn"):
            with self.subTest(behavior=behavior):
                self.setUp()
                AnthropicSubmissionHandler.behavior = behavior
                events = await self.invoke()
                self.assertEqual([e["type"] for e in events], ["error"], events)
                self.assertEqual(len(AnthropicSubmissionHandler.requests), 1)
                self.assertNotIn("test-secret-never-print", json.dumps(events))

    async def test_duplicate_argument_keys_not_concealed_by_sdk(self):
        AnthropicSubmissionHandler.arguments = '{"method_id":null,' + AnthropicSubmissionHandler.arguments[1:]
        events = await self.invoke()
        self.assertEqual([e["type"] for e in events], ["error"], events)
        self.assertEqual(len(AnthropicSubmissionHandler.requests), 1)

    async def test_reasoning_never_displayed_as_answer(self):
        AnthropicSubmissionHandler.behavior = "thinking"
        events = await self.invoke()
        self.assertEqual([e["type"] for e in events], ["done"], events)
        self.assertNotIn("Private note", json.dumps(events))

    async def test_ordinary_english_and_strict_guard_unchanged(self):
        payload = self.payload()
        payload.pop("response_mode"); payload.pop("solution_protocol")
        AnthropicSubmissionHandler.behavior = "english"
        events = await self.invoke(payload)
        self.assertEqual(events[-1]["type"], "done", events)
        self.assertEqual(events[-1]["text"], "Hello world")
        self.assertNotIn("tools", AnthropicSubmissionHandler.requests[-1][2])
        self.setUp()
        payload = self.payload()
        payload["solution_protocol"] = "renderer_tools_strict"
        events = await self.invoke(payload)
        self.assertEqual([e["type"] for e in events], ["error"], events)
        self.assertEqual(AnthropicSubmissionHandler.requests, [])
