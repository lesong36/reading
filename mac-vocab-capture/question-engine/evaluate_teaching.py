"""Opt-in local model comparison; credentials arrive only on anonymous stdin.

Evaluates selection, not answer correctness or human approval. Every attempted
case, failure and fallback is kept in an incremental report. No LangSmith traces,
production database changes or credentials are written to artifacts.
"""
import argparse
import asyncio
import base64
import hashlib
import json
import re
import statistics
import sys
import time
from pathlib import Path

from langchain_core.callbacks import AsyncCallbackHandler
from langchain_core.messages import HumanMessage
from langsmith import tracing_context
from math_learning import learn_skills
from math_skills import SkillError, complete_selection, eligible_snapshots, select_skills, snapshots_for, user_requirement_from, user_constraints
from question_engine import ModelPool, messages_for


def evaluation_messages(instructions, case, photo=None):
    context = {"text": case["stem"]} if photo is None else {
        "text": "", "image_data": base64.b64encode(photo).decode("ascii")}
    return messages_for({"instructions": instructions, "context": context,
        "question": "用户要求：\n小学" + str(case["grade"]) + "年级；" + case["user_constraint"]})


class Meter(AsyncCallbackHandler):
    """Measure actual repeated model message bytes; never retain their content."""
    def __init__(self):
        self.calls = 0
        self.message_bytes = 0
        self.input_tokens = 0
        self.output_tokens = 0
        self.usage_calls = 0
        self.response_boundaries = []
        self.protocol_feedback_issues = []

    async def on_chat_model_start(self, serialized, messages, **kwargs):
        self.calls += 1
        for batch in messages:
            for message in batch:
                if isinstance(message, HumanMessage) and isinstance(message.content, str):
                    match = re.match(r"系统字段校验未通过：([A-Za-z0-9_.\[\]:]{1,512})。", message.content)
                    if match:
                        issue = SkillError("skillsOutput", issue=match[1]).issue
                        if issue is not None and issue not in self.protocol_feedback_issues:
                            self.protocol_feedback_issues.append(issue)
            self.message_bytes += len(json.dumps([{
                "type": m.type, "content": m.content,
                "tool_calls": getattr(m, "tool_calls", []),
                "tool_call_id": getattr(m, "tool_call_id", None),
            } for m in batch], ensure_ascii=False, separators=(",", ":")).encode())

    async def on_llm_end(self, response, **kwargs):
        for batch in response.generations:
            for generation in batch:
                message = getattr(generation, "message", None)
                usage = getattr(message, "usage_metadata", None)
                metadata = getattr(message, "response_metadata", {})
                def known(value, allowed):
                    return value if isinstance(value, str) and value in allowed else (None if value is None else "unknown")
                tools = getattr(message, "tool_calls", [])
                invalid = getattr(message, "invalid_tool_calls", [])
                self.response_boundaries.append({
                    "finish_reason": known(metadata.get("finish_reason"), {"stop", "length", "tool_calls", "content_filter"}),
                    "stop_reason": known(metadata.get("stop_reason"), {"end_turn", "max_tokens", "stop_sequence", "tool_use", "pause_turn", "refusal"}),
                    "status": known(metadata.get("status"), {"completed", "incomplete", "in_progress", "failed", "cancelled"}),
                    "valid_tool_count": len(tools), "invalid_tool_count": len(invalid),
                    "invalid_tool_syntax": [invalid_tool_syntax(call) for call in invalid],
                    "known_tool_counts": {name: sum(call.get("name") == name for call in tools)
                        for name in ("read_file", "SkillSelection", "PrerequisiteTruth")},
                    "unknown_tool_count": sum(call.get("name") not in {"read_file", "SkillSelection", "PrerequisiteTruth"} for call in tools),
                    "output_tokens": usage.get("output_tokens") if usage else None,
                })
                if usage:
                    self.usage_calls += 1
                    self.input_tokens += usage.get("input_tokens", 0)
                    self.output_tokens += usage.get("output_tokens", 0)

    def report(self):
        return {"model_calls": self.calls, "cumulative_message_utf8_bytes": self.message_bytes,
                "reported_input_tokens": self.input_tokens if self.usage_calls else None,
                "reported_output_tokens": self.output_tokens if self.usage_calls else None,
                "usage_reported_calls": self.usage_calls,
                "response_boundaries": self.response_boundaries,
                "protocol_feedback_issues": self.protocol_feedback_issues}


