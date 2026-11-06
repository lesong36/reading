"""Inert single-submission contract; native code verifies source facts and arithmetic.

This validates transport shape, never authenticates quotations or computes answers.
"""
import copy
import json
import math
import re

TOOL_NAME = "submit_math_solution"
MAX_BYTES = 150_000


class SolutionContractError(ValueError):
    def __init__(self, issue, *, path=None, rule=None):
        self.issue = issue
        # Paths come only from schema properties and locally enumerated indexes.
        self.diagnostic = {"path": path, "rule": rule} if path is not None else None
        super().__init__(issue)


def _text(limit=500, empty=False):
    return {"type": "string", "minLength": 0 if empty else 1, "maxLength": limit}


def _array(items, minimum=0, maximum=32):
    return {"type": "array", "items": items, "minItems": minimum, "maxItems": maximum}


def _object(properties, optional=()):
    return {"type": "object", "properties": properties,
            "required": [k for k in properties if k not in optional], "additionalProperties": False}


def _enum(*values):
    return {"enum": list(values)}


def _ref(name):
    return {"$ref": "#/$defs/" + name}


_NUMBER = {"type": "number", "minimum": -1_000_000_000, "maximum": 1_000_000_000}
_DEFS = {
    "source": _object({"value": _NUMBER, "evidence": _text()}),
    "quantity": _object({"value": _NUMBER, "unit": _text(24, True), "evidence": _text()}),
    "multiplier": _object({"value": {"type": "integer", "minimum": 2, "maximum": 20},
        "unit": {"enum": ["", "倍"]}, "evidence": _text()}, ("unit",)),
    "ratio_quantity": _object({"value": {"type": "integer", "minimum": 2, "maximum": 20},
        "unit": {"enum": ["", "倍"]}, "evidence": _text()}),
}
_ID = _text(80)
_DEFS["ids"] = _array(_ID, maximum=32)
_IDS = _ref("ids")
_ROW = _object({"label": _text(100), "factIDs": _IDS})
_OPERATIONS = _enum("sum", "difference", "product", "quotient", "equal", "floor_quotient", "remainder")


def _recipe(kind, fields, optional=()):
    return _object({"id": _ID, "title": _text(120), "kind": _enum(kind), **fields}, optional)


_DIAGRAMS = [
    _recipe("difference_ratio", {"difference": _ref("quantity"), "multiplier": _ref("multiplier")}),
    _recipe("sum_difference", {"total": _ref("quantity"), "difference": _ref("quantity")}),
    _recipe("sum_ratio", {"total": _ref("quantity"), "multiplier": _ref("ratio_quantity")}),
    _recipe("equalize_transfer", {"larger": _ref("quantity"), "smaller": _ref("quantity"), "equality_evidence": _text()}),
    _recipe("cyclic_pattern", {"count": _ref("source"), "labels": _array(_text(30), 1, 12), "pattern_evidence": _text()}),
    _recipe("state_changes", {"initial": _ref("quantity"),
        "changes": _array(_object({"direction": _enum("increase", "decrease"), "amount": _ref("quantity")}), 1, 5)}),
    _recipe("rectangle_sum_difference", {"rectangle_evidence": _text(), "total_sides": _ref("quantity"), "difference": _ref("quantity")}),
    _recipe("venn_counts", {key: _ref("quantity") for key in ("total", "left", "right", "intersection")}),
    _recipe("fixed_total", {"resource_unit": _text(24), "count_unit": _text(24),
        "original_per_item": _ref("quantity"), "original_count": _ref("quantity"),
        "improved_per_item": _ref("quantity"), "conservation_evidence": _text()}),
    _recipe("return_deadline", {"distance_unit": _enum("米", "千米"), "time_unit": _enum("分钟", "小时"),
        **{k: _ref("source") for k in ("outward_speed", "return_speed", "outward_time", "deadline")}}),
    _recipe("interval_problem", {"scenario": _enum("stairs"),
        **{k: _ref("quantity") for k in ("start_floor", "end_floor", "steps_per_interval")}}),
    _recipe("interval_problem", {"scenario": _enum("planting"), "length": _ref("quantity"),
        "spacing": _ref("quantity"), "endpoints": _enum("both", "one", "neither"), "endpoint_evidence": _text()}),
]
_BALANCE = {"anyOf": [
    _object({"kind": _enum("exact"), "evidence": _text()}),
    _object({"kind": _enum("surplus", "shortfall", "extra_recipients", "missing_recipients"), "value": _NUMBER, "evidence": _text()}),
]}
_DIAGRAMS.append(_recipe("two_allocations", {"item_unit": _text(24), "recipient_unit": _text(24),
    "allocations": _array(_object({"per_recipient": _ref("source"), "balance": _BALANCE}), 2, 2),
    "view": _enum("table", "bar_comparison")}, ("view",)))
