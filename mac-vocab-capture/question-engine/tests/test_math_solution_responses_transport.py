"""Renderer submission through the real Responses SDK against a local HTTP server."""
import json
from pathlib import Path
import sys
import threading
import unittest
from http.server import ThreadingHTTPServer

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import question_engine as engine
import test_engine as fixtures
from test_math_solution_transport import SubmissionHandler, result


def renderer_arguments():
    value = result()
    diagram = value["diagram_outcome"]["primary_diagram"].copy()
    diagram.pop("kind")
    return {"method_id": None, "visual_method_ids": [],
            "relationship": value["answer"], "diagram": diagram}


class ResponsesSubmissionHandler(fixtures.Handler):
    requests = []
    client_ports = []
    behavior = "tool"
    tool_name = "render_difference_ratio"
    arguments = json.dumps(renderer_arguments(), ensure_ascii=False)

    def do_POST(self):
        if self.behavior != "400":
            return super().do_POST()
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.requests.append((self.path, {k.lower(): v for k, v in self.headers.items()}, body))
        raw = json.dumps({"error": {"message": "test-secret-never-print", "type": "invalid_request_error"}}).encode()
        self.send_response(400)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def chat(self):
        # Reuse the established Chat fixture without changing its class state.
        return SubmissionHandler.chat(self)

    def response_events(self):
        if self.behavior == "english":
            return super().response_events()
        output = []
        sequence = 0

        def event(kind, **fields):
            nonlocal sequence
            self.send_event({"type": kind, "sequence_number": sequence, **fields}, kind)
            sequence += 1

        if self.behavior == "reasoning":
            item = {"id": "reasoning-one", "type": "reasoning",
                    "summary": [{"type": "summary_text", "text": "Private reasoning summary."}]}
            event("response.output_item.added", output_index=0, item=item)
            event("response.output_item.done", output_index=0, item=item)
            output.append(item)
        count = 2 if self.behavior == "multi" else 1
        for index in range(count):
            output_index = len(output)
            item_id = f"function-{index}"
            name = "wrong_tool" if self.behavior == "wrong" else self.tool_name
            item = {"id": item_id, "type": "function_call", "call_id": f"call-{index}",
                    "name": name, "arguments": "", "status": "in_progress"}
            event("response.output_item.added", output_index=output_index, item=item.copy())
            for fragment in (self.arguments[:20], self.arguments[20:75], self.arguments[75:]):
                event("response.function_call_arguments.delta", item_id=item_id,
                      output_index=output_index, delta=fragment)
            event("response.function_call_arguments.done", item_id=item_id,
                  output_index=output_index, arguments=self.arguments)
            item.update(arguments=self.arguments, status="completed")
            event("response.output_item.done", output_index=output_index, item=item.copy())
            output.append(item)
        if self.behavior in ("prose", "refusal"):
            index = len(output)
            item = {"id": "message-outside", "type": "message", "role": "assistant",
                    "status": "in_progress", "content": []}
            event("response.output_item.added", output_index=index, item=item.copy())
            if self.behavior == "prose":
                block = {"type": "output_text", "text": "Outside tool prose.", "annotations": []}
                event("response.output_text.delta", item_id=item["id"], output_index=index,
                      content_index=0, delta=block["text"], logprobs=[])
                event("response.output_text.done", item_id=item["id"], output_index=index,
                      content_index=0, text=block["text"], logprobs=[])
            else:
                block = {"type": "refusal", "refusal": "Cannot answer."}
                event("response.refusal.delta", item_id=item["id"], output_index=index,
                      content_index=0, delta=block["refusal"])
                event("response.refusal.done", item_id=item["id"], output_index=index,
                      content_index=0, refusal=block["refusal"])
            item.update(status="completed", content=[block])
            event("response.output_item.done", output_index=index, item=item.copy())
            output.append(item)
        if self.behavior == "missing":
            return
        status = self.behavior if self.behavior in ("incomplete", "failed") else "completed"
        response = {"id": "response-one", "object": "response", "created_at": 1,
                    "status": status, "model": "gpt-6.1-sol", "output": output,
                    "error": {"code": "server_error", "message": "test-secret-never-print"} if status == "failed" else None,
                    "incomplete_details": {"reason": "max_output_tokens"} if status == "incomplete" else None,
                    "instructions": None, "parallel_tool_calls": False, "temperature": 1,
                    "tool_choice": "required", "tools": [], "top_p": 1,
                    "usage": {"input_tokens": 11, "output_tokens": 7, "total_tokens": 18,
                              "output_tokens_details": {"reasoning_tokens": 2}}}
        event("response." + status, response=response)