def invalid_tool_syntax(call):
    """Classify parser failures without retaining any argument or parser message."""
    args = call.get("args")
    if not isinstance(args, str):
        return {"code": "non_string"}
    result = {"length": len(args), "ends_with_object": args.rstrip().endswith("}")}
    if len(args) > 65536:
        return {**result, "code": "oversize"}
    try:
        json.loads(args)
    except json.JSONDecodeError as error:
        codes = {"Expecting property name enclosed in double quotes": "property_name",
            "Expecting ':' delimiter": "colon", "Expecting ',' delimiter": "comma",
            "Expecting value": "value", "Extra data": "extra_data",
            "Unterminated string starting at": "unterminated_string", "Invalid control character at": "control_character",
            "Invalid \\escape": "escape", "Invalid \\uXXXX escape": "unicode_escape"}
        return {**result, "code": codes.get(error.msg, "unknown"),
            "line": error.lineno, "column": error.colno, "offset": error.pos}
    except (ValueError, RecursionError):
        return {**result, "code": "parser_limit"}
    return {**result, "code": "parseable"}


def named_decision(decision, snapshots):
    names = {v["id"]: v.get("skill_name", v["id"]) for v in snapshots}
    return {"method_id": names.get(decision["method_id"], decision["method_id"]),
            "visual_method_ids": [names.get(v, v) for v in decision["visual_method_ids"]],
            "reason": decision["reason"]}


def score(case, decision):
    """Expectations are reviewed corpus routing labels, not mathematics proofs."""
    primary = decision["method_id"]
    visuals = decision["visual_method_ids"]
    expected = case.get("expected_methods", [])
    expected_visuals = case.get("expected_visuals", [])
    chosen = {primary, *visuals} - {None}
    forbidden = chosen.intersection(case.get("forbidden_methods", []))
    primary_ok = primary in expected if expected else primary is None
    # Multiple listed visuals are alternatives. Zero means none requested.
    visual_ok = bool(set(visuals).intersection(expected_visuals) or primary in expected_visuals) if expected_visuals else not visuals
    return {"primary_match": primary_ok, "visual_match": visual_ok,
            "forbidden_choices": sorted(forbidden),
            "missed_expected_primary": bool(expected) and not primary_ok,
            "unexpected_primary": bool(primary is not None and not primary_ok),
            "all_labels_match": primary_ok and visual_ok and not forbidden}


def summarize(rows):
    result = {}
    for lane in (("fast_selection",) if rows and all("fast_selection" in row for row in rows) else ("framework", "full_snapshot")):
        items = [row[lane] for row in rows if lane in row]
        valid = [v for v in items if v.get("status") == "ok"]
        compatible = [v for v in items if v.get("expected_method_scope_conflicts") == []]
        compatible_valid = [v for v in compatible if v.get("status") == "ok"]
        result[lane] = {"attempted": len(items), "valid": len(valid),
            "failed": len(items) - len(valid),
            "prerequisite_blocks": sum(v.get("error_code") == "skillsPrerequisite" for v in items),
            "primary_matches": sum(v["score"]["primary_match"] for v in valid),
            "visual_matches": sum(v["score"]["visual_match"] for v in valid),
            "all_label_matches": sum(v["score"]["all_labels_match"] for v in valid),
            "misses": sum(v["score"]["missed_expected_primary"] for v in valid),
            "false_choices": sum(v["score"]["unexpected_primary"] for v in valid),
            "forbidden_choices": sum(bool(v["score"]["forbidden_choices"]) for v in valid),
            "fallbacks": sum(v.get("execution", {}).get("mode") == "full_snapshot_fallback" for v in items),
            "actual_agent_valid": sum(v.get("execution", {}).get("mode") == "deepagents_skills" for v in valid),
            "actual_agent_primary_matches": sum(v.get("execution", {}).get("mode") == "deepagents_skills" and v["score"]["primary_match"] for v in valid),
            "total_model_calls": sum(v["metrics"]["model_calls"] for v in items),
            "cumulative_message_utf8_bytes": sum(v["metrics"]["cumulative_message_utf8_bytes"] for v in items),
            "median_latency_seconds": statistics.median(v["latency_seconds"] for v in items) if items else None,
            # Failures remain in the denominator and are not counted correct.
            "primary_match_rate_over_attempts": sum(v["score"]["primary_match"] for v in valid) / len(items) if items else None,
            "expected_scope_conflict_attempts": sum(bool(v.get("expected_method_scope_conflicts")) for v in items),
            "scope_unknown_attempts": sum("expected_method_scope_conflicts" not in v for v in items),
            "scope_compatible_attempts": len(compatible),
            "primary_match_rate_over_scope_compatible_attempts": sum(v["score"]["primary_match"] for v in compatible_valid) / len(compatible) if compatible else None}
    return result