_OFFER = {"anyOf": [
    _object({"name": _text(40), "kind": _enum("threshold_reduction"), "threshold": _ref("source"), "reduction": _ref("source")}),
    _object({"name": _text(40), "kind": _enum("buy_get"), "paid": _ref("source"), "free": _ref("source")}),
]}
_DIAGRAMS.append(_recipe("purchase_comparison", {"item_unit": _enum("本", "张", "个"), "currency_unit": _enum("元"),
    "quantity_policy": _enum("exact_required_quantity"), "required_count": _ref("source"), "unit_price": _ref("source"),
    "offers": _array(_OFFER, 2, 2)}))

_Q_BASE = {"id": _ID, "label": _text(100), "unit": _text(24, True)}
_QUANTITIES = {"anyOf": [
    _object({**_Q_BASE, "value": _NUMBER, "evidence": _text()}, ("unit",)),
    _object({**_Q_BASE, "operation": _OPERATIONS, "inputs": _array(_ID, 1, 12)}, ("unit",)),
    _object({**_Q_BASE, "rule": _enum("zero", "one", "two", "ten", "hundred", "thousand")}, ("unit",)),
    _object({**_Q_BASE, "unknown": _enum(True)}, ("unit",)),
]}
_DEFS["quantities"] = _array(_QUANTITIES, 1, 32)
_DEFS["parts"] = _array({"type": "integer", "minimum": 1, "maximum": 20}, maximum=32)
_PARTS = _ref("parts")
_DEFS["checks"] = _array(_object({"operation": _OPERATIONS, "inputs": _array(_ID, 1, 12), "result": _ID}), maximum=32)
_CHECKS = _ref("checks")
_DEFS["rows"] = _array(_ROW)
_ROWS = _ref("rows")
_DEFS["columns"] = _array(_text(100), maximum=32)
_COLUMNS = _ref("columns")
_LAYOUTS = {
    "bar_comparison": {"items": _IDS}, "equal_parts": {"items": _IDS, "parts": _PARTS},
    "state": {"states": _IDS}, "table": {"columns": _COLUMNS, "rows": _ROWS},
    "area": {k: _ID for k in ("length", "width", "area")},
    "interval": {k: _ID for k in ("start", "end", "gaps", "per", "total")},
    "balance": {k: _ID for k in ("high", "low", "mean", "transfer")},
    "part_whole": {"whole": _ID, "portions": _IDS},
    "venn": {k: _ID for k in ("leftOnly", "intersection", "rightOnly", "union")},
    "cycle": {**{k: _ID for k in ("count", "period", "cycles", "remainder")}, "labels": _array(_text(100))},
}
for _view, _layout in _LAYOUTS.items():
    _layout_schema = _object(_layout)
    if _view == "venn":
        _layout_schema = {"anyOf": [_layout_schema, _object({**_layout, "outside": _ID, "total": _ID})]}
    _base = {"view": _enum(_view), "quantities": _ref("quantities"), "checks": _CHECKS}
    _DIAGRAMS.append(_recipe("quantity_plan", {**_base, "layout": _layout_schema}, ("checks",)))
    # Preserve the established positional transport as well as named layouts.
    _DIAGRAMS.append(_recipe("quantity_plan", {**_base, "factIDs": _IDS, "parts": _PARTS,
        "columns": _COLUMNS, "rows": _ROWS}, ("checks", "factIDs", "parts", "columns", "rows")))

