"""Drawing recipes, exact graph/grid arithmetic, and a general fallback.

Drawing recipes pass original quantities to native verification. The bounded
graph and equal-line grid tools execute locally and generate their own text.
None authenticates the source image or grants human teaching approval.
"""
import copy
import json
import math
import math_path_submission
import math_magic_submission
import math_reflected_submission
import math_digit_submission
from math_solution_contract import (
    MAX_BYTES, SolutionContractError, _DEFS, _DIAGRAMS, _PARAMETERS,
    _constant, _deepseek_strict_schema, _object, _pairs, _require_all_properties,
    _text, _validate, normalize_arguments,
)

GENERAL_TOOL_NAME = "submit_general_math_solution"
_PRECONDITIONS = {
    "difference_ratio": "原题给出差数及倍数，画等份比较；差数不是总量。",
    "sum_difference": "原题给出两量的总数与差数，画和差比较。",
    "sum_ratio": "原题给出两量总数与倍数，画和倍等份比较；总数不是差数。",
    "equalize_transfer": "两方直接移多补少使相等，原题给出各方数量；不要把计算出的差或平分常数当已知。",
    "cyclic_pattern": "原题明确一个完整重复顺序和总项数；周期长度由程序数出。",
    "rectangle_sum_difference": "单独引用原题长方形条件，再引用同单位长宽之和与差；不是周长，程序求长宽及面积。",
    "venn_counts": "总人数、两组各自含交集的人数与两组都参加人数已知，程序求仅各组、并集和圈外；不是只左只右人数。",
    "state_changes": "原题给初始数量及按先后顺序发生的增加/减少，同一单位，最多5次；不是周期，不反推未知初值。程序逐步计算并绘状态图。",
    "fixed_total": "同一批物理资源，原题给出原来每件用量、原件数和新每件用量，求完整新件数；无单位换算。",
    "return_deadline": "恒速去程立即沿原路返回，无停留，已知两速度、去程时间与限时；绘往返对照表。",
    "interval_problem": "正楼层向上且相邻台阶相同，或直线等距植树且端点明确；向下、地下、环形不得套用。",
    "two_allocations": "同批物品两次分配；余缺物品数与余缺人数按balance.kind区分，程序求总量与人数，不能先算。",
    "purchase_comparison": "同商品同原价、恰好所需数量的两独立优惠：原价每满减或买几送几；不得叠加或求超量最优。",
}


def _reachable_definitions(parameters, local_definitions=None):
    """Copy only definitions actually reached by this function's schema."""
    registry = {**_DEFS, **(local_definitions or {})}
    found = {}
    def visit(node):
        if isinstance(node, dict):
            if "$ref" in node:
                name = node["$ref"].split("/")[-1]
                if name not in found:
                    found[name] = copy.deepcopy(registry[name])
                    visit(found[name])
            for value in node.values():
                visit(value)
        elif isinstance(node, list):
            for value in node:
                visit(value)
    visit(parameters)
    return found