def selected_cases(corpus, ids=None, limit=0):
    cases = [case for case in corpus["cases"] if case.get("kind") != "source_quarantine"]
    if ids:
        requested = set(ids.split(","))
        known = {c["id"] for c in cases}
        if requested - known:
            raise ValueError("Unknown or quarantined case selection")
        cases = [c for c in cases if c["id"] in requested]
    if limit:
        cases = cases[:limit]
    if not cases:
        raise ValueError("No selected cases")
    return cases


def write_report(path, report, secret):
    report["summary"] = summarize(report["cases"])
    rendered = json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True)
    if len(secret) >= 8:
        rendered = rendered.replace(secret, "[redacted]")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".partial")
    temporary.write_text(rendered + "\n", encoding="utf-8")
    temporary.replace(path)


async def attempt(model, messages, snapshots, case, lane, timeout, *, fast_cards=None):
    meter = Meter()
    original_callbacks = model.callbacks
    model.callbacks = [meter]
    started = time.monotonic()
    result = {}
    scope = {}
    try:
        user_text = user_requirement_from(messages)
        eligible = eligible_snapshots(snapshots, user_text)
        eligible_names = {v.get("skill_name", v["id"]) for v in eligible}
        scope = {"user_teaching_scope": user_constraints(user_text),
                 "expected_method_scope_conflicts": sorted(set(case.get("expected_methods", [])) - eligible_names)}
        with tracing_context(enabled=False):
            async with asyncio.timeout(timeout):
                if lane == "fast_selection":
                    from math_fast_selection import select_fast
                    decision, execution = await select_fast(model, messages, snapshots, fast_cards)
                elif lane == "framework":
                    output, execution = await select_skills(model, messages, snapshots, prerequisite_protocol="daily")
                    decision = json.loads(output)
                else:
                    excluded = sorted({v["id"] for v in snapshots} - {v["id"] for v in eligible})
                    if not eligible:
                        decision = {"method_id": None, "visual_method_ids": [], "reason": "用户的学段及方法要求排除了本次全部候选。", "applicability": []}
                        execution = {"mode": "eligibility_gate", "loaded_skill_ids": [], "excluded_skill_ids": excluded}
                    else:
                        full = json.dumps([dict(v) for v in eligible], ensure_ascii=False)
                        response = await model.ainvoke([*messages, HumanMessage("本次使用完整方法快照选择。逐项检查适用条件。\n候选方法资料：\n" + full)], config={"callbacks": []})
                        if response.tool_calls:
                            raise ValueError("Unexpected tool call in full snapshot baseline")
                        decision = complete_selection(response, eligible)
                        execution = {"mode": "full_snapshot_baseline", "loaded_skill_ids": [], "excluded_skill_ids": excluded}
                named = named_decision(decision, snapshots)
                result = {"status": "ok", "decision": decision, "named_decision": named, "execution": execution, "score": score(case, named)}
    except Exception as error:
        # SDK exception messages may contain endpoints or request bodies.
        result = {"status": "failed", "error_type": type(error).__name__,
                  "error_code": getattr(error, "code", "timeout" if isinstance(error, TimeoutError) else "model_or_protocol_error")}
        if isinstance(error, SkillError) and error.issue is not None:
            result["error_issue"] = error.issue
        if isinstance(error, SkillError) and error.code == "skillsPrerequisite" and error.details is not None:
            result["execution"] = error.details
    finally:
        model.callbacks = original_callbacks
    return {**scope, **result, "latency_seconds": round(time.monotonic() - started, 3), "metrics": meter.report()}