_DEFS["diagram"] = {"anyOf": _DIAGRAMS}
_PARAMETERS = _object({
    "mode": _enum("native_recipe", "general"),
    "method_id": {"anyOf": [_text(120), {"type": "null"}]},
    "visual_method_ids": _array(_text(120), maximum=2),
    "answer": _text(40_000),
    "diagram_outcome": {"anyOf": [
        _object({"status": _enum("renderable"), "primary_diagram": _ref("diagram"),
                 "additional_diagrams": _array(_ref("diagram"), maximum=2)}, ("additional_diagrams",)),
        _object({"status": _enum("unreadable_or_insufficient", "no_helpful_diagram", "user_requested_text_only"), "reason": _text(500)}),
        _object({"status": _enum("inline_grid")}),
        _object({"status": _enum("inline_cube")}),
        _object({"status": _enum("inline_triangle")}),
        _object({"status": _enum("inline_hexagon")}),
        _object({"status": _enum("inline_route")}),
        _object({"status": _enum("inline_geometry")}),
        _object({"status": _enum("inline_rectangle_dissection")}),
    ]},
})
_PARAMETERS["$defs"] = _DEFS


def _require_all_properties(schema):
    """Strict input shape, retaining local length/cardinality safety bounds."""
    if isinstance(schema, list):
        return [_require_all_properties(item) for item in schema]
    if not isinstance(schema, dict):
        return schema
    result = {key: _require_all_properties(item) for key, item in schema.items()}
    if result.get("type") == "object" and "properties" in result:
        result["required"] = list(result["properties"])
        result["additionalProperties"] = False
    return result


def _strict_parameters():
    definitions = copy.deepcopy(_DEFS)
    del definitions["diagram"]
    definitions["native_diagram"] = {"anyOf": [copy.deepcopy(d) for d in _DIAGRAMS
        if d["properties"]["kind"]["enum"][0] != "quantity_plan"]}
    definitions["general_diagram"] = {"anyOf": [copy.deepcopy(d) for d in _DIAGRAMS
        if d["properties"]["kind"]["enum"][0] == "quantity_plan"]}
    def renderable(name):
        return _object({"status": _enum("renderable"), "primary_diagram": _ref(name),
                        "additional_diagrams": _array(_ref(name), maximum=2)})
    common = {key: copy.deepcopy(_PARAMETERS["properties"][key])
              for key in ("method_id", "visual_method_ids")}
    native = _object({"mode": _enum("native_recipe"), **common, "answer": _text(120),
                      "diagram_outcome": renderable("native_diagram")})
    general = _object({"mode": _enum("general"), **common, "answer": _text(40_000),
        "diagram_outcome": {"anyOf": [renderable("general_diagram"),
            _object({"status": _enum("unreadable_or_insufficient", "no_helpful_diagram", "user_requested_text_only"),
                     "reason": _text(500)}),
            _object({"status": _enum("inline_grid")}),
        _object({"status": _enum("inline_cube")}),
            _object({"status": _enum("inline_triangle")}),
        _object({"status": _enum("inline_hexagon")}),
        _object({"status": _enum("inline_route")}),
            _object({"status": _enum("inline_geometry")}),
            _object({"status": _enum("inline_rectangle_dissection")})]}})
    # Branches remain mutually exclusive through mode; fields retain the existing wire shape.
    return _require_all_properties({"anyOf": [native, general], "$defs": definitions})


_STRICT_PARAMETERS = _strict_parameters()


