"""One result submission, including bounded graph counting; no second synthesis."""
import json
from time import perf_counter
from contextlib import aclosing

from langchain_core.messages.ai import add_usage
from math_solution_contract import MAX_BYTES, TOOL_NAME, SolutionContractError, normalize_arguments, tool_schema
from math_diagram_tools import GENERAL_TOOL_NAME, normalize_tool_arguments, tool_schemas


def _arguments(raw, allowed_names=None, *, responses=False, anthropic=False):
    allowed_names = allowed_names or {TOOL_NAME}
    if raw is None or getattr(raw, "invalid_tool_calls", None):
        raise SolutionContractError("submission_tool")
    if anthropic and isinstance(raw.content, list):
        if any(not isinstance(block, dict) or block.get("type") not in
               ("tool_use", "input_json_delta", "thinking", "redacted_thinking") for block in raw.content):
            raise SolutionContractError("submission_tool")
    elif responses and isinstance(raw.content, list):
        if any(not isinstance(block, dict) or block.get("type") not in ("function_call", "reasoning") for block in raw.content):
            raise SolutionContractError("submission_tool")
    elif raw.content:
        raise SolutionContractError("submission_tool")
    # Require original argument text: SDK-decoded dictionaries can conceal
    # duplicate keys. Chat chunks preserve the wire strings during aggregation.
    calls = raw.additional_kwargs.get("tool_calls")
    if calls is not None:
        if not isinstance(calls, list) or len(calls) != 1:
            raise SolutionContractError("submission_tool")
        call = calls[0]
        if not isinstance(call, dict) or call.get("type") != "function":
            raise SolutionContractError("submission_tool")
        function = call.get("function")
        if not isinstance(function, dict) or function.get("name") not in allowed_names:
            raise SolutionContractError("submission_tool")
        arguments = function.get("arguments")
        name = function["name"]
    else:
        calls = getattr(raw, "tool_call_chunks", [])
        if len(calls) != 1 or calls[0].get("name") not in allowed_names:
            raise SolutionContractError("submission_tool")
        arguments = calls[0].get("args")
        name = calls[0]["name"]
    parsed = getattr(raw, "tool_calls", [])
    if len(parsed) != 1 or parsed[0].get("name") != name:
        raise SolutionContractError("submission_tool")
    return name, arguments


def _chunk_size(chunk, *, responses=False, anthropic=False):
    if (responses or anthropic) and isinstance(chunk.content, list):
        # Function arguments also appear in tool_call_chunks. Count their wire
        # text once, not both SDK representations, while bounding reasoning too.
        size = sum(len(json.dumps(block, ensure_ascii=False).encode("utf-8")) for block in chunk.content
                   if isinstance(block, dict) and block.get("type") not in
                   ("function_call", "tool_use", "input_json_delta"))
    else:
        size = len(chunk.content.encode("utf-8")) if isinstance(chunk.content, str) else MAX_BYTES + 1
    calls = chunk.additional_kwargs.get("tool_calls")
    chunks = calls is None
    if chunks:
        calls = getattr(chunk, "tool_call_chunks", [])
    if not isinstance(calls, list):
        raise SolutionContractError("submission_tool")
    for call in calls:
        function = call if chunks else (call.get("function", {}) if isinstance(call, dict) else {})
        for value in (call.get("id") if isinstance(call, dict) else None,
                      function.get("name"), function.get("args" if chunks else "arguments")):
            if value is not None:
                if not isinstance(value, str):
                    raise SolutionContractError("submission_tool")
                size += len(value.encode("utf-8"))
    return size


