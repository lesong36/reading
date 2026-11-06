import json
from pathlib import Path
import sys
import threading
import unittest
from http.server import ThreadingHTTPServer
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import question_engine as engine
import test_engine as fixtures
from math_solution_contract import TOOL_NAME


def result():
    return {"mode": "native_recipe", "method_id": None, "visual_method_ids": [],
            "answer": "原数为一份，多出的九份对应72。",
            "diagram_outcome": {"status": "renderable", "primary_diagram": {
                "id": "times-ten", "title": "原数与十倍", "kind": "difference_ratio",
                "difference": {"value": 72, "unit": "", "evidence": "比原数大72"},
                "multiplier": {"value": 10, "unit": "", "evidence": "原数乘10"}}}}


class SubmissionHandler(fixtures.Handler):
    requests = []
    client_ports = []
    behavior = "tool"
    tool_name = TOOL_NAME
    arguments = json.dumps(result(), ensure_ascii=False)

    def chat(self):
        if self.behavior == "english":
            return super().chat()
        name = "wrong_tool" if self.behavior == "wrong" else self.tool_name
        arguments = self.arguments
        first = {"index": 0, "id": "call-one", "type": "function", "function": {"name": name, "arguments": ""}}
        deltas = [{"tool_calls": [first]}]
        for fragment in (arguments[:20], arguments[20:75], arguments[75:]):
            deltas.append({"tool_calls": [{"index": 0, "function": {"arguments": fragment}}]})
        if self.behavior == "multi":
            deltas.append({"tool_calls": [{"index": 1, "id": "call-two", "type": "function", "function": {"name": TOOL_NAME, "arguments": arguments}}]})
        if self.behavior == "prose":
            deltas.append({"content": "旁白不能隐藏无效工具参数。"})
        for delta in deltas:
            self.send_event({"id": "chat-one", "object": "chat.completion.chunk", "created": 1,
                             "model": "public-test-model", "choices": [{"index": 0, "delta": delta, "finish_reason": None}]})
        if self.behavior != "missing":
            self.send_event({"id": "chat-one", "object": "chat.completion.chunk", "created": 1,
                             "model": "public-test-model", "choices": [{"index": 0, "delta": {},
                             "finish_reason": "length" if self.behavior == "length" else "tool_calls"}]})
            self.send_event({"id": "chat-one", "object": "chat.completion.chunk", "created": 1,
                             "model": "public-test-model", "choices": [],
                             "usage": {"prompt_tokens": 11, "completion_tokens": 7, "total_tokens": 18,
                             "completion_tokens_details": {"reasoning_tokens": 0}}})
        self.send_bytes(b"data: [DONE]\n\n")