def _deepseek_strict_schema(schema):
    """Documented Beta subset. `$def` spelling follows the official example.

    Null acceptance still requires an actual provider capability probe;
    never replace null with a fabricated method or silently fall back/retry.
    https://api-docs.deepseek.com/guides/tool_calls/
    """
    if isinstance(schema, list):
        return [_deepseek_strict_schema(item) for item in schema]
    if not isinstance(schema, dict):
        return schema
    result = {("$def" if key == "$defs" else key): _deepseek_strict_schema(item)
              for key, item in schema.items()
              if key not in ("minLength", "maxLength", "minItems", "maxItems")}
    if "$ref" in result:
        result["$ref"] = result["$ref"].replace("#/$defs/", "#/$def/")
    if "enum" in result and "type" not in result:
        values = result["enum"]
        if all(isinstance(value, str) for value in values):
            result["type"] = "string"
        elif all(type(value) is bool for value in values):
            result["type"] = "boolean"
    if result.get("type") == "string":
        minimum = schema.get("minLength", 0)
        maximum = schema.get("maxLength", 40_000)
        if maximum <= 120:
            result["pattern"] = r"^[\s\S]{" + str(minimum) + "," + str(maximum) + "}$"
    return result


def _strict_wire_parameters():
    branch = copy.deepcopy(_STRICT_PARAMETERS)
    definitions = branch.pop("$defs")
    root = _object({"solution": branch})
    root["$defs"] = definitions
    return root


def tool_schema(strict=False):
    """Fresh single tool; strict mode is explicit and requires the Beta endpoint."""
    function = {"name": TOOL_NAME,
        "description": "Submit one complete solution with cited original quantities. Do not force a named method. Supply a useful checked diagram or explicitly explain why none is appropriate. Native code computes recipe results; do not invent givens.",
        "parameters": _deepseek_strict_schema(_strict_wire_parameters()) if strict else copy.deepcopy(_PARAMETERS)}
    if strict:
        function["strict"] = True
    return {"type": "function", "function": function}


def _validate(value, schema, definitions=None, path="$"):
    definitions = _DEFS if definitions is None else definitions
    def fail(rule, issue="submission_shape", field_path=path):
        raise SolutionContractError(issue, path=field_path, rule=rule)
    if "$ref" in schema:
        return _validate(value, definitions[schema["$ref"].split("/")[-1]], definitions, path)
    if "anyOf" in schema:
        failures = []
        for branch in schema["anyOf"]:
            try:
                _validate(value, branch, definitions, path)
                return
            except SolutionContractError as error:
                # Prefer the matching discriminator, then the most specific field.
                matches = sum(isinstance(value, dict) and value.get(key) in item.get("enum", [])
                    for key, item in branch.get("properties", {}).items() if "enum" in item)
                failures.append((matches, len((error.diagnostic or {}).get("path", "")), error))
        best = max(failures, key=lambda item: item[:2])[2]
        detail = best.diagnostic or {"path": path, "rule": "anyOf"}
        raise SolutionContractError("submission_shape", **detail)
    if "enum" in schema and not any(type(value) is type(v) and value == v for v in schema["enum"]):
        fail("enum")
    kind = schema.get("type")
    if kind == "null" and value is not None:
        fail("type")
    if kind == "string":
        if not isinstance(value, str):
            fail("type")
        if len(value) > schema.get("maxLength", 40_000):
            fail("maxLength")
        if schema.get("minLength", 0) and not value.strip():
            fail("minLength")
    if kind in ("number", "integer"):
        if type(value) not in (int, float):
            fail("type", "submission_number")
        if not math.isfinite(value):
            fail("finite", "submission_number")
        if value < schema["minimum"]:
            fail("minimum", "submission_number")
        if value > schema["maximum"]:
            fail("maximum", "submission_number")
        if kind == "integer" and value != int(value):
            fail("integer", "submission_number")
    if kind == "object":
        if not isinstance(value, dict):
            fail("type")
        if set(value) - set(schema["properties"]):
            # Never include an untrusted extra key in diagnostics.
            fail("additionalProperties")
        for key in schema["required"]:
            if key not in value:
                fail("required", field_path=path + "." + key)
        for key, item in value.items():
            _validate(item, schema["properties"][key], definitions, path + "." + key)
    if kind == "array":
        if not isinstance(value, list):
            fail("type")
        if len(value) < schema["minItems"]:
            fail("minItems")
        if len(value) > schema["maxItems"]:
            fail("maxItems")
        for index, item in enumerate(value):
            _validate(item, schema["items"], definitions, path + f"[{index}]")


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise SolutionContractError("submission_duplicate_key")
        result[key] = value
    return result