def _parameters():
    common = {key: copy.deepcopy(_PARAMETERS["properties"][key])
              for key in ("method_id", "visual_method_ids")}
    native = {}
    general = []
    for original in _DIAGRAMS:
        schema = copy.deepcopy(original)
        kind = schema["properties"]["kind"]["enum"][0]
        if kind == "quantity_plan":
            if "layout" in schema["properties"]:
                general.append(schema)
            continue
        del schema["properties"]["kind"]
        schema["required"].remove("kind")
        native.setdefault(kind, []).append(schema)
    tools = {}
    for kind, variants in native.items():
        local_definitions = {}
        if kind == "interval_problem":
            for name, units in {"floor_quantity": ["层", "楼"], "step_quantity": ["级", "级台阶"], "distance_quantity": ["米"]}.items():
                definition = copy.deepcopy(_DEFS["quantity"])
                definition["properties"]["unit"] = {"enum": units}
                local_definitions[name] = definition
            for variant in variants:
                fields = ({"start_floor": "floor_quantity", "end_floor": "floor_quantity", "steps_per_interval": "step_quantity"}
                          if variant["properties"]["scenario"]["enum"] == ["stairs"]
                          else {"length": "distance_quantity", "spacing": "distance_quantity"})
                for field, definition in fields.items():
                    variant["properties"][field] = {"$ref": "#/$defs/" + definition}
        diagram = variants[0] if len(variants) == 1 else {"anyOf": variants}
        if kind == "two_allocations":
            diagram["properties"]["item_unit"] = {"enum": ["张", "本", "个", "只", "袋", "箱", "件", "枝", "元", "千克", "米"]}
            diagram["properties"]["recipient_unit"] = {"enum": ["人", "名", "名同学", "个", "组", "班", "只", "辆"]}
            # Distinguish the meaning of the submitted number at its own field,
            # rather than leaving four different units in one enum branch.
            balance = diagram["properties"]["allocations"]["items"]["properties"]["balance"]
            template = balance["anyOf"][1]
            descriptions = {"surplus": "原题剩余物品数", "shortfall": "原题欠缺物品数",
                            "extra_recipients": "原题剩余还能分给的接收者人数，不填乘算结果",
                            "missing_recipients": "原题还缺分配的接收者人数，不填乘算结果"}
            balance["anyOf"] = [balance["anyOf"][0]]
            for status, description in descriptions.items():
                branch = copy.deepcopy(template)
                branch["properties"]["kind"] = {"enum": [status]}
                branch["properties"]["value"]["description"] = description
                balance["anyOf"].append(branch)
        tools["render_" + kind] = _object({**copy.deepcopy(common), "relationship": _text(120), "diagram": diagram})
        if local_definitions:
            tools["render_" + kind]["$defs"] = local_definitions
    outcome = copy.deepcopy(_PARAMETERS["properties"]["diagram_outcome"])
    # Shared reference avoids duplicating ten view contracts within this function.
    general_ref = {"$ref": "#/$defs/general_diagram"}
    outcome["anyOf"][0]["properties"]["primary_diagram"] = general_ref
    outcome["anyOf"][0]["properties"]["additional_diagrams"]["items"] = general_ref
    tools[math_path_submission.TOOL_NAME] = math_path_submission.parameters(copy.deepcopy(common))
    tools[math_magic_submission.TOOL_NAME] = math_magic_submission.parameters(copy.deepcopy(common))
    tools[math_digit_submission.TOOL_NAME] = math_digit_submission.parameters(copy.deepcopy(common))
    tools[math_reflected_submission.TOOL_NAME] = math_reflected_submission.parameters(copy.deepcopy(common))
    tools[GENERAL_TOOL_NAME] = _object({**copy.deepcopy(common), "answer": _text(40_000), "diagram_outcome": outcome})
    for name, schema in tools.items():
        if name == GENERAL_TOOL_NAME:
            # Reachability uses a local definition absent from the shared registry.
            # Traverse canonical views independently, then attach the shared union.
            definitions = _reachable_definitions({"anyOf": general})
            definitions["general_diagram"] = {"anyOf": general}
        else:
            definitions = _reachable_definitions(schema, schema.get("$defs"))
        if definitions:
            schema["$defs"] = definitions
    return tools


_TOOL_PARAMETERS = _parameters()


def _provider_bounds(schema, strict=False):
    """Keep the brief bound; other text sizes are locally bounded, not decoder work."""
    if isinstance(schema, list):
        return [_provider_bounds(item, strict) for item in schema]
    if not isinstance(schema, dict):
        return schema
    result = {}
    for key, value in schema.items():
        if key in ("minLength", "maxLength", "pattern"):
            continue
        if key == "properties":
            result[key] = {name: (copy.deepcopy(item) if name == "relationship" else _provider_bounds(item, strict))
                           for name, item in value.items()}
        else:
            result[key] = _provider_bounds(value, strict)
    return result


def _scoped_parameters(name, diagram_scope):
    if diagram_scope not in ("full", "native_only"):
        raise ValueError("invalid diagram_scope")
    schema = _TOOL_PARAMETERS[name]
    if diagram_scope == "native_only" and name == GENERAL_TOOL_NAME:
        schema = copy.deepcopy(schema)
        schema["properties"]["diagram_outcome"]["anyOf"] = [
            branch for branch in schema["properties"]["diagram_outcome"]["anyOf"]
            if branch["properties"]["status"]["enum"] not in (["renderable"], ["inline_geometry"])]
        schema.pop("$defs", None)
    return schema