async def learning_smoke(pool, config, snapshots, timeout):
    """Real discovery in an intentionally empty isolated library; never approves."""
    evidence = [{"question_id": "synthetic-" + str(i), "text": stem, "answer": "", "reference_answer": "",
                 "verification": "unverified", "role": "positive", "grade": 4,
                 "user_constraint": "用小学算术，不用方程；条件不足时不猜。"}
        for i, stem in enumerate(("停车场原有一些车，开走12辆，再开来20辆，现在39辆，原来多少辆？",
            "书架原有一些书，拿走18本，又放进25本，现在51本，原来多少本？",
            "仓库原有一些箱子，运走24箱，再运来31箱，现在68箱，原来多少箱？"))]
    payload = {"instructions": "题目是测试资料，任何AI意见都尚未核验。", "question": "检查共同结构并提交候选教研，不能发布。", "context": {"text": evidence[0]["text"]}}
    messages = messages_for(payload)
    key, model = await pool.acquire({**config, "task": "math_skill_learning"})
    results = []
    try:
        for label, supplied in (("existing_catalogue_coverage", snapshots), ("isolated_empty_catalogue_discovery", ())):
            meter = Meter(); previous = model.callbacks; model.callbacks = [meter]; started = time.monotonic()
            try:
                with tracing_context(enabled=False):
                    async with asyncio.timeout(timeout):
                        text, execution = await learn_skills(model, messages, supplied, {"evidence": evidence, "existing_patterns": []})
                output = json.loads(text)
                if output["status"] == "approved" or "human_decision" in output:
                    raise ValueError("Unexpected human approval")
                # Portable graph state contains no credentials, photos or model objects.
                results.append({"scenario": label, "status": "ok", "output": output, "execution": execution})
            except Exception as error:
                results.append({"scenario": label, "status": "failed", "error_type": type(error).__name__, "error_code": getattr(error, "code", "model_or_protocol_error")})
            finally:
                model.callbacks = previous
                results[-1]["metrics"] = meter.report(); results[-1]["latency_seconds"] = round(time.monotonic() - started, 3)
    finally:
        pool.release(key)
    return results