def _constant(_):
    raise SolutionContractError("submission_number")


def _validate_inline_grid_answer(answer):
    """Validate inert fenced input bounds only; WebView checks geometry at display.

    A complete top-level math-grid fence is required. Other fenced examples do
    not count, and an unfinished grid is not a successful diagram submission.
    """
    try:
        blocks, opening, body = [], None, []
        for line in answer.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
            if opening is not None:
                if re.fullmatch(r" {0,3}" + re.escape(opening[0]) +
                                "{" + str(opening[1]) + r",}[ \t]*", line):
                    if opening[2] == "math-grid":
                        blocks.append("\n".join(body))
                    opening, body = None, []
                else:
                    body.append(line)
                continue
            match = re.fullmatch(r" {0,3}(`{3,}|~{3,})([^\n]*)", line)
            if match:
                fence, language = match.groups()
                opening = (fence[0], len(fence), language.strip())
        if not blocks or opening is not None and opening[2] == "math-grid":
            raise ValueError("complete grid required")
        schema = _object({"title": _text(120),
            "unitWidth": {"type": "number", "minimum": 0.000001, "maximum": 1000},
            "unitHeight": {"type": "number", "minimum": 0.000001, "maximum": 1000},
            "source": _array(_array(_text(12, True), 1, 16), 1, 16),
            "target": _array(_array(_text(12, True), 1, 16), 1, 16)})
        for block in blocks:
            if len(block.encode("utf-16-le")) // 2 > 30000:
                raise ValueError("grid size")
            plan = json.loads(block, object_pairs_hook=_pairs, parse_constant=_constant)
            _validate(plan, schema)
            if re.search(r"[\x00-\x1f\x7f]", plan["title"]):
                raise ValueError("grid title")
            for key in ("unitWidth", "unitHeight"):
                value = plan[key]
                if abs(round(value * 1000000) / 1000000 - value) > 1e-12 * max(1, value):
                    raise ValueError("grid precision")
            for key in ("source", "target"):
                rows = plan[key]
                if any(len(row) != len(rows[0]) for row in rows):
                    raise ValueError("grid rows")
                labels = {label for row in rows for label in row if label != ""}
                if not 1 <= len(labels) <= 16 or any(label.strip() != label or
                        re.search(r"[\x00-\x1f\x7f]", label) for label in labels):
                    raise ValueError("grid labels")
    except (SolutionContractError, ValueError, UnicodeError, RecursionError, OverflowError):
        raise SolutionContractError("submission_inline_grid", path="$.answer", rule="inline_grid_input") from None