async def submit_once(model, messages, *, strict=False, renderer_tools=False, explicit_non_strict=False, responses=False, anthropic=False, timings=None, observation=None, diagram_scope="full"):
    # Named choice requires a single result tool, without an agent loop. Strict
    # decoding is requested only through an explicitly selected Beta endpoint.
    if diagram_scope not in ("full", "native_only") or diagram_scope != "full" and not renderer_tools:
        raise ValueError("invalid diagram_scope")
    started = perf_counter()
    schemas = tool_schemas(strict=strict, diagram_scope=diagram_scope) if renderer_tools else [tool_schema(strict=strict)]
    if (explicit_non_strict or responses) and not strict:
        # Moonshot documents omitted strict as true. Explicitly opt out of its
        # provider-specific schema decoder for the ordinary portable protocol;
        # retain the complete local validation and native arithmetic checks.
        for schema in schemas:
            schema["function"]["strict"] = False
    choice = "required" if renderer_tools else {"type": "function", "function": {"name": TOOL_NAME}}
    # Sonnet 5.5 rejects forced tool choice even with up-front thinking off.
    # Accept exactly one validated tool locally; never retry a plain-text reply.
    if anthropic:
        choice = "auto"
    if observation is not None:
        observation["phase"] = "tool_binding"
    bound = model.bind_tools(schemas, tool_choice=choice,
                             **({"parallel_tool_calls": False} if responses or anthropic else {}))
    bound_at = perf_counter()
    first_chunk_at = first_arguments_at = None
    raw, size, usage = None, 0, None
    terminal, incomplete = False, False
    termination = "missing_terminal"
    if observation is not None:
        observation["phase"] = "stream"
    try:
        async with aclosing(bound.astream(messages, config={"callbacks": []})) as stream:
            async for chunk in stream:
                now = perf_counter()
                if first_chunk_at is None:
                    first_chunk_at = now
                if first_arguments_at is None and any(item.get("args") for item in chunk.tool_call_chunks):
                    first_arguments_at = now
                size += _chunk_size(chunk, responses=responses, anthropic=anthropic)
                if size > MAX_BYTES:
                    raise SolutionContractError("submission_size")
                reason = chunk.response_metadata.get("status" if responses else "stop_reason" if anthropic else "finish_reason")
                if reason:
                    # Retain only local categories, never arbitrary provider strings.
                    category = {"length": "token_limit", "max_tokens": "token_limit",
                                "content_filter": "content_filter", "incomplete": "incomplete",
                                "failed": "provider_failure"}.get(reason, "other_terminal")
                    if not incomplete:
                        termination = category
                    terminal = reason == "completed" if responses else reason == "tool_use" if anthropic else reason in ("tool_calls", "stop")
                    incomplete = incomplete or not terminal
                if responses and (chunk.response_metadata.get("incomplete_details") or chunk.response_metadata.get("error")):
                    incomplete = True
                    termination = "incomplete"
                if chunk.usage_metadata is not None:
                    usage = add_usage(usage, chunk.usage_metadata)
                raw = chunk if raw is None else raw + chunk
    finally:
        stream_ended_at = perf_counter()
        if timings is not None:
            timings.update(tool_binding=bound_at-started, stream_total=stream_ended_at-bound_at)
            if first_chunk_at is not None:
                timings["first_sdk_chunk"] = first_chunk_at-bound_at
            if first_arguments_at is not None:
                timings["first_tool_arguments"] = first_arguments_at-bound_at
                timings["arguments_to_stream_end"] = stream_ended_at-first_arguments_at
    if observation is not None:
        observation["phase"] = "submission_validation"
    try:
        if incomplete or not terminal:
            error = SolutionContractError("submission_truncated")
            error.stream_termination = termination
            raise error
        # No SDK structured-output parser, retries, endpoint switching or text-mode
        # fallback. Native code receives its existing portable six-field envelope.
        name, arguments = _arguments(raw, {s["function"]["name"] for s in schemas}, responses=responses, anthropic=anthropic)
        output = (normalize_tool_arguments(name, arguments, strict=strict, preserve_general_answer=True, diagram_scope=diagram_scope) if renderer_tools
                  else normalize_arguments(arguments, strict=strict))
        if renderer_tools and name == GENERAL_TOOL_NAME and not output["diagrams"] and "diagram_submission_failure" not in output:
            # This is the already validated tool outcome, not a phrase inferred from
            # answer prose. V3 alone carries it to the native UI; old protocols retain
            # their exact six-field envelope and missing-picture diagnostics.
            outcome = json.loads(arguments)["diagram_outcome"]
            if outcome["status"] in ("unreadable_or_insufficient", "no_helpful_diagram", "user_requested_text_only"):
                output["diagram_omission"] = {"status": outcome["status"], "reason": outcome["reason"]}
        encoded = json.dumps(output, ensure_ascii=False, separators=(",", ":"))
    finally:
        if timings is not None:
            timings["submission_validation"] = perf_counter()-stream_ended_at
    return encoded, usage