class SingleSubmissionWireTests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), SubmissionHandler)
        cls.server.daemon_threads = True
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        SubmissionHandler.requests.clear()
        SubmissionHandler.behavior = "tool"
        SubmissionHandler.tool_name = TOOL_NAME
        SubmissionHandler.arguments = json.dumps(result(), ensure_ascii=False)

    def payload(self):
        payload = fixtures.request()
        payload["configuration"].update(endpoint=f"http://127.0.0.1:{self.server.server_port}/chat/completions", thinking="off", direct_connection=True)
        payload.update(response_mode="math_solution", solution_protocol="single_submission")
        return payload

    async def test_exact_paths_stream_executes_once_and_returns_program_count(self):
        SubmissionHandler.tool_name = "count_simple_graph_paths"
        SubmissionHandler.arguments = json.dumps({
            "method_id": None, "visual_method_ids": [], "nodes": ["A", "B", "C"],
            "edges": [{"from": "A", "to": "B"}, {"from": "A", "to": "C"}, {"from": "C", "to": "B"}],
            "node_locations": [{"node": n, "location": "原图位置"+n, "x": (0,800,0)[i], "y": (0,0,800)[i]} for i,n in enumerate("ABC")],
            "start": "A", "end": "B", "directed": False,
            "source_evidence": "三点两两连接", "crossing_convention": "无交叉"})
        events = await self.invoke(self.payload() | {"solution_protocol": "renderer_tools", "diagram_scope": "native_only"})
        self.assertEqual(events[-1]["type"], "done", events)
        output = json.loads(events[-1]["text"])
        self.assertIn("合计：2条", output["answer"])
        self.assertIn("仍须核对原题", output["answer"])
        self.assertEqual(output["diagrams"], [])
        self.assertEqual(len(SubmissionHandler.requests), 1)

    async def test_equal_sum_grid_stream_returns_program_result_without_second_synthesis(self):
        SubmissionHandler.tool_name = "solve_equal_sum_grid"
        SubmissionHandler.arguments = json.dumps({
            "method_id": None, "visual_method_ids": [], "grid": [[1, None], [None, None]],
            "diagonals": True, "target": {"row": 2, "column": 2}, "source_evidence": "二阶表行列两对角线等和"})
        events = await self.invoke(self.payload() | {"solution_protocol": "renderer_tools", "diagram_scope": "native_only"})
        self.assertEqual(events[-1]["type"], "done", events)
        answer = json.loads(events[-1]["text"])["answer"]
        self.assertIn("唯一确定为：1", answer)
        self.assertIn("两条主对角线和：2、2", answer)
        self.assertEqual(len(SubmissionHandler.requests), 1)

    async def invoke(self, payload=None, pool=None):
        events = []
        await engine.run_request(payload or self.payload(), events.append, pool)
        return events

    async def test_native_only_scope_binds_compact_schema_and_keeps_omission(self):
        SubmissionHandler.tool_name = "submit_general_math_solution"
        value = {"method_id": None, "visual_method_ids": [], "answer": "115×2×12=2760（元）。",
                 "diagram_outcome": {"status": "no_helpful_diagram", "reason": "所列图解工具不适用，直接算术解答。"}}
        SubmissionHandler.arguments = json.dumps(value, ensure_ascii=False)
        payload = self.payload() | {"solution_protocol": "renderer_tools", "diagram_scope": "native_only"}
        events = await self.invoke(payload)
        self.assertEqual([event["type"] for event in events], ["done"], events)
        output = json.loads(events[-1]["text"])
        self.assertTrue(output["answer"].startswith(value["answer"]))
        self.assertEqual(output["diagrams"], [])
        self.assertEqual(output["diagram_omission"], value["diagram_outcome"])
        self.assertEqual(len(SubmissionHandler.requests), 1)
        general = SubmissionHandler.requests[0][2]["tools"][-1]["function"]["parameters"]
        self.assertNotIn("quantity_plan", json.dumps(general))
        self.assertNotIn("$defs", general)

    async def test_native_only_scope_rejects_general_graph_but_retains_text(self):
        from test_math_diagram_tools import general
        SubmissionHandler.tool_name = "submit_general_math_solution"
        value = general()
        SubmissionHandler.arguments = json.dumps(value)
        events = await self.invoke(self.payload() | {"solution_protocol": "renderer_tools", "diagram_scope": "native_only"})
        self.assertEqual(events[-1]["type"], "done", events)
        output = json.loads(events[-1]["text"])
        self.assertEqual(output["answer"], value["answer"])
        self.assertEqual(output["diagrams"], [])
        self.assertEqual(output["diagram_submission_failure"], "submission_shape")
        self.assertNotIn("diagram_omission", output)
        self.assertEqual(len(SubmissionHandler.requests), 1)

    async def test_invalid_diagram_scope_rejected_before_model_acquisition(self):
        for scope in (None, "", "native", [], {}):
            events = await self.invoke(self.payload() | {"solution_protocol": "renderer_tools", "diagram_scope": scope})
            self.assertEqual(events[-1]["type"], "error", events)
            self.assertEqual(events[-1]["code"], "invalid", events)
        for protocol in ("single_submission", "single_submission_strict", None):
            payload = self.payload() | {"diagram_scope": "full"}
            if protocol is None:
                payload.pop("solution_protocol")
                payload.pop("response_mode")
            else:
                payload["solution_protocol"] = protocol
            events = await self.invoke(payload)
            self.assertEqual(events[-1]["code"], "invalid", events)
        self.assertEqual(SubmissionHandler.requests, [])

    async def test_exact_one_wire_request_original_photo_named_tool_and_null_method(self):
        policy = engine.thinking_options
        def deepseek_off(configuration):
            return policy(configuration | {"endpoint": "https://api.deepseek.com/chat/completions"})
        with patch.object(engine, "thinking_options", side_effect=deepseek_off), patch.object(engine, "supports_chat_usage", return_value=True):
            events = await self.invoke()
        self.assertEqual(len(SubmissionHandler.requests), 1)
        self.assertEqual([e["type"] for e in events], ["done"], events)
        answer = json.loads(events[-1]["text"])
        self.assertIsNone(answer["method_id"])
        self.assertEqual(answer["diagrams"][0]["difference"]["value"], 72)
        self.assertEqual(events[-1]["usage"], {"input_tokens": 11, "output_tokens": 7, "reasoning_tokens": 0})
        path, _, body = SubmissionHandler.requests[0]
        self.assertEqual(path, "/chat/completions")
        self.assertEqual(body["tool_choice"], {"type": "function", "function": {"name": TOOL_NAME}})
        self.assertEqual(len(body["tools"]), 1)
        self.assertNotIn("strict", body["tools"][0]["function"])
        self.assertEqual(body["thinking"], {"type": "disabled"})
        images = [block["image_url"]["url"] for message in body["messages"]
                  if isinstance(message.get("content"), list) for block in message["content"]
                  if block.get("type") == "image_url"]
        self.assertEqual(images, ["data:image/png;base64," + fixtures.PNG])

    async def test_renderer_tool_one_request_null_main_original_inputs_and_no_second_synthesis(self):
        payload = self.payload() | {"solution_protocol": "renderer_tools"}
        payload["configuration"]["thinking"] = "high"
        value = result()
        diagram = value["diagram_outcome"]["primary_diagram"].copy()
        diagram.pop("kind")
        SubmissionHandler.tool_name = "render_difference_ratio"
        SubmissionHandler.arguments = json.dumps({"method_id": None, "visual_method_ids": [],
            "relationship": value["answer"], "diagram": diagram}, ensure_ascii=False)
        policy = engine.thinking_options
        with patch.object(engine, "thinking_options", side_effect=lambda c: policy(c | {"endpoint": "https://api.deepseek.com/chat/completions"})):
            events = await self.invoke(payload)
        self.assertEqual([e["type"] for e in events], ["done"], events)
        self.assertEqual(len(SubmissionHandler.requests), 1)
        output = json.loads(events[-1]["text"])
        self.assertIsNone(output["method_id"])
        self.assertEqual(output["diagrams"], [value["diagram_outcome"]["primary_diagram"]])
        body = SubmissionHandler.requests[0][2]
        self.assertEqual(body["tool_choice"], "required")
        self.assertEqual(body["thinking"], {"type": "disabled"})
        self.assertEqual(len(body["tools"]), 18)
        self.assertNotIn(TOOL_NAME, [t["function"]["name"] for t in body["tools"]])
        images = [b["image_url"]["url"] for m in body["messages"] if isinstance(m.get("content"), list)
                  for b in m["content"] if b.get("type") == "image_url"]
        self.assertEqual(images, ["data:image/png;base64," + fixtures.PNG])

    async def test_renderer_tools_strict_is_explicit_beta_and_general_keeps_all_requested_answers(self):
        payload = self.payload() | {"solution_protocol": "renderer_tools_strict"}
        payload["configuration"]["endpoint"] = f"http://127.0.0.1:{self.server.server_port}/beta/chat/completions"
        SubmissionHandler.tool_name = "submit_general_math_solution"
        SubmissionHandler.arguments = json.dumps({"method_id": None, "visual_method_ids": [],
            "answer": "第一题条件不全；第二题答案须按原图确定，不能套已有方法。",
            "diagram_outcome": {"status": "unreadable_or_insufficient", "reason": "第一题右边裁切。"}})
        events = await self.invoke(payload)
        self.assertEqual([e["type"] for e in events], ["done"], events)
        self.assertEqual(len(SubmissionHandler.requests), 1)
        self.assertTrue(all(t["function"]["strict"] for t in SubmissionHandler.requests[0][2]["tools"]))
        self.assertIn("第二题", json.loads(events[-1]["text"])["answer"])
        self.assertEqual(json.loads(events[-1]["text"])["diagram_omission"],
                         {"status": "unreadable_or_insufficient", "reason": "第一题右边裁切。"})

    async def test_renderer_invalid_tool_duplicate_or_multiple_calls_never_retry(self):
        payload = self.payload() | {"solution_protocol": "renderer_tools"}
        for behavior in ("wrong", "multi", "prose", "length", "missing"):
            SubmissionHandler.requests.clear()
            SubmissionHandler.behavior = behavior
            SubmissionHandler.tool_name = "render_difference_ratio"
            events = await self.invoke(payload)
            self.assertEqual(events[-1]["type"], "error", events)
            self.assertEqual(len(SubmissionHandler.requests), 1)

    async def test_general_invalid_diagram_keeps_full_text_and_reports_failure_not_omission(self):
        SubmissionHandler.tool_name = "submit_general_math_solution"
        SubmissionHandler.arguments = json.dumps({"method_id": None, "visual_method_ids": [],
            "answer": "原题各边逐一核对，完整路径是E→F→G→H→I→E→G。",
            "diagram_outcome": {"status": "renderable", "primary_diagram": {
                "kind": "quantity_plan", "id": "bad", "title": "路径表", "view": "table", "layout": {}}}})
        events = await self.invoke(self.payload() | {"solution_protocol": "renderer_tools"})
        self.assertEqual([e["type"] for e in events], ["done"], events)
        self.assertEqual(len(SubmissionHandler.requests), 1)
        value = json.loads(events[-1]["text"])
        self.assertIn("E→F→G", value["answer"])
        self.assertEqual(value["diagram_submission_failure"], "submission_shape")
        self.assertNotIn("diagram_omission", value)
        self.assertEqual(value["diagrams"], [])

    async def test_moonshot_regular_protocol_explicitly_disables_server_schema_decoder(self):
        value = result()
        diagram = value["diagram_outcome"]["primary_diagram"].copy(); diagram.pop("kind")
        SubmissionHandler.tool_name = "render_difference_ratio"
        SubmissionHandler.arguments = json.dumps({"method_id": None, "visual_method_ids": [],
            "relationship": value["answer"], "diagram": diagram})
        with patch.object(engine, "is_kimi_k26", return_value=True):
            events = await self.invoke(self.payload() | {"solution_protocol": "renderer_tools"})
        self.assertEqual([e["type"] for e in events], ["done"], events)
        body = SubmissionHandler.requests[0][2]
        self.assertTrue(all(t["function"]["strict"] is False for t in body["tools"]))
        self.assertEqual(body["thinking"], {"type": "disabled"})
        self.assertEqual(body["max_tokens"], 8192)
        self.assertNotIn("max_completion_tokens", body)
        self.assertEqual(len(SubmissionHandler.requests), 1)

    async def test_explicit_beta_strict_one_request_and_schema_binding(self):
        payload = self.payload()
        payload["solution_protocol"] = "single_submission_strict"
        payload["configuration"]["endpoint"] = f"http://127.0.0.1:{self.server.server_port}/beta/chat/completions"
        value = result()
        value["diagram_outcome"]["additional_diagrams"] = []
        SubmissionHandler.arguments = json.dumps({"solution": value}, ensure_ascii=False)
        events = await self.invoke(payload)
        self.assertEqual([e["type"] for e in events], ["done"], events)
        self.assertEqual(len(SubmissionHandler.requests), 1)
        path, _, body = SubmissionHandler.requests[0]
        self.assertEqual(path, "/beta/chat/completions")
        self.assertTrue(body["tools"][0]["function"]["strict"])
        self.assertIsNone(json.loads(events[-1]["text"])["method_id"])

    async def test_strict_cannot_silently_switch_endpoint_or_retry_long_native_result(self):
        payload = self.payload() | {"solution_protocol": "single_submission_strict"}
        events = await self.invoke(payload)
        self.assertEqual(events[-1]["type"], "error")
        self.assertFalse(SubmissionHandler.requests)
        payload["configuration"]["endpoint"] = f"http://127.0.0.1:{self.server.server_port}/beta/chat/completions"
        value = result()
        value["answer"] = "重复计算" * 40
        value["diagram_outcome"]["additional_diagrams"] = []
        SubmissionHandler.arguments = json.dumps({"solution": value})
        events = await self.invoke(payload)
        self.assertEqual(events[-1]["type"], "error")
        self.assertEqual(len(SubmissionHandler.requests), 1)

    async def test_invalid_streams_never_retry_or_fallback(self):
        for behavior in ("wrong", "multi", "prose", "length", "missing", "401", "500"):
            with self.subTest(behavior=behavior):
                SubmissionHandler.requests.clear()
                SubmissionHandler.behavior = behavior
                events = await self.invoke()
                self.assertEqual(len(SubmissionHandler.requests), 1)
                self.assertEqual(events[-1]["type"], "error", events)
                self.assertFalse(any(e["type"] == "delta" for e in events))
                if behavior in ("length", "missing"):
                    self.assertEqual(events[-1]["submission_issue"], "submission_truncated")
                    self.assertEqual(events[-1]["stream_termination"],
                                     "token_limit" if behavior == "length" else "missing_terminal")
                self.assertNotIn("test-secret-never-print", json.dumps(events))

    async def test_duplicate_keys_and_bad_shape_rejected_on_wire(self):
        for arguments in ('{"mode":"general","mode":"native_recipe"}',
                          json.dumps(result()).replace('"difference_ratio"', '"unsupported"'),
                          '{"mode":'):
            SubmissionHandler.requests.clear()
            SubmissionHandler.arguments = arguments
            events = await self.invoke()
            self.assertEqual(len(SubmissionHandler.requests), 1)
            self.assertEqual(events[-1]["type"], "error")
            self.assertEqual(events[-1]["code"], "mathSubmission")
            self.assertIn(events[-1]["submission_issue"], {"submission_duplicate_key", "submission_shape", "submission_json"})

    async def test_explicit_no_diagram_reason_preserved_but_text_only_not_inferred(self):
        value = result() | {"mode": "general", "answer": "照片缺少总数。",
                           "diagram_outcome": {"status": "unreadable_or_insufficient", "reason": "右边条件被裁切。"}}
        SubmissionHandler.arguments = json.dumps(value)
        events = await self.invoke()
        answer = json.loads(events[-1]["text"])
        self.assertEqual(answer["diagrams"], [])
        self.assertNotIn("diagram_omission", answer, "V2 keeps its established envelope")
        self.assertIn("右边条件被裁切", answer["answer"])
        value["diagram_outcome"]["status"] = "user_requested_text_only"
        SubmissionHandler.arguments = json.dumps(value)
        events = await self.invoke()
        self.assertEqual(events[-1]["type"], "error")
        self.assertEqual(len(SubmissionHandler.requests), 2)

    async def test_invalid_protocol_or_extra_requests_rejected_before_http(self):
        for changes in ({"response_mode": None}, {"solution_protocol": "unknown"},
                        {"task": "math_method_selection"}, {"web_search": {"bad": True}}):
            events = await self.invoke(self.payload() | changes)
            self.assertEqual(events[-1]["type"], "error")
            self.assertFalse(SubmissionHandler.requests)
        payload = self.payload(); payload["configuration"]["api"] = "responses"
        events = await self.invoke(payload)
        self.assertEqual(events[-1]["type"], "error")
        self.assertFalse(SubmissionHandler.requests)

    async def test_english_wire_and_model_pool_remain_isolated(self):
        pool = engine.ModelPool()
        try:
            await self.invoke(pool=pool)
            payload = self.payload()
            payload.pop("response_mode"); payload.pop("solution_protocol")
            SubmissionHandler.behavior = "english"
            events = await self.invoke(payload, pool)
            self.assertEqual(events[-1]["text"], "Hello world")
            body = SubmissionHandler.requests[-1][2]
            self.assertNotIn("tools", body)
            self.assertNotIn("tool_choice", body)
            self.assertEqual(body["max_completion_tokens"], 900)
            self.assertEqual(body["messages"][0]["content"], payload["instructions"])
            self.assertEqual(len(pool.entries), 2)
        finally:
            await pool.close()