def _validate_inline_geometry_answer(answer):
    """Bounded schematic input only; neither source measurements nor math approval."""
    try:
        blocks, opening, body = [], None, []
        for line in answer.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
            if opening is not None:
                if re.fullmatch(r" {0,3}" + re.escape(opening[0]) +
                                "{" + str(opening[1]) + r",}[ \t]*", line):
                    if opening[2] == "math-center-cut":
                        blocks.append("\n".join(body))
                    opening, body = None, []
                else:
                    body.append(line)
                continue
            match = re.fullmatch(r" {0,3}(`{3,}|~{3,})([^\n]*)", line)
            if match:
                fence, language = match.groups()
                opening = (fence[0], len(fence), language.strip())
        if not blocks or opening is not None and opening[2] == "math-center-cut":
            raise ValueError("complete geometry required")
        dimension = {"type": "number", "minimum": 0.001, "maximum": 1000}
        schema = _object({"title": _text(120), "outerWidth": dimension, "outerHeight": dimension,
            "hole": _object({key: dimension for key in ("x", "y", "width", "height")})})
        for block in blocks:
            if len(block.encode("utf-16-le")) // 2 > 2000:
                raise ValueError("geometry size")
            plan = json.loads(block, object_pairs_hook=_pairs, parse_constant=_constant)
            _validate(plan, schema)
            if (len(plan["title"].encode("utf-16-le")) // 2 > 120 or
                    re.search(r"[<>\x00-\x1f\x7f]", plan["title"])):
                raise ValueError("geometry title")
            if max(plan["outerWidth"], plan["outerHeight"]) / min(plan["outerWidth"], plan["outerHeight"]) > 20:
                raise ValueError("geometry aspect")
            hole = plan["hole"]
            if not (0 < hole["x"] < hole["x"] + hole["width"] < plan["outerWidth"] and
                    0 < hole["y"] < hole["y"] + hole["height"] < plan["outerHeight"]):
                raise ValueError("strictly interior hole required")
    except (SolutionContractError, ValueError, UnicodeError, RecursionError, OverflowError):
        raise SolutionContractError("submission_inline_geometry", path="$.answer", rule="inline_geometry_input") from None


def _validate_inline_rectangle_dissection_answer(answer):
    try:
        blocks, opening, body = [], None, []
        for line in answer.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
            if opening is not None:
                if re.fullmatch(r" {0,3}" + re.escape(opening[0]) + "{" + str(opening[1]) + r",}[ \t]*", line):
                    if opening[2] == "math-rectangle-dissection": blocks.append("\n".join(body))
                    opening, body = None, []
                else: body.append(line)
                continue
            match = re.fullmatch(r" {0,3}(`{3,}|~{3,})([^\n]*)", line)
            if match:
                fence, language = match.groups(); opening = (fence[0], len(fence), language.strip())
        if not blocks or (opening is not None and opening[2] == "math-rectangle-dissection"): raise ValueError()
        for block in blocks:
            if len(block.encode("utf-16-le")) // 2 > 2000 or not re.fullmatch(r'\s*\{\s*"case"\s*:\s*"404-e12"\s*\}\s*', block): raise ValueError()
    except (ValueError, UnicodeError, RecursionError):
        raise SolutionContractError("submission_inline_rectangle_dissection", path="$.answer", rule="inline_rectangle_dissection_input") from None


def _validate_inline_cube_answer(answer):
    try:
        blocks, opening, body = [], None, []
        for line in answer.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
            if opening is not None:
                if re.fullmatch(r" {0,3}" + re.escape(opening[0]) + "{" + str(opening[1]) + r",}[ \t]*", line):
                    if opening[2] == "math-cube-path": blocks.append("\n".join(body))
                    opening, body = None, []
                else: body.append(line)
                continue
            match = re.fullmatch(r" {0,3}(`{3,}|~{3,})([^\n]*)", line)
            if match:
                fence, language = match.groups()
                opening = (fence[0], len(fence), language.strip())
        if not blocks or opening is not None and opening[2] == "math-cube-path": raise ValueError()
        for block in blocks:
            if len(block.encode("utf-16-le")) // 2 > 2000: raise ValueError()
            plan = json.loads(block, object_pairs_hook=_pairs, parse_constant=_constant)
            if not isinstance(plan, dict) or set(plan) != {"title", "edge"}: raise ValueError()
            title, edge = plan["title"], plan["edge"]
            if not isinstance(title, str) or not title.strip() or len(title.encode("utf-16-le")) // 2 > 120 or re.search(r"[<>\x00-\x1f\x7f]", title): raise ValueError()
            if type(edge) is not int or not 0 <= edge <= 5: raise ValueError()
    except (SolutionContractError, ValueError, UnicodeError, RecursionError, OverflowError, TypeError):
        raise SolutionContractError("submission_inline_cube", path="$.answer", rule="inline_cube_input") from None


