"""Local, persistent NDJSON bridge. Credentials only arrive over the input pipe."""

import asyncio
import base64
from collections import OrderedDict
from contextvars import ContextVar
import hashlib
from ipaddress import ip_address
import importlib.metadata
import json
import logging
import os
import re
import sys
from functools import cached_property
from urllib.parse import urlsplit
from urllib import request as urllib_request

# Never inherit an opt-in tracing/debug configuration from the launching shell.
for _name in tuple(os.environ):
    if _name.startswith(("LANGSMITH_", "LANGCHAIN_", "OPENAI_", "ANTHROPIC_")):
        os.environ.pop(_name, None)
os.environ["LANGSMITH_TRACING"] = "false"
os.environ["LANGCHAIN_TRACING_V2"] = "false"
logging.disable(logging.CRITICAL)

# Import before announcing ready, so the app can preload the runtime at startup.
import httpx2 as httpx
import anthropic
import openai
from langchain_anthropic import ChatAnthropic
from langchain_core.messages import AIMessage, HumanMessage, SystemMessage
from langchain_core.messages.ai import add_usage, subtract_usage
from langchain_openai import ChatOpenAI
from langsmith import tracing_context
from pydantic import PrivateAttr


class EndpointChatAnthropic(ChatAnthropic):
    """The Anthropic adapter does not expose an async HTTP-client constructor field."""

    _request_client: httpx.AsyncClient = PrivateAttr()

    @cached_property
    def _async_client(self):
        return anthropic.AsyncAnthropic(**self._client_params, http_client=self._request_client)

    def _make_message_chunk_from_anthropic_event(self, event, **kwargs):
        # Observe typed events already parsed by the official SDK. LangChain drops
        # message_stop from its output chunks, but completeness still requires it.
        boundary = _message_boundary.get()
        if boundary is not None:
            if event.type == "message_start":
                boundary.started = event.message.type == "message"
                boundary.start_usage = event.message.usage
            elif event.type == "message_stop":
                boundary.stopped = True
            elif event.type == "message_delta" and boundary.start_usage is not None:
                # Older valid streams put stable input/cache counts only at start.
                # Keep SDK typed values, so LangChain can normalize those counts.
                update = {}
                for field in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "cache_creation"):
                    previous = getattr(boundary.start_usage, field, None)
                    if getattr(event.usage, field, None) is None and previous is not None:
                        update[field] = previous
                if update:
                    event = event.model_copy(update={"usage": event.usage.model_copy(update=update)})
        chunk, block = super()._make_message_chunk_from_anthropic_event(event, **kwargs)
        if boundary is not None and event.type == "message_delta" and chunk is not None and chunk.usage_metadata:
            # Anthropic's message_delta usage is cumulative. Convert it to chunk
            # increments once, before the shared LangChain metadata accumulator.
            cumulative = chunk.usage_metadata
            chunk.usage_metadata = None if boundary.usage_unknown else subtract_usage(cumulative, boundary.previous_usage)
            boundary.previous_usage = cumulative
        return chunk, block


class EngineError(Exception):
    def __init__(self, code):
        self.code = code


def system_proxy_for(endpoint):
    """Use macOS static proxy settings, unaffected by inherited proxy variables."""
    parts = urlsplit(endpoint)
    host = parts.hostname or ""
    if host == "localhost" or host.endswith(".localhost"):
        return None
    try:
        address = ip_address(host)
        if address.is_loopback or (getattr(address, "ipv4_mapped", None) and address.ipv4_mapped.is_loopback):
            return None
    except ValueError:
        pass
    if sys.platform != "darwin":
        return None
    get_proxies = getattr(urllib_request, "getproxies_macosx_sysconf", None)
    bypass = getattr(urllib_request, "proxy_bypass_macosx_sysconf", None)
    if get_proxies is None or bypass is None:
        return None
    if bypass(host):
        return None
    # urllib.getproxies() checks environment first; even a lone no_proxy setting
    # prevents its SystemConfiguration fallback. Read the macOS source directly.
    return get_proxies().get(parts.scheme)