class ResponsesSubmissionWireTests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), ResponsesSubmissionHandler)
        cls.server.daemon_threads = True
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        ResponsesSubmissionHandler.requests.clear()
        ResponsesSubmissionHandler.behavior = "tool"
        ResponsesSubmissionHandler.tool_name = "render_difference_ratio"
        ResponsesSubmissionHandler.arguments = json.dumps(renderer_arguments(), ensure_ascii=False)

    def payload(self):
        payload = fixtures.request("responses", "/chatgpt/v1/responses")
        payload["configuration"].update(endpoint=f"http://127.0.0.1:{self.server.server_port}/chatgpt/v1/responses",
                                         model="gpt-6.1-sol", thinking="low", direct_connection=True)
        payload.update(response_mode="math_solution", solution_protocol="renderer_tools")
        return payload

    async def invoke(self, payload=None, pool=None):
        events = []
        await engine.run_request(payload or self.payload(), events.append, pool)
        return events

    def assert_one_error(self, events):
        self.assertEqual(len(ResponsesSubmissionHandler.requests), 1)
        self.assertEqual([event["type"] for event in events], ["error"], events)
        self.assertNotIn("test-secret-never-print", json.dumps(events))

    async def test_one_responses_post_flat_non_strict_tools_photo_history_and_native_inputs(self):
        events = await self.invoke()
        self.assertEqual([event["type"] for event in events], ["done"], events)
        self.assertEqual(len(ResponsesSubmissionHandler.requests), 1)
        value = json.loads(events[0]["text"])
        self.assertEqual(set(value), {"mode", "method_id", "visual_method_ids", "answer", "diagrams", "schemaVersion"})
        self.assertIsNone(value["method_id"])
        self.assertEqual(value["diagrams"], [result()["diagram_outcome"]["primary_diagram"]])
        self.assertEqual(events[0]["usage"], {"input_tokens": 11, "output_tokens": 7, "reasoning_tokens": 2})
        timings = events[0]["timings"]
        self.assertTrue(all(isinstance(v, float) and v >= 0 for v in timings.values()))
        self.assertLessEqual(timings["first_sdk_chunk"], timings["first_tool_arguments"])
        self.assertAlmostEqual(timings["first_tool_arguments"] + timings["arguments_to_stream_end"], timings["stream_total"])
        self.assertGreaterEqual(timings["engine_total"], timings["stream_total"])
        path, headers, body = ResponsesSubmissionHandler.requests[0]
        self.assertEqual(path, "/chatgpt/v1/responses")
        self.assertEqual(headers["authorization"], "Bearer test-secret-never-print")
        self.assertEqual(body["model"], "gpt-6.1-sol")
        self.assertEqual(body["reasoning"], {"effort": "low"})
        self.assertFalse(body["store"])
        self.assertTrue(body["stream"])
        self.assertFalse(body["parallel_tool_calls"])
        self.assertEqual(body["tool_choice"], "required")
        self.assertEqual(len(body["tools"]), 18)
        self.assertTrue(all(tool["type"] == "function" and tool["strict"] is False and
                            "function" not in tool and isinstance(tool["parameters"], dict) for tool in body["tools"]))
        self.assertIn("render_difference_ratio", {tool["name"] for tool in body["tools"]})
        images = [block["image_url"] for item in body["input"] if isinstance(item.get("content"), list)
                  for block in item["content"] if block.get("type") == "input_image"]
        self.assertEqual(images, ["data:image/png;base64," + fixtures.PNG])
        self.assertIn("First question", json.dumps(body["input"]))
        assistant = next(item for item in body["input"] if item.get("role") == "assistant")
        self.assertIn("First answer", json.dumps(assistant))
        self.assertNotIn("input_text", json.dumps(assistant))
        self.assertNotIn("temperature", body)

    async def test_reasoning_block_permitted_without_displaying_it(self):
        ResponsesSubmissionHandler.behavior = "reasoning"
        events = await self.invoke()
        self.assertEqual([event["type"] for event in events], ["done"], events)
        self.assertEqual(len(ResponsesSubmissionHandler.requests), 1)
        self.assertEqual(json.loads(events[0]["text"])["diagrams"][0]["multiplier"]["value"], 10)
        self.assertNotIn("Private reasoning summary", json.dumps(events))

    async def test_general_bad_graph_preserves_full_answer_and_typed_failure(self):
        ResponsesSubmissionHandler.tool_name = "submit_general_math_solution"
        answer = "逐边核对，完整路径是E→F→G→H→I→E→G。另一题答案为8。"
        ResponsesSubmissionHandler.arguments = json.dumps({"method_id": None, "visual_method_ids": [],
            "answer": answer, "diagram_outcome": {"status": "renderable", "primary_diagram": {
                "kind": "quantity_plan", "id": "bad", "title": "路径表", "view": "table", "layout": {}}}})
        events = await self.invoke()
        self.assertEqual([event["type"] for event in events], ["done"], events)
        self.assertEqual(len(ResponsesSubmissionHandler.requests), 1)
        value = json.loads(events[0]["text"])
        self.assertEqual(value["answer"], answer)
        self.assertEqual(value["diagram_submission_failure"], "submission_shape")
        self.assertNotIn("diagram_omission", value)
        self.assertEqual(value["diagrams"], [])

    async def test_general_no_help_preserves_explicit_omission(self):
        ResponsesSubmissionHandler.tool_name = "submit_general_math_solution"
        outcome = {"status": "no_helpful_diagram", "reason": "原题需要逐项核对，示意图不能帮助理解。"}
        ResponsesSubmissionHandler.arguments = json.dumps({"method_id": None, "visual_method_ids": [],
            "answer": "逐项核对后的答案是8。", "diagram_outcome": outcome})
        events = await self.invoke()
        self.assertEqual([event["type"] for event in events], ["done"], events)
        self.assertEqual(len(ResponsesSubmissionHandler.requests), 1)
        value = json.loads(events[0]["text"])
        self.assertEqual(value["diagram_omission"], outcome)
        self.assertEqual(value["diagrams"], [])
        self.assertNotIn("diagram_submission_failure", value)

    async def test_invalid_function_streams_no_retry_no_fallback_no_secret_leak(self):
        for behavior in ("wrong", "multi", "prose", "missing", "incomplete", "failed", "refusal", "400", "401", "500"):
            with self.subTest(behavior=behavior):
                ResponsesSubmissionHandler.requests.clear()
                ResponsesSubmissionHandler.behavior = behavior
                self.assert_one_error(await self.invoke())

    async def test_original_argument_text_rejects_duplicate_keys_and_malformed_json(self):
        original = json.dumps(renderer_arguments(), ensure_ascii=False)
        for arguments, issue in ((original.replace('"method_id": null', '"method_id": null, "method_id": null'), "submission_duplicate_key"),
                                 ('{"method_id":', "submission_json")):
            with self.subTest(issue=issue):
                ResponsesSubmissionHandler.requests.clear()
                ResponsesSubmissionHandler.arguments = arguments
                events = await self.invoke()
                self.assert_one_error(events)
                self.assertEqual(events[0]["code"], "mathSubmission")
                self.assertEqual(events[0]["submission_issue"], issue)

    async def test_native_invalid_number_keeps_relationship_clearly_incomplete_without_retry(self):
        original = renderer_arguments()
        ResponsesSubmissionHandler.arguments = json.dumps(original).replace('"value": 72', '"value": "72"')
        events = await self.invoke()
        self.assertEqual([event["type"] for event in events], ["done"], events)
        self.assertEqual(len(ResponsesSubmissionHandler.requests), 1)
        value = json.loads(events[0]["text"])
        self.assertEqual(value["answer"], original["relationship"])
        self.assertEqual(value["diagram_submission_failure"], "submission_relationship_only")
        self.assertEqual(value["diagrams"], [])
        self.assertIsNone(value["method_id"])
        self.assertEqual(value["visual_method_ids"], [])
        self.assertNotIn("diagram_omission", value)

    async def test_existing_v2_chat_submission_keeps_named_tool_and_six_field_envelope(self):
        from math_solution_contract import TOOL_NAME
        payload = self.payload()
        payload["solution_protocol"] = "single_submission"
        payload["configuration"].update(api="chatCompletions", model="public-test-model",
            endpoint=f"http://127.0.0.1:{self.server.server_port}/v1/chat/completions", thinking="off")
        ResponsesSubmissionHandler.tool_name = TOOL_NAME
        ResponsesSubmissionHandler.arguments = json.dumps(result(), ensure_ascii=False)
        events = await self.invoke(payload)
        self.assertEqual([event["type"] for event in events], ["done"], events)
        self.assertEqual(len(ResponsesSubmissionHandler.requests), 1)
        self.assertEqual(set(json.loads(events[0]["text"])),
                         {"mode", "method_id", "visual_method_ids", "answer", "diagrams", "schemaVersion"})
        path, _, body = ResponsesSubmissionHandler.requests[0]
        self.assertEqual(path, "/v1/chat/completions")
        self.assertEqual(body["tool_choice"], {"type": "function", "function": {"name": TOOL_NAME}})
        self.assertEqual(len(body["tools"]), 1)
        self.assertNotIn("strict", body["tools"][0]["function"])
        self.assertNotIn("parallel_tool_calls", body)
        self.assertNotIn("input", body)

    async def test_existing_english_responses_and_chat_submission_wire_remain_isolated(self):
        pool = engine.ModelPool()
        try:
            self.assertEqual((await self.invoke(pool=pool))[-1]["type"], "done")
            payload = self.payload()
            payload.pop("response_mode")
            payload.pop("solution_protocol")
            ResponsesSubmissionHandler.behavior = "english"
            events = await self.invoke(payload, pool)
            self.assertEqual(events[-1]["text"], "Hello world")
            english = ResponsesSubmissionHandler.requests[-1][2]
            self.assertNotIn("tools", english)
            self.assertNotIn("tool_choice", english)
            self.assertNotIn("parallel_tool_calls", english)
            self.assertFalse(english["store"])
            self.assertEqual(english["max_output_tokens"], 4096)
            self.assertEqual(len(pool.entries), 2)
            payload = self.payload()
            payload["configuration"].update(api="chatCompletions", model="public-test-model",
                endpoint=f"http://127.0.0.1:{self.server.server_port}/v1/chat/completions", thinking="off")
            ResponsesSubmissionHandler.behavior = "tool"
            events = await self.invoke(payload, pool)
            self.assertEqual(events[-1]["type"], "done", events)
            chat = ResponsesSubmissionHandler.requests[-1][2]
            self.assertEqual(chat["tool_choice"], "required")
            self.assertEqual(len(chat["tools"]), 18)
            self.assertTrue(all("function" in tool and "strict" not in tool["function"] for tool in chat["tools"]))
            self.assertNotIn("parallel_tool_calls", chat)
            self.assertNotIn("input", chat)
            self.assertIn("messages", chat)
            self.assertEqual(len(pool.entries), 3)
        finally:
            await pool.close()


if __name__ == "__main__":
    unittest.main()