def _validate_inline_triangle_answer(answer):
    try:
        blocks, opening, body = [], None, []
        for line in answer.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
            if opening is not None:
                if re.fullmatch(r" {0,3}" + re.escape(opening[0]) + "{" + str(opening[1]) + r",}[ \t]*", line):
                    if opening[2] == "math-triangle-dissection": blocks.append("\n".join(body))
                    opening, body = None, []
                else: body.append(line)
                continue
            match = re.fullmatch(r" {0,3}(`{3,}|~{3,})([^\n]*)", line)
            if match:
                fence, language = match.groups()
                opening = (fence[0], len(fence), language.strip())
        if not blocks or opening is not None and opening[2] == "math-triangle-dissection": raise ValueError()
        for block in blocks:
            if not (re.fullmatch(r'\s*\{\s*"pieces"\s*:\s*(?:5|13)\s*\}\s*', block)
                    or re.fullmatch(r'\s*\{\s*"case"\s*:\s*"404-e03"\s*\}\s*', block)):
                raise ValueError()
    except (ValueError, UnicodeError, RecursionError):
        raise SolutionContractError("submission_inline_triangle", path="$.answer", rule="inline_triangle_input") from None


def _validate_inline_hexagon_answer(answer):
    try:
        blocks, opening, body = [], None, []
        for line in answer.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
            if opening is not None:
                if re.fullmatch(r" {0,3}" + re.escape(opening[0]) + "{" + str(opening[1]) + r",}[ \t]*", line):
                    if opening[2] == "math-hexagon-partition": blocks.append("\n".join(body))
                    opening, body = None, []
                else: body.append(line)
                continue
            match = re.fullmatch(r" {0,3}(`{3,}|~{3,})([^\n]*)", line)
            if match:
                fence, language = match.groups()
                opening = (fence[0], len(fence), language.strip())
        if not blocks or opening is not None and opening[2] == "math-hexagon-partition": raise ValueError()
        for block in blocks:
            if not re.fullmatch(r'\s*\{\s*"sides"\s*:\s*(?:3|4|5)\s*\}\s*', block): raise ValueError()
    except (ValueError, UnicodeError, RecursionError):
        raise SolutionContractError("submission_inline_hexagon", path="$.answer", rule="inline_hexagon_input") from None


def _validate_inline_route_answer(answer):
    try:
        blocks, opening, body = [], None, []
        for line in answer.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
            if opening is not None:
                if re.fullmatch(r" {0,3}" + re.escape(opening[0]) + "{" + str(opening[1]) + r",}[ \t]*", line):
                    if opening[2] == "math-grid-route": blocks.append("\n".join(body))
                    opening, body = None, []
                else: body.append(line)
                continue
            match = re.fullmatch(r" {0,3}(`{3,}|~{3,})([^\n]*)", line)
            if match:
                fence, language = match.groups()
                opening = (fence[0], len(fence), language.strip())
        if not blocks or (opening is not None and opening[2] == "math-grid-route"): raise ValueError()
        for block in blocks:
            if len(block.encode("utf-16-le")) // 2 > 5000: raise ValueError()
            plan = json.loads(block, object_pairs_hook=_pairs, parse_constant=_constant)
            if not isinstance(plan, dict) or set(plan) != {"width", "height", "points", "stars"}: raise ValueError()
            w, h, points, stars = (plan[k] for k in ("width", "height", "points", "stars"))
            if type(w) is not int or type(h) is not int or not 1 <= w <= 8 or not 1 <= h <= 8: raise ValueError()
            if not isinstance(points, list) or not 2 <= len(points) <= 100 or not isinstance(stars, list) or len(stars) > 32: raise ValueError()
            for point in points + stars:
                if not isinstance(point, list) or len(point) != 2 or any(type(x) is not int for x in point) or not 0 <= point[0] <= w or not 0 <= point[1] <= h: raise ValueError()
            if any(abs(a[0]-b[0])+abs(a[1]-b[1]) != 1 for a,b in zip(points, points[1:])): raise ValueError()
    except (SolutionContractError, ValueError, UnicodeError, RecursionError, OverflowError, TypeError):
        raise SolutionContractError("submission_inline_route", path="$.answer", rule="inline_route_input") from None


