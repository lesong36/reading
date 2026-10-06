import asyncio
import base64
import gzip
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import unittest
import zlib
from unittest.mock import patch
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import question_engine as engine

PNG = base64.b64encode(b"\x89PNG\r\n\x1a\npublic-image").decode()


def request(api="chatCompletions", path="/v1/chat/completions", identifier="one"):
    return {
        "op": "answer", "id": identifier, "question": "What does it mean?",
        "instructions": "Explain only the supplied source.",
        "context": {"text": "There is a car in front of him.", "selected_word": "him", "image_data": PNG},
        "history": [{"question": "First question", "answer": "First answer"}],
        "configuration": {"model": "public-test-model", "api_key": "test-secret-never-print",
                          "endpoint": SERVER_URL + path, "api": api},
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    requests = []
    client_ports = []
    behavior = "normal"
    compression = False
    received = threading.Event()

    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.requests.append((self.path, {key.lower(): value for key, value in self.headers.items()}, body))
        self.client_ports.append(self.client_address[1])
        self.received.set()
        if self.behavior in ("401", "500"):
            raw = json.dumps({"error": {"message": "test-secret-never-print", "type": "auth"}}).encode()
            self.send_response(int(self.behavior))
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return
        if self.behavior.startswith("json"):
            text = "" if self.behavior == "json-empty" else "Hello world"
            if self.path.endswith("responses"):
                payload = {"id": "response-1", "object": "response", "created_at": 1,
                           "status": "incomplete" if self.behavior == "json-length" else "completed",
                           "error": None, "model": "public-test-model", "output": [
                               {"type": "message", "id": "msg-1", "role": "assistant", "status": "completed",
                                "content": [{"type": "output_text", "text": text, "annotations": []}]}]}
            elif self.path.endswith("messages"):
                payload = {"id": "msg-1", "type": "message", "role": "assistant", "model": "public-test-model",
                           "content": [{"type": "text", "text": text}],
                           "stop_reason": "max_tokens" if self.behavior == "json-length" else "end_turn",
                           "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 2}}
            else:
                payload = {"choices": [{"message": {"role": "assistant", "content": text},
                                         "finish_reason": "length" if self.behavior == "json-length" else "stop"}]}
            if self.behavior == "json-usage":
                if self.path.endswith("responses"):
                    payload["usage"] = {"input_tokens": 11, "output_tokens": 7, "total_tokens": 18,
                                        "output_tokens_details": {"reasoning_tokens": 2}}
                elif self.path.endswith("messages"):
                    payload["usage"] = {"input_tokens": 11, "output_tokens": 7,
                                        "output_tokens_details": {"thinking_tokens": 2}}
                else:
                    payload["usage"] = {"prompt_tokens": 11, "completion_tokens": 7, "total_tokens": 18,
                                        "completion_tokens_details": {"reasoning_tokens": 2}}
            elif self.behavior == "json-unknown-usage":
                payload.pop("usage", None)
            raw = json.dumps(payload).encode()
            if self.compression:
                raw = gzip.compress(raw)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            if self.compression:
                self.send_header("Content-Encoding", "gzip")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        if self.compression:
            self.send_header("Content-Encoding", "gzip")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        self.compressor = zlib.compressobj(wbits=31) if self.compression else None
        if self.behavior == "slow":
            time.sleep(1.5)
        try:
            if self.path.endswith("responses"):
                self.response_events()
            elif self.path.endswith("messages"):
                self.messages()
            else:
                self.chat()
            if self.compressor:
                self.wfile.write(self.compressor.flush(zlib.Z_FINISH))
        except (BrokenPipeError, ConnectionResetError):
            pass

    def send_event(self, payload, event=None):
        prefix = f"event: {event}\n" if event else ""
        self.send_bytes((prefix + "data: " + json.dumps(payload) + "\n\n").encode())

    def send_bytes(self, data):
        if self.compressor:
            data = self.compressor.compress(data) + self.compressor.flush(zlib.Z_SYNC_FLUSH)
        self.wfile.write(data)
        self.wfile.flush()

    def chat(self):
        for text in (() if self.behavior == "empty" else ("Hello ", "world")):
            self.send_event({"id": "chat-1", "object": "chat.completion.chunk", "created": 1,
                             "model": "public-test-model", "choices": [
                                 {"index": 0, "delta": {"content": text}, "finish_reason": None}]})
        if self.behavior != "missing":
            reason = "length" if self.behavior == "length" else "stop"
            self.send_event({"id": "chat-1", "object": "chat.completion.chunk", "created": 1,
                             "model": "public-test-model", "choices": [
                                 {"index": 0, "delta": {}, "finish_reason": reason}]})
            if self.behavior == "usage":
                self.send_event({"id": "chat-1", "object": "chat.completion.chunk", "created": 1,
                                 "model": "public-test-model", "choices": [],
                                 "usage": {"prompt_tokens": 11, "completion_tokens": 7, "total_tokens": 18,
                                           "completion_tokens_details": {"reasoning_tokens": 2}}})
            self.send_bytes(b"data: [DONE]\n\n")

    def messages(self):
        message = {"id": "msg-1", "type": "message", "role": "assistant", "content": [],
                   "model": "public-test-model", "stop_reason": None, "stop_sequence": None,
                   "usage": {"input_tokens": 10, "output_tokens": 0}}
        if self.behavior == "usage":
            message["usage"].update(cache_read_input_tokens=4, cache_creation_input_tokens=3)
        self.send_event({"type": "message_start", "message": message}, "message_start")
        self.send_event({"type": "content_block_start", "index": 0,
                         "content_block": {"type": "thinking", "thinking": ""}}, "content_block_start")
        self.send_event({"type": "content_block_delta", "index": 0,
                         "delta": {"type": "thinking_delta", "thinking": "Hidden thought"}}, "content_block_delta")
        self.send_event({"type": "content_block_stop", "index": 0}, "content_block_stop")
        self.send_event({"type": "content_block_start", "index": 1,
                         "content_block": {"type": "text", "text": ""}}, "content_block_start")
        for text in ("Hello ", "world"):
            self.send_event({"type": "content_block_delta", "index": 1,
                             "delta": {"type": "text_delta", "text": text}}, "content_block_delta")
        self.send_event({"type": "content_block_stop", "index": 1}, "content_block_stop")
        if self.behavior != "missing":
            reason = "max_tokens" if self.behavior == "length" else "end_turn"
            final_usage = {"output_tokens": 2}
            if self.behavior == "usage":
                self.send_event({"type": "message_delta", "delta": {"stop_reason": None, "stop_sequence": None},
                                 "usage": {"output_tokens": 1, "output_tokens_details": {"thinking_tokens": 1}}}, "message_delta")
                final_usage = {"input_tokens": 10, "output_tokens": 7, "cache_read_input_tokens": 4,
                               "cache_creation_input_tokens": 3, "output_tokens_details": {"thinking_tokens": 2}}
            self.send_event({"type": "message_delta", "delta": {"stop_reason": reason, "stop_sequence": None},
                             "usage": final_usage}, "message_delta")
            if self.behavior != "missing-stop":
                self.send_event({"type": "message_stop"}, "message_stop")

    def response_events(self):
        item = {"id": "message-1", "type": "message", "role": "assistant", "status": "in_progress", "content": []}
        self.send_event({"type": "response.output_item.added", "output_index": 0, "item": item,
                         "sequence_number": 0})
        if self.behavior == "refusal":
            self.send_event({"type": "response.refusal.delta", "item_id": "message-1", "output_index": 0,
                             "content_index": 0, "delta": "Cannot answer.", "sequence_number": 1})
            self.send_event({"type": "response.refusal.done", "item_id": "message-1", "output_index": 0,
                             "content_index": 0, "refusal": "Cannot answer.", "sequence_number": 2})
        for index, text in enumerate(() if self.behavior == "refusal" else ("Hello ", "world"), 1):
            self.send_event({"type": "response.output_text.delta", "item_id": "message-1", "output_index": 0,
                             "content_index": 0, "delta": text, "sequence_number": index, "logprobs": []})
        if self.behavior != "missing":
            status = "incomplete" if self.behavior == "length" else "completed"
            item.update(status="completed", content=[{"type": "output_text", "text": "Hello world", "annotations": []}])
            if self.behavior == "refusal":
                item["content"] = [{"type": "refusal", "refusal": "Cannot answer."}]
            response = {"id": "response-1", "object": "response", "created_at": 1, "status": status,
                        "error": None, "incomplete_details": {"reason": "max_output_tokens"} if status == "incomplete" else None,
                        "instructions": None, "model": "public-test-model", "output": [item],
                        "parallel_tool_calls": False, "temperature": 1, "tool_choice": "auto", "tools": [],
                        "top_p": 1, "usage": {"input_tokens": 10, "output_tokens": 2, "total_tokens": 12}}
            if self.behavior == "usage":
                response["usage"] = {"input_tokens": 11, "output_tokens": 7, "total_tokens": 18,
                                     "output_tokens_details": {"reasoning_tokens": 2}}
            elif self.behavior == "unknown-usage":
                response.pop("usage")
            self.send_event({"type": "response." + status, "response": response, "sequence_number": 3})


SERVER = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
SERVER.daemon_threads = True
SERVER_URL = f"http://127.0.0.1:{SERVER.server_port}"
threading.Thread(target=SERVER.serve_forever, daemon=True).start()


class ProxyResolverTests(unittest.TestCase):
    def test_usage_counts_only_preserve_known_non_negative_integers(self):
        self.assertIsNone(engine.usage_for_event(None))
        for invalid in ({"input_tokens": True, "output_tokens": 3}, {"input_tokens": 1, "output_tokens": -1},
                        {"input_tokens": 1.5, "output_tokens": 3}, {"input_tokens": 1}):
            self.assertIsNone(engine.usage_for_event(invalid))
        self.assertEqual(engine.usage_for_event({"input_tokens": 11, "output_tokens": 7,
                                                "output_token_details": {"reasoning": 0}}),
                         {"input_tokens": 11, "output_tokens": 7, "reasoning_tokens": 0})

    def test_usage_options_only_for_verified_chat_hosts(self):
        for host in ("api.openai.com", "api.deepseek.com", "API.DEEPSEEK.COM"):
            self.assertTrue(engine.supports_chat_usage(f"https://{host}/v1/chat/completions"))
        for host in ("public.invalid", "localhost", "api.openai.com.invalid", "127.0.0.1"):
            self.assertFalse(engine.supports_chat_usage(f"https://{host}/v1/chat/completions"))

    def test_mac_system_source_ignores_environment_proxy_and_no_proxy(self):
        proxies = {"http": "http://127.0.0.1:9990", "https": "http://127.0.0.1:9991"}
        with patch.object(engine.sys, "platform", "darwin"), \
                patch.dict(os.environ, {"no_proxy": "*", "HTTP_PROXY": "http://bad.invalid:9992"}, clear=True), \
                patch.object(engine.urllib_request, "getproxies", side_effect=AssertionError("environment lookup")), \
                patch.object(engine.urllib_request, "getproxies_macosx_sysconf", return_value=proxies, create=True) as source, \
                patch.object(engine.urllib_request, "proxy_bypass_macosx_sysconf", return_value=False, create=True):
            self.assertEqual(engine.system_proxy_for("https://public.invalid/v1/responses"), proxies["https"])
            self.assertEqual(engine.system_proxy_for("http://public.invalid/v1/chat/completions"), proxies["http"])
            self.assertEqual(source.call_count, 2)

    def test_loopback_always_bypasses_before_mac_lookup(self):
        with patch.object(engine.sys, "platform", "darwin"), \
                patch.object(engine.urllib_request, "getproxies_macosx_sysconf", create=True) as source, \
                patch.object(engine.urllib_request, "proxy_bypass_macosx_sysconf", create=True) as bypass:
            for host in ("localhost", "LOCALHOST", "app.localhost", "127.0.0.1", "127.6.5.4", "[::1]", "[::ffff:127.0.0.1]"):
                with self.subTest(host=host):
                    self.assertIsNone(engine.system_proxy_for(f"http://{host}:1234/v1/chat/completions"))
            source.assert_not_called()
            bypass.assert_not_called()

    def test_mac_exception_and_non_mac_do_not_use_proxy(self):
        with patch.object(engine.urllib_request, "getproxies_macosx_sysconf", create=True) as source, \
                patch.object(engine.urllib_request, "proxy_bypass_macosx_sysconf", return_value=True, create=True) as bypass:
            with patch.object(engine.sys, "platform", "darwin"):
                self.assertIsNone(engine.system_proxy_for("https://private.invalid/v1/responses"))
                bypass.assert_called_once_with("private.invalid")
            with patch.object(engine.sys, "platform", "linux"):
                self.assertIsNone(engine.system_proxy_for("https://public.invalid/v1/responses"))
            source.assert_not_called()


class SDKTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        Handler.requests.clear()
        Handler.client_ports.clear()
        Handler.behavior = "normal"
        Handler.compression = False
        Handler.received.clear()

    async def answer(self, payload):
        events = []
        await engine.run_request(payload, events.append)
        return events

    async def test_followup_reuses_idle_connection_after_typing_pause(self):
        # Complete JSON envelopes keep the test server connection open. The
        # client must preserve it across a natural pause before a follow-up.
        Handler.behavior = "json"
        pool = engine.ModelPool()
        try:
            for turn in range(2):
                if turn:
                    await asyncio.sleep(6)
                events = []
                await engine.run_request(request(identifier=str(turn)), events.append, pool)
                self.assertEqual(events[-1]["type"], "done")
            self.assertEqual(len(Handler.requests), 2)
            self.assertEqual(Handler.client_ports[0], Handler.client_ports[1])
        finally:
            await pool.close()

    async def test_direct_choice_skips_proxy_without_retry_all_protocols(self):
        for api, path in (("chatCompletions", "/v1/chat/completions"), ("responses", "/v1/responses"),
                          ("anthropicMessages", "/v1/messages")):
            Handler.requests.clear()
            payload = request(api, path)
            payload["configuration"]["direct_connection"] = True
            with patch.object(engine, "system_proxy_for", return_value="http://127.0.0.1:1") as proxy:
                events = await self.answer(payload)
                proxy.assert_not_called()
            self.assertEqual(events[-1]["type"], "done")
            self.assertEqual(len(Handler.requests), 1)

    async def test_network_choices_isolate_clients_and_invalid_choice_never_sends(self):
        pool = engine.ModelPool()
        try:
            with patch.object(engine, "system_proxy_for", return_value=None) as proxy:
                for direct in (False, True, False):
                    payload = request()
                    payload["configuration"]["direct_connection"] = direct
                    events = []
                    await engine.run_request(payload, events.append, pool)
                    self.assertEqual(events[-1]["type"], "done")
                self.assertEqual(proxy.call_count, 2)
                self.assertEqual(len(pool.entries), 2)
                self.assertEqual(len(Handler.requests), 3)
                payload["configuration"]["direct_connection"] = "true"
                events = []
                await engine.run_request(payload, events.append, pool)
                self.assertEqual(events[-1]["code"], "invalid")
                self.assertEqual(len(Handler.requests), 3)
        finally:
            await pool.close()

    async def test_thinking_controls_reach_sdk_and_cache_by_choice(self):
        pool = engine.ModelPool()
        try:
            for api, model, expected in [
                ("responses", "gpt-6.1-sol", {"reasoning": {"effort": "low"}}),
                ("anthropicMessages", "claude-sonnet-5-5", {"thinking": {"type": "between_tools"}, "output_config": {"effort": "low"}}),
            ]:
                Handler.requests.clear()
                for choice in ("off", "high"):
                    payload = request(api, "/v1/responses" if api == "responses" else "/v1/messages")
                    payload["configuration"].update(model=model, thinking=choice)
                    events=[]
                    await engine.run_request(payload, events.append, pool)
                    self.assertEqual(events[-1]["type"], "done")
                body=Handler.requests[0][2]
                for key, value in expected.items():
                    self.assertEqual(body[key], value)
                body=Handler.requests[1][2]
                self.assertEqual(body["reasoning"]["effort"] if api == "responses" else body["output_config"]["effort"], "high")
                self.assertEqual(len(Handler.requests), 2)
        finally:
            await pool.close()

    async def test_kimi_k26_sdk_omits_temperature_and_honors_thinking(self):
        pool = engine.ModelPool()
        try:
            with patch.object(engine, "is_kimi_k26", return_value=True):
                for choice in ("off", "automatic", "low", "medium", "high"):
                    payload = request()
                    payload["configuration"].update(model="kimi-k2.6", thinking=choice)
                    events = []
                    await engine.run_request(payload, events.append, pool)
                    self.assertEqual(events[-1]["type"], "done")
                    body = Handler.requests[-1][2]
                    self.assertNotIn("temperature", body)
                    self.assertNotIn("max_completion_tokens", body)
                    self.assertNotIn("reasoning_effort", body)
                    if choice == "automatic":
                        self.assertNotIn("thinking", body)
                    else:
                        self.assertEqual(body["thinking"]["type"], "disabled" if choice == "off" else "enabled")
                    self.assertEqual(body["max_tokens"], 900 if choice == "off" else 16384)
            self.assertEqual(len(Handler.requests), 5, "No fallback or repeated chargeable calls")
        finally:
            await pool.close()

    def test_kimi_policy_is_scoped_to_official_service_and_model(self):
        cfg = {"endpoint": "https://api.moonshot.cn/v1/chat/completions", "api": "chatCompletions", "model": "kimi-k2.6", "thinking": "off"}
        for host in ("api.moonshot.cn", "api.moonshot.ai"):
            cfg["endpoint"] = "https://" + host + "/v1/chat/completions"
            self.assertTrue(engine.is_kimi_k26(cfg))
            self.assertEqual(engine.thinking_options(cfg), {"extra_body": {"thinking": {"type": "disabled"}}})
        for change in ({"endpoint": "https://gateway.test/v1/chat/completions"}, {"model": "unknown-kimi"}, {"api": "responses"}):
            other = cfg | change
            self.assertFalse(engine.is_kimi_k26(other))
            self.assertEqual(engine.thinking_options(other), {})

    async def test_deepseek_thinking_controls_reach_actual_sdk_body(self):
        policy = engine.thinking_options
        def deepseek_policy(configuration):
            return policy(configuration | {"endpoint": "https://api.deepseek.com/v1/chat/completions"})
        pool = engine.ModelPool()
        try:
            with patch.object(engine, "thinking_options", side_effect=deepseek_policy):
                for choice in ("off", "low", "medium", "high"):
                    payload = request()
                    payload["configuration"].update(model="deepseek-flash", thinking=choice)
                    events = []
                    await engine.run_request(payload, events.append, pool)
                    self.assertEqual(events[-1]["type"], "done")
                    body = Handler.requests[-1][2]
                    self.assertEqual(body["thinking"]["type"], "disabled" if choice == "off" else "enabled")
                    if choice != "off":
                        self.assertEqual(body["reasoning_effort"], "low" if choice == "low" else "high")
                self.assertEqual(len(Handler.requests), 4)
        finally:
            await pool.close()

    def test_documented_thinking_capabilities_and_unknown_defaults(self):
        cfg={"endpoint":"https://api.deepseek.com/v1/chat/completions", "api":"chatCompletions", "model":"deepseek-flash", "thinking":"off"}
        self.assertEqual(engine.thinking_options(cfg), {"extra_body":{"thinking":{"type":"disabled"}}})
        cfg["thinking"]="medium"
        self.assertEqual(engine.thinking_options(cfg)["reasoning_effort"], "high")
        cfg.update(endpoint="https://gateway.test/v1/responses",api="responses",model="gpt-5.4",thinking="off")
        self.assertEqual(engine.thinking_options(cfg), {"reasoning":{"effort":"none"}})
        cfg.update(model="gpt-6.1-sol")
        self.assertEqual(engine.thinking_options(cfg), {"reasoning":{"effort":"low"}})
        cfg.update(api="anthropicMessages",model="claude-opus-5-5")
        options=engine.thinking_options(cfg)
        self.assertEqual(options["thinking"],{"type":"adaptive"})
        self.assertEqual(options["output_config"],{"effort":"low"})
        cfg.update(model="unknown")
        self.assertEqual(engine.thinking_options(cfg),{})
        cfg.update(thinking="automatic")
        self.assertEqual(engine.thinking_options(cfg),{})
        cfg.update(thinking="high")
        with self.assertRaises(engine.EngineError):engine.thinking_options(cfg)

    async def test_chat_real_sdk_path_auth_image_history(self):
        events = await self.answer(request())
        self.assertEqual(events[-1], {"id": "one", "type": "done", "text": "Hello world"})
        self.assertEqual([e["text"] for e in events[:-1]], ["Hello ", "world"])
        path, headers, body = Handler.requests[0]
        self.assertEqual(path, "/v1/chat/completions")
        self.assertEqual(headers["authorization"], "Bearer test-secret-never-print")
        self.assertEqual(body["temperature"], .2)
        self.assertEqual(body.get("max_tokens", body.get("max_completion_tokens")), 900)
        self.assertIn("image_url", json.dumps(body["messages"][1]))
        self.assertEqual(body["messages"][3], {"role": "assistant", "content": "First answer"})
        self.assertEqual(len(Handler.requests), 1)

    async def test_sdk_stream_usage_all_protocols_without_double_counting(self):
        for api, path in (("chatCompletions", "/v1/chat/completions"), ("responses", "/v1/responses"),
                          ("anthropicMessages", "/v1/messages")):
            with self.subTest(api=api):
                Handler.requests.clear()
                Handler.behavior = "usage"
                with patch.object(engine, "supports_chat_usage", return_value=True):
                    events = await self.answer(request(api, path))
                self.assertEqual(events[-1]["usage"], {
                    "input_tokens": 17 if api == "anthropicMessages" else 11,
                    "output_tokens": 7, "reasoning_tokens": 2})
                self.assertEqual(events[-1]["text"], "Hello world")
                self.assertEqual([event["text"] for event in events if event["type"] == "delta"], ["Hello ", "world"])
                self.assertEqual(len(Handler.requests), 1)
                body = Handler.requests[0][2]
                if api == "chatCompletions":
                    self.assertEqual(body["stream_options"], {"include_usage": True})
                else:
                    self.assertNotIn("stream_options", body)

    async def test_unknown_usage_omitted_without_changing_gateway_requests(self):
        for api, path in (("chatCompletions", "/v1/chat/completions"), ("responses", "/v1/responses"),
                          ("anthropicMessages", "/v1/messages")):
            with self.subTest(api=api):
                Handler.requests.clear()
                Handler.behavior = "json-unknown-usage" if api == "anthropicMessages" else "unknown-usage"
                events = await self.answer(request(api, path))
                self.assertEqual(events[-1], {"id": "one", "type": "done", "text": "Hello world"})
                self.assertNotIn("stream_options", Handler.requests[0][2])
                self.assertEqual(len(Handler.requests), 1)

    async def test_complete_json_usage_all_protocols_publishes_once(self):
        Handler.behavior = "json-usage"
        for api, path in (("chatCompletions", "/v1/chat/completions"), ("responses", "/v1/responses"),
                          ("anthropicMessages", "/v1/messages")):
            with self.subTest(api=api):
                Handler.requests.clear()
                events = await self.answer(request(api, path))
                self.assertEqual(events[-1], {"id": "one", "type": "done", "text": "Hello world",
                                             "usage": {"input_tokens": 11, "output_tokens": 7, "reasoning_tokens": 2}})
                self.assertEqual([event["type"] for event in events], ["delta", "done"])
                self.assertEqual(len(Handler.requests), 1)

    async def test_real_http_request_uses_explicit_fake_system_proxy(self):
        payload = request()
        payload["configuration"]["endpoint"] = "http://public.invalid/v1/chat/completions"
        with patch.object(engine.sys, "platform", "darwin"), \
                patch.object(engine.urllib_request, "getproxies_macosx_sysconf", return_value={"http": SERVER_URL}, create=True), \
                patch.object(engine.urllib_request, "proxy_bypass_macosx_sysconf", return_value=False, create=True):
            events = await self.answer(payload)
        self.assertEqual(events[-1], {"id": "one", "type": "done", "text": "Hello world"})
        self.assertEqual(len(Handler.requests), 1)
        self.assertEqual(Handler.requests[0][0], payload["configuration"]["endpoint"])

    async def test_proxy_changes_separate_cache_and_client_keeps_environment_off(self):
        pool = engine.ModelPool()
        configuration = request()["configuration"]
        configuration["endpoint"] = "https://public.invalid/v1/chat/completions"
        routes = ["http://127.0.0.1:9990", "http://127.0.0.1:9990", "http://127.0.0.1:9991", None]
        options = []
        original_client = engine.httpx.AsyncClient

        class ObservedClient(original_client):
            def __init__(self, **kwargs):
                options.append({"proxy": kwargs.get("proxy"), "trust_env": kwargs.get("trust_env")})
                super().__init__(**kwargs)

        try:
            with patch.object(engine, "system_proxy_for", side_effect=routes) as resolver, \
                    patch.object(engine.httpx, "AsyncClient", ObservedClient):
                acquired = []
                for _ in routes:
                    key, model = await pool.acquire(configuration)
                    acquired.append((key, model))
                    pool.release(key)
            self.assertEqual(resolver.call_count, 4)
            self.assertEqual(acquired[0][0], acquired[1][0])
            self.assertIs(acquired[0][1], acquired[1][1])
            self.assertNotEqual(acquired[0][0], acquired[2][0])
            self.assertNotEqual(acquired[2][0], acquired[3][0])
            self.assertEqual(options, [{"proxy": route, "trust_env": False} for route in (routes[0], routes[2], None)])
            self.assertEqual(len(pool.entries), 3)
        finally:
            await pool.close()

    async def test_responses_real_sdk_exact_proxy_history_and_no_temperature(self):
        events = await self.answer(request("responses", "/chatgpt/v1/responses"))
        self.assertEqual(events[-1]["type"], "done", events)
        self.assertEqual(events[-1]["text"], "Hello world")
        path, _, body = Handler.requests[0]
        self.assertEqual(path, "/chatgpt/v1/responses")
        self.assertNotIn("temperature", body)
        self.assertFalse(body["store"])
        self.assertEqual(body["max_output_tokens"], 4096)
        assistant = next(item for item in body["input"] if item.get("role") == "assistant")
        self.assertNotIn("input_text", json.dumps(assistant))
        self.assertIn("First answer", json.dumps(assistant))

    async def test_anthropic_real_sdk_custom_endpoint_and_thinking_hidden(self):
        events = await self.answer(request("anthropicMessages", "/custom/messages"))
        self.assertEqual(events[-1]["type"], "done", events)
        self.assertEqual(events[-1]["text"], "Hello world")
        self.assertNotIn("Hidden thought", json.dumps(events))
        path, headers, body = Handler.requests[0]
        self.assertEqual(path, "/custom/messages")
        self.assertEqual(headers["x-api-key"], "test-secret-never-print")
        self.assertIn("anthropic-version", headers)
        self.assertEqual(body["max_tokens"], 900)
        self.assertEqual(body["messages"][0]["content"][1]["source"]["data"], PNG)

    async def test_http_401_no_retry_and_no_secret_errors(self):
        Handler.behavior = "401"
        events = await self.answer(request())
        self.assertEqual(events, [{"id": "one", "type": "error", "code": "server", "status": 401}])
        self.assertNotIn("test-secret", json.dumps(events))
        self.assertEqual(len(Handler.requests), 1)

    async def test_real_http_500_remains_server_with_status_without_retry(self):
        Handler.behavior = "500"
        events = await self.answer(request())
        self.assertEqual(events, [{"id": "one", "type": "error", "code": "server", "status": 500}])
        self.assertNotIn("test-secret", json.dumps(events))
        self.assertEqual(len(Handler.requests), 1)

    async def test_network_timeout_and_response_errors_never_invent_http_status(self):
        fake_request = engine.httpx.Request("POST", "https://public.invalid/v1/messages",
                                            headers={"Authorization": "Bearer fake-key-never-print"})
        cases = [
            (engine.openai.APIConnectionError(message="fake-key-never-print", request=fake_request), "connection"),
            (engine.anthropic.APIConnectionError(message="fake-key-never-print", request=fake_request), "connection"),
            (engine.httpx.ConnectError("fake-key-never-print", request=fake_request), "connection"),
            (engine.openai.APITimeoutError(fake_request), "timeout"),
            (engine.anthropic.APITimeoutError(fake_request), "timeout"),
            (engine.httpx.ReadTimeout("fake-key-never-print", request=fake_request), "timeout"),
            (engine.EngineError("server"), "response"),
            (ValueError("fake-key-never-print"), "response"),
        ]
        for error, code in cases:
            with self.subTest(error=type(error).__name__):
                with patch.object(engine, "stream_answer", side_effect=error):
                    events = await self.answer(request())
                self.assertEqual(events, [{"id": "one", "type": "error", "code": code}])
                self.assertNotIn("fake-key", json.dumps(events))
        self.assertFalse(Handler.requests)

    async def test_missing_terminal_and_length_rejected_all_protocols(self):
        for api, path in (("chatCompletions", "/v1/chat/completions"), ("responses", "/v1/responses"),
                          ("anthropicMessages", "/v1/messages")):
            for behavior in ("missing", "length"):
                with self.subTest(api=api, behavior=behavior):
                    Handler.behavior = behavior
                    events = await self.answer(request(api, path))
                    self.assertEqual(events[-1].get("code"), "truncated", events)
                    self.assertNotIn("done", [e["type"] for e in events])

    async def test_invalid_image_never_sent(self):
        payload = request()
        payload["context"]["image_data"] = "not image"
        events = await self.answer(payload)
        self.assertEqual(events[-1]["code"], "invalid")
        self.assertFalse(Handler.requests)

    async def test_blank_local_key_uses_dummy_not_environment_key(self):
        payload = request()
        payload["configuration"]["api_key"] = ""
        await self.answer(payload)
        self.assertEqual(Handler.requests[0][1]["authorization"], "Bearer local")

    async def test_six_turn_bound_and_image_only_context(self):
        payload = request()
        payload["context"]["text"] = ""
        payload["history"] = [{"question": f"Q{i}", "answer": f"A{i}"} for i in range(8)]
        events = await self.answer(payload)
        self.assertEqual(events[-1]["type"], "done")
        body = Handler.requests[0][2]
        self.assertEqual(len(body["messages"]), 15)
        self.assertEqual(body["messages"][2]["content"], "Q2")

    async def test_claude_missing_message_stop_rejected(self):
        Handler.behavior = "missing-stop"
        events = await self.answer(request("anthropicMessages", "/v1/messages"))
        self.assertEqual(events[-1].get("code"), "truncated", events)

    async def test_responses_refusal_displayed(self):
        Handler.behavior = "refusal"
        events = await self.answer(request("responses", "/v1/responses"))
        self.assertEqual(events[-1], {"id": "one", "type": "done", "text": "Cannot answer.",
                                     "usage": {"input_tokens": 10, "output_tokens": 2}})

    async def test_empty_normal_response_rejected(self):
        Handler.behavior = "empty"
        events = await self.answer(request())
        self.assertEqual(events[-1].get("code"), "empty", events)

    async def test_timeout_is_bounded_without_retry(self):
        Handler.behavior = "slow"
        timeout = asyncio.timeout
        with patch.object(engine.asyncio, "timeout", side_effect=lambda _: timeout(.03)):
            events = await self.answer(request())
        self.assertEqual(events[-1].get("code"), "timeout", events)
        self.assertEqual(len(Handler.requests), 1)

    async def test_credentials_in_endpoint_and_unknown_protocol_rejected(self):
        for changes in ({"endpoint": "https://user:password@example.com/v1/responses"}, {"api": "unknown"}):
            payload = request()
            payload["configuration"].update(changes)
            events = await self.answer(payload)
            self.assertEqual(events[-1].get("code"), "invalid", events)
        self.assertFalse(Handler.requests)

    async def test_profile_reuse_key_change_eviction_and_close(self):
        pool = engine.ModelPool(limit=2)
        payload = request()
        try:
            await engine.run_request(payload, lambda _: None, pool)
            first = next(iter(pool.entries.values()))
            await engine.run_request(payload, lambda _: None, pool)
            self.assertIs(first, next(iter(pool.entries.values())))
            payload["configuration"]["api_key"] = "second-test-key"
            await engine.run_request(payload, lambda _: None, pool)
            self.assertEqual(len(pool.entries), 2)
            payload["configuration"]["model"] = "second-test-model"
            await engine.run_request(payload, lambda _: None, pool)
            self.assertEqual(len(pool.entries), 2)
            self.assertTrue(first["client"].is_closed)
        finally:
            entries = list(pool.entries.values())
            await pool.close()
            self.assertTrue(all(entry["client"].is_closed for entry in entries))
            self.assertFalse(pool.entries)

    async def test_concurrent_same_profile_during_eviction_shares_one_client(self):
        pool = engine.ModelPool(limit=2)
        configurations = []
        for name in ("a", "b", "c"):
            configuration = request()["configuration"]
            configuration["model"] = name
            configurations.append(configuration)
        try:
            for configuration in configurations[:2]:
                key, _ = await pool.acquire(configuration)
                pool.release(key)
            close_entry = pool.close_entry

            async def delayed_close(entry):
                await asyncio.sleep(.02)
                await close_entry(entry)

            with patch.object(pool, "close_entry", side_effect=delayed_close):
                first, second = await asyncio.gather(
                    pool.acquire(configurations[2]), pool.acquire(configurations[2]))
            self.assertEqual(first[0], second[0])
            self.assertIs(first[1], second[1])
            self.assertEqual(pool.entries[first[0]]["users"], 2)
            pool.release(first[0])
            pool.release(second[0])
            self.assertEqual(pool.entries[first[0]]["users"], 0)
            self.assertEqual(len(pool.entries), 2)
        finally:
            await pool.close()

    async def test_complete_json_fallback_all_protocols_without_retry(self):
        for api, path in (("chatCompletions", "/v1/chat/completions"), ("responses", "/v1/responses"),
                          ("anthropicMessages", "/v1/messages")):
            for behavior in ("json", "json-empty", "json-length"):
                with self.subTest(api=api, behavior=behavior):
                    Handler.requests.clear()
                    Handler.behavior = behavior
                    events = await self.answer(request(api, path))
                    self.assertEqual(len(Handler.requests), 1)
                    if behavior == "json":
                        expected = {"id": "one", "type": "done", "text": "Hello world"}
                        if api == "anthropicMessages":
                            expected["usage"] = {"input_tokens": 1, "output_tokens": 2}
                        self.assertEqual(events[-1], expected)
                        self.assertEqual([event["type"] for event in events], ["delta", "done"])
                    else:
                        self.assertEqual(len(events), 1, events)
                        self.assertEqual(events[0]["code"], "empty" if behavior == "json-empty" else "truncated")

    async def test_compressed_complete_json_all_protocols_without_retry(self):
        Handler.compression = True
        for api, path in (("chatCompletions", "/v1/chat/completions"), ("responses", "/v1/responses"),
                          ("anthropicMessages", "/v1/messages")):
            with self.subTest(api=api):
                Handler.requests.clear()
                Handler.behavior = "json"
                events = await self.answer(request(api, path))
                self.assertEqual(len(Handler.requests), 1)
                expected = {"id": "one", "type": "done", "text": "Hello world"}
                if api == "anthropicMessages":
                    expected["usage"] = {"input_tokens": 1, "output_tokens": 2}
                self.assertEqual(events[-1], expected)
                self.assertEqual(len(events), 2, events)

    async def test_compressed_claude_sse_keeps_sdk_boundary_checks(self):
        Handler.compression = True
        events = await self.answer(request("anthropicMessages", "/v1/messages"))
        self.assertEqual(events[-1], {"id": "one", "type": "done", "text": "Hello world",
                                     "usage": {"input_tokens": 10, "output_tokens": 2}})
        Handler.behavior = "missing-stop"
        events = await self.answer(request("anthropicMessages", "/v1/messages"))
        self.assertEqual(events[-1].get("code"), "truncated", events)


class ProcessTests(unittest.TestCase):
    def setUp(self):
        Handler.requests.clear()
        Handler.client_ports.clear()
        Handler.behavior = "normal"
        Handler.compression = False
        Handler.received.clear()
        environment = os.environ.copy()
        environment.update(LANGSMITH_TRACING="true", LANGCHAIN_TRACING_V2="true",
                           LANGSMITH_ENDPOINT=SERVER_URL + "/trace", LANGSMITH_API_KEY="fake-trace-key")
        executable = os.environ.get("QUESTION_ENGINE_EXECUTABLE")
        command = [executable] if executable else [sys.executable, str(Path(engine.__file__))]
        self.process = subprocess.Popen(command,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        text=True, env=environment)
        ready = json.loads(self.process.stdout.readline())
        self.assertEqual(ready, {"type": "ready", "protocol": 1, "langchain_version": "1.4.3"})

    def tearDown(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.communicate(timeout=5)

    def send(self, payload):
        self.process.stdin.write(json.dumps(payload) + "\n")
        self.process.stdin.flush()

    def test_typing_pause_keeps_connection_in_persistent_engine(self):
        Handler.behavior = "json"
        for turn in range(2):
            if turn:
                time.sleep(6)
            self.send(request(identifier=str(turn)))
            while True:
                event = json.loads(self.process.stdout.readline())
                self.assertNotEqual(event["type"], "error", event)
                if event["type"] == "done":
                    self.assertEqual(event["id"], str(turn))
                    break
        self.assertEqual(len(Handler.requests), 2)
        self.assertEqual(Handler.client_ports[0], Handler.client_ports[1])

    def test_persistent_multiplex_no_trace_and_no_keys_on_output(self):
        for identifier in ("one", "two"):
            self.send(request(identifier=identifier))
        done = set()
        while len(done) < 2:
            event = json.loads(self.process.stdout.readline())
            self.assertNotEqual(event["type"], "error", event)
            if event["type"] == "done":
                done.add(event["id"])
        self.process.stdin.close()
        self.process.stdin = None
        output, stderr = self.process.communicate(timeout=5)
        self.assertEqual(self.process.returncode, 0)
        self.assertEqual(stderr, "")
        self.assertNotIn("test-secret", output)
        self.assertEqual([p for p, _, _ in Handler.requests], ["/v1/chat/completions"] * 2)

    def test_cancel_and_eof_abort_inflight_without_done(self):
        Handler.behavior = "slow"
        self.send(request(identifier="cancel-me"))
        self.assertTrue(Handler.received.wait(timeout=5))
        self.send({"op": "cancel", "id": "cancel-me"})
        self.process.stdin.close()
        self.process.stdin = None
        output, stderr = self.process.communicate(timeout=2)
        self.assertNotIn('"done"', output)
        self.assertEqual(stderr, "")
        self.assertEqual(self.process.returncode, 0)

    def test_eof_alone_aborts_inflight_without_done(self):
        Handler.behavior = "slow"
        self.send(request(identifier="eof-me"))
        self.assertTrue(Handler.received.wait(timeout=5))
        self.process.stdin.close()
        self.process.stdin = None
        output, stderr = self.process.communicate(timeout=2)
        self.assertNotIn('"done"', output)
        self.assertEqual(stderr, "")
        self.assertEqual(self.process.returncode, 0)

    def test_cancel_does_not_abort_other_request(self):
        Handler.behavior = "slow"
        self.send(request(identifier="cancel-me"))
        self.assertTrue(Handler.received.wait(timeout=5))
        self.send({"op": "cancel", "id": "cancel-me"})
        Handler.behavior = "normal"
        self.send(request(identifier="keep-me"))
        events = []
        while not events or events[-1]["type"] != "done":
            event = json.loads(self.process.stdout.readline())
            self.assertNotEqual(event["type"], "error", event)
            events.append(event)
        self.assertEqual({event["id"] for event in events}, {"keep-me"})


if __name__ == "__main__":
    try:
        unittest.main()
    finally:
        SERVER.shutdown()