async def run(args, payload):
    if set(payload) != {"configuration", "instructions", "teaching_skills"}:
        raise ValueError("Unexpected bridge payload")
    config = payload["configuration"]
    if not isinstance(config, dict) or set(config) != {"api", "api_key", "endpoint", "model", "thinking", "direct_connection"}:
        raise ValueError("Invalid bridge configuration")
    snapshots = snapshots_for(payload["teaching_skills"])
    fast_cards = None
    if getattr(args, "fast_only", False):
        from math_fast_selection import build_cards
        fast_cards = build_cards(snapshots, args.profiles, args.skill_index)
    path = Path(args.corpus)
    raw = path.read_bytes(); corpus = json.loads(raw)
    cases = selected_cases(corpus, args.cases, args.limit)
    photo = None
    if getattr(args, "photo", None):
        if len(cases) != 1:
            raise ValueError("Photo evaluation requires exactly one selected case")
        photo = Path(args.photo).read_bytes()
    report = {"schema_version": 1, "model": config["model"], "api": config["api"],
        "corpus_sha256": hashlib.sha256(raw).hexdigest(), "catalogue_count": len(snapshots),
        "selection_instructions_sha256": hashlib.sha256(payload["instructions"].encode()).hexdigest(),
        "engine_sources_sha256": {source.name: hashlib.sha256(source.read_bytes()).hexdigest()
            for source in sorted(Path(__file__).parent.glob("*.py"))},
        "catalogue_versions": [{"id": v["id"], "skill_name": v.get("skill_name"), "version_id": v["version_id"],
            "instructions_sha256": hashlib.sha256(v["instructions"].encode()).hexdigest()} for v in snapshots],
        "input_mode": "reviewed_corpus_text_only", "answer_accuracy_evaluated": False,
        "human_approval_granted": False, "production_data_modified": False,
        "excluded_quarantine_ids": [c["id"] for c in corpus["cases"] if c.get("kind") == "source_quarantine"],
        "limitations": ["Routing labels are expectations, not independently certified mathematical proofs.",
            "held_out labels denote a corpus split; some cases appeared in earlier project tests.",
            "This comparison uses readable text; original-photo and rendering acceptance is separate.",
            "Message bytes sum actual repeated model inputs, excluding tool schemas, HTTP overhead and secrets.",
            "All failures and explicit full-snapshot fallbacks remain visible; no self-approval is granted."],
        "cases": [], "complete": False}
    if photo is not None:
        report["input_mode"] = "original_photo_only"
        report["photo_sha256"] = hashlib.sha256(photo).hexdigest()
        report["limitations"][2] = "Original photo is sent without corpus stem or OCR; rendering and native UI latency remain separate."
    if getattr(args, "fast_only", False):
        report["experiment"] = {"mode": "single_call_fast_selection", "max_model_calls": 1,
            "independent_prerequisite_review": False, "solver_full_instructions_tested": False,
            "profiles_sha256": hashlib.sha256(Path(args.profiles).read_bytes()).hexdigest(),
            "skill_index_sha256": hashlib.sha256(Path(args.skill_index).read_bytes()).hexdigest()}
    destination = Path(args.output)
    write_report(destination, report, config["api_key"])
    pool = ModelPool()
    key = None
    try:
        key, model = await pool.acquire({**config, "task": "math_method_selection"})
        for index, case in enumerate(cases):
            messages = evaluation_messages(payload["instructions"], case, photo)
            row = {"id": case["id"], "kind": case["kind"], "split": case["split"],
                   "expected_methods": case.get("expected_methods", []), "expected_visuals": case.get("expected_visuals", []),
                   "gold_check_count": len(case.get("gold_checks", [])), "order": ["framework", "full_snapshot"] if index % 2 == 0 else ["full_snapshot", "framework"]}
            if getattr(args, "fast_only", False):
                row["order"] = ["fast_selection"]
            for lane in row["order"]:
                row[lane] = await attempt(model, messages, snapshots, case, lane, args.timeout, fast_cards=fast_cards)
            report["cases"].append(row)
            write_report(destination, report, config["api_key"])
            print("Compared " + case["id"], file=sys.stderr, flush=True)
        pool.release(key); key = None
        if args.learning_smoke:
            report["learning_smoke"] = await learning_smoke(pool, config, snapshots, args.timeout)
        report["complete"] = True
        write_report(destination, report, config["api_key"])
    finally:
        if key is not None: pool.release(key)
        await pool.close()
    print(json.dumps({"complete": True, "attempted_cases": len(report["cases"]), "summary": report["summary"]}, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", required=True); parser.add_argument("--output", required=True)
    parser.add_argument("--cases"); parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--timeout", type=float, default=90); parser.add_argument("--learning-smoke", action="store_true")
    parser.add_argument("--fast-only", action="store_true")
    parser.add_argument("--profiles"); parser.add_argument("--skill-index")
    parser.add_argument("--photo", help="One original PNG/JPEG; select exactly one corresponding corpus case")
    args = parser.parse_args()
    if args.fast_only and (not args.profiles or not args.skill_index):
        parser.error("Fast selection requires version-bound profiles and skill index")
    if args.limit < 0 or not 1 <= args.timeout <= 300: parser.error("Invalid bounded evaluation settings")
    try:
        data = sys.stdin.buffer.read(1_000_001)
        if len(data) > 1_000_000: raise ValueError("Bridge payload too large")
        asyncio.run(run(args, json.loads(data)))
    except Exception as error:
        print(json.dumps({"error_type": type(error).__name__, "error_code": getattr(error, "code", "evaluation_failed")}))
        raise SystemExit(1) from None


if __name__ == "__main__": main()