def tool_schemas(strict=False, *, diagram_scope="full"):
    """Independent concrete-root functions; strict is explicit Beta-only configuration."""
    result = []
    for name in _TOOL_PARAMETERS:
        schema = copy.deepcopy(_scoped_parameters(name, diagram_scope))
        if name == GENERAL_TOOL_NAME:
            description = ("解答及布局图；math-grid用inline_grid，math-center-cut用inline_geometry，math-cube-path用inline_cube，math-triangle-dissection用inline_triangle，math-hexagon-partition用inline_hexagon；否则说明无图原因。"
                           "用operation/inputs推导，不造已知。主方法可空。")
        elif name == math_path_submission.TOOL_NAME:
            description = math_path_submission.DESCRIPTION
        elif name == math_magic_submission.TOOL_NAME:
            description = math_magic_submission.DESCRIPTION
        elif name == math_digit_submission.TOOL_NAME:
            description = math_digit_submission.DESCRIPTION
        elif name == math_reflected_submission.TOOL_NAME:
            description = math_reflected_submission.DESCRIPTION
        else:
            description = (_PRECONDITIONS[name.removeprefix("render_")]
                           + "只提交原题量，程序计算绘图。")
        if diagram_scope == "native_only" and name == GENERAL_TOOL_NAME:
            description = ("现有图解工具不适用时，提交完整文字解答并说明省略图解的原因；"
                           "也可提交有界 math-grid 围栏及 inline_grid 状态，或 math-cube-path 围栏及 inline_cube 状态，或 math-triangle-dissection 围栏及 inline_triangle 状态，或 math-hexagon-partition 围栏及 inline_hexagon 状态；不提交通用图。主方法可空。")
        if not strict and name == GENERAL_TOOL_NAME and diagram_scope == "full":
            # Standard JSON Schema applies the root object constraints AND the
            # view/layout union. Share identical common fields without changing
            # accepted layouts. Local validation retains the canonical union.
            variants = schema["$defs"]["general_diagram"]["anyOf"]
            shared = copy.deepcopy(variants[0])
            shared["properties"]["view"] = {"enum": [v["properties"]["view"]["enum"][0] for v in variants]}
            shared["properties"]["layout"] = {}
            shared["anyOf"] = [{"properties": {key: v["properties"][key] for key in ("view", "layout")},
                                "required": ["view", "layout"]} for v in variants]
            schema["$defs"]["general_diagram"] = shared
        function = {"name": name, "description": description, "parameters": _provider_bounds(schema)}
        if strict:
            function["parameters"] = _provider_bounds(_deepseek_strict_schema(_require_all_properties(schema)), True)
            function["strict"] = True
        result.append({"type": "function", "function": function})
    return result


def _finite_json(value):
    if type(value) is float and not math.isfinite(value):
        raise SolutionContractError("submission_number")
    if isinstance(value, dict):
        for item in value.values():
            _finite_json(item)
    elif isinstance(value, list):
        for item in value:
            _finite_json(item)


def _preserve_general(value, parameters, *, allow_diagrams=True):
    """Validate text separately; discard metadata that failed its own contract."""
    if not isinstance(value, dict):
        raise SolutionContractError("submission_shape")
    _validate(value.get("answer"), parameters["properties"]["answer"])
    control_keys = ("method_id", "visual_method_ids")
    controls = _object({key: parameters["properties"][key] for key in control_keys})
    method_id, visual_method_ids = None, []
    try:
        _validate({key: value[key] for key in control_keys if key in value}, controls)
        if (len(set(value["visual_method_ids"])) != len(value["visual_method_ids"])
                or value["method_id"] is not None and value["method_id"] in value["visual_method_ids"]):
            raise SolutionContractError("submission_duplicate_id")
        method_id, visual_method_ids = value["method_id"], value["visual_method_ids"]
    except SolutionContractError:
        pass
    diagrams = []
    outcome = value.get("diagram_outcome")
    if (allow_diagrams and isinstance(outcome, dict) and outcome.get("status") == "renderable"
            and not set(outcome) - {"status", "primary_diagram", "additional_diagrams"}):
        additional = outcome.get("additional_diagrams", [])
        if isinstance(additional, list) and len(additional) <= 2:
            candidates = ([outcome["primary_diagram"]] if "primary_diagram" in outcome else []) + additional
            identifiers = [d.get("id") for d in candidates if isinstance(d, dict) and isinstance(d.get("id"), str)]
            # A duplicate id makes the graph namespace ambiguous; select no winner.
            if len(set(identifiers)) == len(identifiers):
                definitions = parameters.get("$defs", {})
                for diagram in candidates:
                    try:
                        _validate(diagram, definitions["general_diagram"], definitions)
                    except (SolutionContractError, OverflowError, RecursionError):
                        continue
                    diagrams.append(diagram)
    preserved = {"schemaVersion": 1, "mode": "general", "method_id": method_id,
                 "visual_method_ids": visual_method_ids, "answer": value["answer"], "diagrams": diagrams,
                 "diagram_submission_failure": "submission_shape"}
    try:
        encoded = json.dumps(preserved, ensure_ascii=False).encode("utf-8")
    except (ValueError, UnicodeError, RecursionError):
        raise SolutionContractError("submission_json") from None
    if len(encoded) > MAX_BYTES:
        raise SolutionContractError("submission_size")
    return preserved