def supports_chat_usage(endpoint):
    # Unverified compatible gateways may reject stream_options; never resend a
    # chargeable request just to acquire statistics.
    return urlsplit(endpoint).hostname in {"api.openai.com", "api.deepseek.com"}


def is_kimi_k26(configuration):
    return (urlsplit(configuration["endpoint"]).hostname in {"api.moonshot.cn", "api.moonshot.ai"}
            and configuration["api"] == "chatCompletions"
            and configuration["model"].strip().lower() == "kimi-k2.6")


def thinking_options(configuration):
    """Use documented model capabilities; unknown gateways retain their defaults."""
    choice = configuration.get("thinking", "automatic")
    if choice not in {"automatic", "off", "low", "medium", "high"}:
        raise EngineError("thinkingUnsupported")
    if is_kimi_k26(configuration):
        # K2.6 fixes temperature by mode. Omit it and use the server default.
        # Thinking and final text share the token budget; avoid truncating at 900.
        if choice == "automatic":
            return {"max_tokens": 16384}
        return {"extra_body": {"thinking": {"type": "disabled" if choice == "off" else "enabled"}},
                **({"max_tokens": 16384} if choice != "off" else {})}
    if choice == "automatic":
        return {}
    api = configuration["api"]
    model = configuration["model"].lower().replace(".", "-")
    def matches(*names):
        return any(model == name or re.fullmatch(re.escape(name) + r"-\d{4}-?\d{2}-?\d{2}", model) for name in names)
    if urlsplit(configuration["endpoint"]).hostname == "api.deepseek.com" and api == "chatCompletions":
        if choice == "off":
            return {"extra_body": {"thinking": {"type": "disabled"}}}
        return {"extra_body": {"thinking": {"type": "enabled"}},
                "reasoning_effort": "low" if choice == "low" else "high",
                "max_tokens": {"low": 4096, "medium": 8192, "high": 16384}[choice]}
    if api == "anthropicMessages":
        always_on = matches("claude-opus-5-5", "claude-fable-5", "claude-fable-5-1", "claude-mythos-5", "claude-mythos-5-1", "claude-mythos-preview")
        adaptive = always_on or matches("claude-sonnet-5-5", "claude-sonnet-5", "claude-opus-5", "claude-sonnet-4-6", "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8")
        if adaptive:
            effort = "low" if choice == "off" else choice
            mode = "adaptive"
            if choice == "off" and not always_on:
                mode = "between_tools" if matches("claude-sonnet-5-5") else "disabled"
            return {"thinking": {"type": mode}, "output_config": {"effort": effort},
                    "max_tokens": 900 if mode != "adaptive" else {"low": 4096, "medium": 8192, "high": 16384}[effort]}
        if matches("claude-sonnet-4-5", "claude-opus-4-5", "claude-haiku-4-5"):
            if choice == "off":
                return {"thinking": {"type": "disabled"}}
            budget = {"low": 1024, "medium": 2048, "high": 4096}[choice]
            return {"thinking": {"type": "enabled", "budget_tokens": budget}, "max_tokens": budget + 900}
    else:
        none = matches("gpt-5-1", "gpt-5-2", "gpt-5-4", "gpt-5-5", "gpt-6-sol", "gpt-6-luna")
        low = matches("gpt-6-astra", "gpt-6-1-sol")
        minimal = matches("gpt-5", "gpt-5-mini", "gpt-5-nano")
        if none or low or minimal:
            effort = choice if choice != "off" else ("none" if none else "low" if low else "minimal")
            result = {"reasoning": {"effort": effort}} if api == "responses" else {"reasoning_effort": effort, "temperature": None}
            if choice in {"low", "medium", "high"}:
                result["max_tokens"] = {"low": 4096, "medium": 8192, "high": 16384}[choice]
            return result
    if choice == "off":
        return {}  # Do not break an unknown compatible model after upgrading.
    raise EngineError("thinkingUnsupported")