def _normalize_arguments(raw, *, text_only_authorized=False, strict=False):
    """Parse exactly one inert tool argument object into the native six-field envelope."""
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
    try:
        if strict:
            _validate(value, _strict_wire_parameters(), _STRICT_PARAMETERS["$defs"])
            value = value["solution"]
        _validate(value, _PARAMETERS)
        if strict:
            _validate(value, _STRICT_PARAMETERS, _STRICT_PARAMETERS["$defs"])
    except (RecursionError, OverflowError):
        raise SolutionContractError("submission_shape") from None
    outcome = value["diagram_outcome"]
    if outcome["status"] == "renderable":
        diagrams = [outcome["primary_diagram"], *outcome.get("additional_diagrams", [])]
        if len({d["id"] for d in diagrams}) != len(diagrams):
            raise SolutionContractError("submission_duplicate_id")
        if value["mode"] == "native_recipe" and any(d["kind"] == "quantity_plan" for d in diagrams):
            raise SolutionContractError("submission_mode")
    elif outcome["status"] in ("inline_grid", "inline_geometry", "inline_rectangle_dissection", "inline_cube", "inline_triangle", "inline_hexagon", "inline_route"):
        if value["mode"] != "general":
            raise SolutionContractError("submission_mode")
        {"inline_grid": _validate_inline_grid_answer, "inline_geometry": _validate_inline_geometry_answer, "inline_rectangle_dissection": _validate_inline_rectangle_dissection_answer, "inline_cube": _validate_inline_cube_answer, "inline_triangle": _validate_inline_triangle_answer, "inline_hexagon": _validate_inline_hexagon_answer, "inline_route": _validate_inline_route_answer}[outcome["status"]](value["answer"])
        diagrams = []
    else:
        if outcome["status"] == "user_requested_text_only" and text_only_authorized is not True:
            raise SolutionContractError("submission_text_only_unauthorized")
        if value["mode"] == "native_recipe":
            raise SolutionContractError("submission_mode")
        diagrams = []
    if len(set(value["visual_method_ids"])) != len(value["visual_method_ids"]):
        raise SolutionContractError("submission_duplicate_id")
    answer = value["answer"]
    if not diagrams and outcome["status"] not in ("inline_grid", "inline_geometry", "inline_rectangle_dissection", "inline_cube", "inline_triangle", "inline_hexagon", "inline_route"):
        answer += "\n\n图解说明：" + outcome["reason"].strip()
    envelope = {"schemaVersion": 1, "mode": value["mode"], "method_id": value["method_id"],
                "visual_method_ids": value["visual_method_ids"], "answer": answer, "diagrams": diagrams}
    try:
        envelope_bytes = len(json.dumps(envelope, ensure_ascii=False).encode("utf-8"))
    except UnicodeError:
        raise SolutionContractError("submission_json") from None
    if len(answer) > 40_000 or envelope_bytes > MAX_BYTES:
        raise SolutionContractError("submission_size")
    return envelope


def normalize_arguments(raw, *, text_only_authorized=False, strict=False):
    try:
        return _normalize_arguments(raw, text_only_authorized=text_only_authorized, strict=strict)
    except SolutionContractError as error:
        if error.diagnostic is not None:
            error.diagnostic = {**error.diagnostic, "tool": TOOL_NAME}
        raise