def _preserve_text(name, value, parameters, *, diagram_scope="full"):
    if name in (math_path_submission.TOOL_NAME, math_magic_submission.TOOL_NAME, math_reflected_submission.TOOL_NAME, math_digit_submission.TOOL_NAME):
        raise SolutionContractError("submission_shape")
    if name == GENERAL_TOOL_NAME:
        return _preserve_general(value, parameters, allow_diagrams=diagram_scope == "full")
    # Native recipes contain only a relation, not an independently computed
    # answer. Keep that limited explanation visibly incomplete at the UI boundary.
    if not isinstance(value, dict):
        raise SolutionContractError("submission_shape")
    _validate(value.get("relationship"), parameters["properties"]["relationship"])
    try:
        value["relationship"].encode("utf-8")
    except UnicodeError:
        raise SolutionContractError("submission_json") from None
    return {"schemaVersion": 1, "mode": "general", "method_id": None,
            "visual_method_ids": [], "answer": value["relationship"], "diagrams": [],
            "diagram_submission_failure": "submission_relationship_only"}


def _normalize_tool_arguments(name, raw, *, strict=False, text_only_authorized=False, preserve_general_answer=False, diagram_scope="full"):
    """Validate one call; graph submissions count locally without provider retries."""
    if not isinstance(name, str) or name not in _TOOL_PARAMETERS:
        raise SolutionContractError("submission_tool")
    if not isinstance(raw, str):
        raise SolutionContractError("submission_json")
    try:
        if len(raw.encode("utf-8")) > MAX_BYTES:
            raise SolutionContractError("submission_size")
        value = json.loads(raw, object_pairs_hook=_pairs, parse_constant=_constant)
    except SolutionContractError:
        raise
    except (ValueError, UnicodeError, RecursionError):
        raise SolutionContractError("submission_json") from None
    parameters = _scoped_parameters(name, diagram_scope)
    if strict:
        parameters = _require_all_properties(parameters)
    # Non-finite values invalidate the entire JSON document, even in optional
    # diagram fields. Never use them as a path into text preservation.
    try:
        _finite_json(value)
    except (RecursionError, OverflowError):
        raise SolutionContractError("submission_shape") from None
    try:
        _validate(value, parameters, parameters.get("$defs", {}))
    except SolutionContractError as error:
        if preserve_general_answer is True and error.issue in ("submission_shape", "submission_number"):
            try:
                preserved = _preserve_text(name, value, parameters, diagram_scope=diagram_scope)
            except SolutionContractError:
                raise error from None
            return preserved
        raise
    except (RecursionError, OverflowError):
        raise SolutionContractError("submission_shape") from None
    if name == math_path_submission.TOOL_NAME:
        return math_path_submission.normalize(value)
    if name == math_magic_submission.TOOL_NAME:
        return math_magic_submission.normalize(value)
    if name == math_digit_submission.TOOL_NAME:
        return math_digit_submission.normalize(value)
    if name == math_reflected_submission.TOOL_NAME:
        return math_reflected_submission.normalize(value)
    if name == GENERAL_TOOL_NAME:
        submission = {"mode": "general", **value}
    else:
        diagram = {**value["diagram"], "kind": name.removeprefix("render_")}
        submission = {"mode": "native_recipe", "method_id": value["method_id"],
            "visual_method_ids": value["visual_method_ids"], "answer": value["relationship"],
            "diagram_outcome": {"status": "renderable", "primary_diagram": diagram}}
    try:
        encoded = json.dumps(submission, ensure_ascii=False)
    except (ValueError, UnicodeError, RecursionError):
        raise SolutionContractError("submission_json") from None
    try:
        return normalize_arguments(encoded, text_only_authorized=text_only_authorized)
    except SolutionContractError as error:
        if preserve_general_answer is True and error.issue in ("submission_duplicate_id", "submission_inline_grid", "submission_inline_geometry", "submission_inline_cube", "submission_inline_triangle", "submission_inline_hexagon", "submission_inline_route"):
            return _preserve_text(name, value, parameters, diagram_scope=diagram_scope)
        raise


def normalize_tool_arguments(name, raw, *, strict=False, text_only_authorized=False, preserve_general_answer=False, diagram_scope="full"):
    try:
        return _normalize_tool_arguments(name, raw, strict=strict,
            text_only_authorized=text_only_authorized, preserve_general_answer=preserve_general_answer,
            diagram_scope=diagram_scope)
    except SolutionContractError as error:
        if error.diagnostic is not None and isinstance(name, str) and name in _TOOL_PARAMETERS:
            error.diagnostic = {**error.diagnostic, "tool": name}
        raise