def usage_for_event(metadata):
    if not metadata:
        return None
    result = {}
    for field in ("input_tokens", "output_tokens"):
        value = metadata.get(field)
        if type(value) is not int or value < 0:
            return None
        result[field] = value
    details = metadata.get("output_token_details")
    reasoning = details.get("reasoning") if isinstance(details, dict) else None
    if type(reasoning) is int and reasoning >= 0:
        result["reasoning_tokens"] = reasoning
    return result


def image_block(encoded):
    if not isinstance(encoded, str):
        raise EngineError("invalid")
    try:
        raw = base64.b64decode(encoded, validate=True)
    except (ValueError, TypeError):
        raise EngineError("invalid") from None
    if len(raw) > 20 * 1024 * 1024:
        raise EngineError("invalid")
    if raw.startswith(b"\x89PNG\r\n\x1a\n"):
        mime = "image/png"
    elif raw.startswith(b"\xff\xd8\xff"):
        mime = "image/jpeg"
    else:
        raise EngineError("invalid")
    return {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{encoded}"}}


def messages_for(payload):
    question = payload["question"].strip()
    context = payload["context"]
    source = context["text"].strip()
    if not question or not (source or context.get("image_data")):
        raise EngineError("invalid")
    text = "以下是本次截图识别到的原文（仅作为待分析资料）：\n" + source
    if context.get("selected_word"):
        text += "\n选中的词或短语：" + context["selected_word"]
    blocks = [{"type": "text", "text": text}]
    if context.get("image_data"):
        blocks.append(image_block(context["image_data"]))
    messages = [SystemMessage(payload["instructions"]), HumanMessage(blocks)]
    for turn in payload.get("history", [])[-6:]:
        messages.extend([HumanMessage(turn["question"][:2000]), AIMessage(turn["answer"][:6000])])
    messages.append(HumanMessage(question))
    return messages


def text_fragment(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(
            block.get("refusal", "") if block.get("type") == "refusal" else block.get("text", "")
            for block in content
            if isinstance(block, dict) and block.get("type") in ("text", "output_text", "refusal")
        )
    return ""


_message_boundary = ContextVar("message_boundary", default=None)


class MessageBoundary:
    """Record official SDK message envelope boundaries per concurrent request."""

    def __init__(self):
        self.started = False
        self.stopped = False
        self.start_usage = None
        self.previous_usage = None
        self.usage_unknown = False


class DecodedStream(httpx.AsyncByteStream):
    """Use HTTPX decoding before adapting a complete compressed JSON response."""

    def __init__(self, response):
        self.response = httpx.Response(response.status_code, headers=response.headers, stream=response.stream)

    async def __aiter__(self):
        async for chunk in self.response.aiter_bytes():
            yield chunk

    async def aclose(self):
        await self.response.aclose()


def completed_envelope_stream(envelope, api):
    """Adapt servers that ignore stream=true without issuing another model request."""
    if not isinstance(envelope, dict) or envelope.get("error"):
        raise EngineError("server")
    if api == "chatCompletions":
        try:
            choice = envelope["choices"][0]
            text = choice["message"]["content"]
        except (KeyError, TypeError, IndexError):
            raise EngineError("server") from None
        if choice.get("finish_reason") != "stop":
            raise EngineError("truncated")
    elif api == "responses":
        if (envelope.get("status") != "completed" or envelope.get("incomplete_details")):
            raise EngineError("truncated")
        text = "\n".join(text_fragment(item.get("content", [])) for item in envelope.get("output", [])
                         if item.get("type") == "message")
    else:
        if envelope.get("type") != "message":
            raise EngineError("server")
        if envelope.get("stop_reason") not in ("end_turn", "stop_sequence"):
            raise EngineError("truncated")
        text = text_fragment(envelope.get("content", []))
    if not isinstance(text, str):
        raise EngineError("server")
    if not text.strip():
        raise EngineError("empty")

    def frame(value):
        event = ("event: " + value["type"] + "\n").encode() if api == "anthropicMessages" else b""
        return event + b"data: " + json.dumps(value, ensure_ascii=False).encode() + b"\n\n"

    if api == "chatCompletions":
        wire = frame({"id": envelope.get("id", "chat-local"), "object": "chat.completion.chunk",
                      "created": envelope.get("created", 0), "model": envelope.get("model", ""),
                      "choices": [{"index": 0, "delta": {"content": text}, "finish_reason": "stop"}]})
        if envelope.get("usage"):
            wire += frame({"id": envelope.get("id", "chat-local"), "object": "chat.completion.chunk",
                           "created": envelope.get("created", 0), "model": envelope.get("model", ""),
                           "choices": [], "usage": envelope["usage"]})
        return wire + b"data: [DONE]\n\n"
    if api == "responses":
        item = {"id": "message-local", "type": "message", "role": "assistant", "content": [], "status": "in_progress"}
        response = {"id": "response-local", "object": "response", "created_at": 0,
                    "model": "", "output": [], **envelope}
        return (frame({"type": "response.output_item.added", "output_index": 0, "item": item, "sequence_number": 0})
                + frame({"type": "response.output_text.delta", "item_id": item["id"], "output_index": 0,
                         "content_index": 0, "delta": text, "sequence_number": 1, "logprobs": []})
                + frame({"type": "response.completed", "response": response, "sequence_number": 2}))
    provider_usage = envelope.get("usage")
    provider_usage = provider_usage if isinstance(provider_usage, dict) else {}
    message = {"id": "message-local", "role": "assistant", "model": "", "usage": {"input_tokens": 0, "output_tokens": 0},
               **envelope, "content": [], "stop_reason": None, "stop_sequence": None}
    message["usage"] = provider_usage or {"input_tokens": 0, "output_tokens": 0}
    if boundary := _message_boundary.get():
        boundary.usage_unknown = any(type(provider_usage.get(field)) is not int for field in ("input_tokens", "output_tokens"))
    return (frame({"type": "message_start", "message": message})
            + frame({"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
            + frame({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}})
            + frame({"type": "content_block_stop", "index": 0})
            + frame({"type": "message_delta", "delta": {"stop_reason": envelope["stop_reason"], "stop_sequence": None},
                     "usage": provider_usage or {"output_tokens": 0}})
            + frame({"type": "message_stop"}))


class JSONFallbackStream(httpx.AsyncByteStream):
    def __init__(self, stream, api):
        self.stream, self.api = stream, api

    async def __aiter__(self):
        data = bytearray()
        async for chunk in self.stream:
            data.extend(chunk)
            if len(data) > 8 * 1024 * 1024:
                raise EngineError("server")
        try:
            envelope = json.loads(data)
        except ValueError:
            raise EngineError("server") from None
        yield completed_envelope_stream(envelope, self.api)

    async def aclose(self):
        await self.stream.aclose()


class ModelPool:
    """Four in-memory profiles reuse SDK clients and keep-alive connections."""

    def __init__(self, limit=4):
        self.entries = OrderedDict()
        self.limit = limit
        self.lock = asyncio.Lock()

    async def acquire(self, configuration):
        async with self.lock:
            return await self._acquire(configuration)

    async def _acquire(self, configuration):
        endpoint, api = configuration["endpoint"], configuration["api"]
        direct = configuration.get("direct_connection", False)
        if type(direct) is not bool:
            raise EngineError("invalid")
        proxy = None if direct else system_proxy_for(endpoint)
        controls = thinking_options(configuration)
        key = (api, endpoint, configuration["model"], configuration.get("thinking", "automatic"),
               hashlib.sha256(configuration["api_key"].encode()).digest(), proxy, direct)
        if key in self.entries:
            entry = self.entries.pop(key)
            self.entries[key] = entry
            entry["users"] += 1
            return key, entry["model"]
        if len(self.entries) >= self.limit:
            idle = next((key for key, value in self.entries.items() if not value["users"]), None)
            if idle is None:
                raise EngineError("invalid")
            await self.close_entry(self.entries.pop(idle))

        async def exact_endpoint(request):
            # Keep the app's full route exact, including custom Messages prefixes.
            request.url = httpx.URL(endpoint)

        async def response_boundary(response):
            if response.status_code == 200 and "application/json" in response.headers.get("content-type", ""):
                if response.headers.get("content-encoding"):
                    response.stream = DecodedStream(response)
                    del response.headers["content-encoding"]
                    response.headers.pop("content-length", None)
                response.stream = JSONFallbackStream(response.stream, api)
                response.headers["content-type"] = "text/event-stream"

        # A user normally takes longer than the SDK's default five seconds to
        # type a follow-up. Preserve idle sockets across that pause, while
        # retaining the existing connection caps and proxy-specific pools.
        limits = httpx.Limits(max_connections=100, max_keepalive_connections=20, keepalive_expiry=120)
        client = httpx.AsyncClient(timeout=90, follow_redirects=False, trust_env=False, proxy=proxy, limits=limits,
                                  event_hooks={"request": [exact_endpoint], "response": [response_boundary]})
        try:
            common = dict(model=configuration["model"], api_key=configuration["api_key"] or "local",
                          timeout=90, max_retries=0)
            if api == "anthropicMessages":
                base = endpoint.removesuffix("/v1/messages").removesuffix("/messages")
                model = EndpointChatAnthropic(**common, base_url=base, **({"max_tokens": 900} | controls))
                model._request_client = client
            else:
                suffix = "/responses" if api == "responses" else "/chat/completions"
                options = dict(base_url=endpoint.removesuffix(suffix), http_async_client=client,
                               use_responses_api=api == "responses",
                               stream_usage=api == "chatCompletions" and supports_chat_usage(endpoint))
                if api == "responses":
                    options.update(max_tokens=4096, store=False, temperature=None)
                else:
                    options.update(max_tokens=900, temperature=None if is_kimi_k26(configuration) else 0.2)
                options.update(controls)
                if is_kimi_k26(configuration):
                    # The OpenAI adapter renames max_tokens to max_completion_tokens.
                    # Kimi documents max_tokens; send that exact field through extra_body.
                    options["extra_body"] = {**options.get("extra_body", {}), "max_tokens": options.pop("max_tokens")}
                model = ChatOpenAI(**common, **options)
        except BaseException:
            await client.aclose()
            raise
        self.entries[key] = {"model": model, "client": client, "users": 1}
        return key, model

    def release(self, key):
        self.entries[key]["users"] -= 1

    @staticmethod
    async def close_entry(entry):
        await entry["client"].aclose()
        sync_root = getattr(entry["model"], "root_client", None)
        if sync_root is not None:
            sync_root.close()

    async def close(self):
        for entry in self.entries.values():
            await self.close_entry(entry)
        self.entries.clear()


async def stream_answer(payload, emit, pool=None):
    try:
        configuration = payload["configuration"]
        endpoint = configuration["endpoint"]
        parts = urlsplit(endpoint)
        api = configuration["api"]
        if (parts.scheme not in ("http", "https") or not parts.hostname
                or parts.username or parts.password or parts.query or parts.fragment
                or api not in ("chatCompletions", "responses", "anthropicMessages")
                or not configuration["model"].strip()):
            raise EngineError("invalid")
        messages = messages_for(payload)
    except (KeyError, TypeError, ValueError, AttributeError):
        raise EngineError("invalid") from None

    owns_pool = pool is None
    pool = pool or ModelPool()
    key = None
    boundary = MessageBoundary()
    token = _message_boundary.set(boundary)
    try:
        key, model = await pool.acquire(configuration)
        output = ""
        usage = None
        terminal = False
        incomplete = False
        with tracing_context(enabled=False):
            async with asyncio.timeout(90):
                async for chunk in model.astream(messages, config={"callbacks": []}):
                    if chunk.usage_metadata is not None:
                        usage = add_usage(usage, chunk.usage_metadata)
                    metadata = chunk.response_metadata
                    reason = metadata.get("finish_reason") or metadata.get("stop_reason")
                    status = metadata.get("status")
                    if reason:
                        terminal = reason in ("stop", "end_turn", "stop_sequence")
                        incomplete = incomplete or not terminal
                    if status in ("completed", "incomplete", "failed", "cancelled"):
                        terminal = status == "completed"
                        incomplete = incomplete or not terminal
                    fragment = text_fragment(chunk.content)
                    if fragment:
                        output += fragment
                        emit({"id": payload["id"], "type": "delta", "text": fragment})
        if incomplete or not terminal:
            raise EngineError("truncated")
        if api == "anthropicMessages" and not (boundary.started and boundary.stopped):
            raise EngineError("truncated")
        if not output.strip():
            raise EngineError("empty")
        event = {"id": payload["id"], "type": "done", "text": output.strip()}
        if counts := usage_for_event(usage):
            event["usage"] = counts
        emit(event)
    finally:
        _message_boundary.reset(token)
        if key is not None:
            pool.release(key)
        if owns_pool:
            await pool.close()


def write_event(event):
    sys.stdout.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


async def run_request(payload, emit, pool=None):
    identifier = payload.get("id")
    try:
        await stream_answer(payload, emit, pool)
    except asyncio.CancelledError:
        # The native caller owns cancellation state; never finish a cancelled answer.
        raise
    except Exception as error:
        code = "response"
        if isinstance(error, EngineError):
            code = "response" if error.code == "server" else error.code
        elif isinstance(error, (TimeoutError, httpx.TimeoutException, openai.APITimeoutError, anthropic.APITimeoutError)):
            code = "timeout"
        elif isinstance(error, (httpx.TransportError, openai.APIConnectionError, anthropic.APIConnectionError)):
            code = "connection"
        elif isinstance(error, (KeyError, TypeError)):
            code = "invalid"
        status = getattr(error, "status_code", None)
        if type(status) is int:
            code = "server"
        event = {"id": identifier, "type": "error", "code": code}
        if type(status) is int:
            event["status"] = status
        emit(event)


async def main():
    reader = asyncio.StreamReader(limit=32 * 1024 * 1024)
    protocol = asyncio.StreamReaderProtocol(reader)
    await asyncio.get_running_loop().connect_read_pipe(lambda: protocol, sys.stdin.buffer)
    write_event({"type": "ready", "protocol": 1,
                 "langchain_version": importlib.metadata.version("langchain")})
    tasks = {}
    pool = ModelPool()
    try:
        while line := await reader.readline():
            try:
                payload = json.loads(line)
                if not isinstance(payload, dict):
                    raise EngineError("invalid")
                identifier = payload["id"]
                if not isinstance(identifier, str) or not identifier or len(identifier) > 128:
                    raise EngineError("invalid")
                if payload["op"] == "cancel":
                    if task := tasks.get(identifier):
                        task.cancel()
                elif payload["op"] == "answer" and identifier not in tasks and len(tasks) < 8:
                    task = asyncio.create_task(run_request(payload, write_event, pool))
                    tasks[identifier] = task
                    task.add_done_callback(lambda _, key=identifier: tasks.pop(key, None))
                else:
                    write_event({"id": identifier, "type": "error", "code": "invalid"})
            except (ValueError, KeyError, TypeError, EngineError):
                write_event({"type": "error", "code": "invalid"})
    finally:
        pending = list(tasks.values())
        for task in pending:
            task.cancel()
        await asyncio.gather(*pending, return_exceptions=True)
        await pool.close()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except (BrokenPipeError, KeyboardInterrupt):
        pass
