"""Literal numeric citation consistency, not semantic or image authentication.

Chinese words are parsed only as complete, conventionally written number tokens.
No source text is rewritten and no arithmetic or colloquial shorthand is inferred.
"""
from fractions import Fraction
import re


_VALUE = re.compile(r"-?(?:0|[1-9][0-9]{0,11})(?:\.[0-9]{1,12}|/[1-9][0-9]{0,11})?\Z")
_ARABIC = re.compile(r"(?<![A-Za-z0-9./-])-?(?:0|[1-9][0-9]{0,11})(?:\.[0-9]{1,12}|/[1-9][0-9]{0,11})?(?![A-Za-z0-9./])")
_CHINESE = re.compile(r"[负零〇一二两三四五六七八九十百千万点亿億兆壹贰叁肆伍陆柒捌玖拾佰仟]+")
_DIGITS = {char: index for index, char in enumerate("零一二三四五六七八九")}
_DIGITS.update({"〇": 0, "两": 2})
_MAX_TEXT = 65536


def _section_spelling(number):
    result = ""
    pending_zero = False
    for place, unit in ((1000, "千"), (100, "百"), (10, "十"), (1, "")):
        digit, number = divmod(number, place)
        if digit:
            if pending_zero:
                result += "零"
            result += "零一二三四五六七八九"[digit] + unit
            pending_zero = False
        elif result and number:
            pending_zero = True
    return result


def _integer_spelling(number):
    if number == 0:
        return "零"
    high, low = divmod(number, 10000)
    result = _section_spelling(high) + "万" if high else ""
    if high and 0 < low < 1000:
        result += "零"
    result += _section_spelling(low)
    return result[1:] if result.startswith("一十") else result


def _parse_integer(token):
    if not token or len(token) > 24 or token.count("万") > 1:
        return None
    # 两 is accepted as a standalone count or before a magnitude, not 两十.
    if token != "两" and re.search(r"两(?![百千万])", token):
        return None
    normalized = token.replace("两", "二").replace("〇", "零")
    total = section = digit = 0
    for char in normalized:
        if char in _DIGITS:
            digit = _DIGITS[char]
        elif char in "十百千":
            section += (digit or 1) * {"十": 10, "百": 100, "千": 1000}[char]
            digit = 0
        elif char == "万":
            total += (section + digit) * 10000
            section = digit = 0
        else:
            return None
    number = total + section + digit
    if number >= 100000000:
        return None
    # Canonical round-trip rejects 一百二, descending-order errors, digit strings,
    # redundant zeros and malformed forms instead of finding a valid substring.
    canonical = _integer_spelling(number)
    if normalized not in (canonical, "一" + canonical if canonical.startswith("十") else canonical):
        return None
    return number


def _parse_chinese(token):
    if len(token) > 40:
        return None
    negative = token.startswith("负")
    token = token[1:] if negative else token
    if token.count("点") > 1:
        return None
    integer, separator, decimals = token.partition("点")
    number = _parse_integer(integer)
    if number is None:
        return None
    value = Fraction(number)
    if separator:
        if not 1 <= len(decimals) <= 12 or any(char not in _DIGITS or char == "两" for char in decimals):
            return None
        digits = "".join(str(_DIGITS[char]) for char in decimals)
        value += Fraction(int(digits), 10 ** len(digits))
    return -value if negative else value


def _chinese_values(text):
    for match in _CHINESE.finditer(text):
        start, end = match.span()
        # A malformed mixed numeral is rejected whole; English identifiers and
        # adjacent Arabic number fragments do not become Chinese source inputs.
        if (start and (text[start - 1].isdecimal() or (text[start - 1].isascii() and (text[start - 1].isalnum() or text[start - 1] in "./-")))) or (end < len(text) and (text[end].isdecimal() or (text[end].isascii() and (text[end].isalnum() or text[end] in "./")))):
            continue
        if text[max(0, start - 2):start] == "分之" or text[end:end + 2] == "分之":
            continue
        # 千米/千克/千瓦 can be a compound unit, or a thousand expressed with a
        # simple unit. Refuse the ambiguous citation rather than bind 3 as 3000.
        if match.group().endswith("千") and text[end:end + 1] in ("米", "克", "瓦"):
            continue
        value = _parse_chinese(match.group())
        if value is not None:
            yield value


def source_contains_number(excerpt, value, *, allow_chinese=True):
    """Whether a canonical value occurs literally in an unchanged citation."""
    if not isinstance(excerpt, str) or len(excerpt) > _MAX_TEXT or not isinstance(value, str) or not _VALUE.fullmatch(value):
        return False
    # Retain the established Arabic boundary contract even beside Chinese units
    # (5千克, 3万元). Chinese parsing adds support; it does not narrow that path.
    if re.search(r"(?<![A-Za-z0-9./-])" + re.escape(value) + r"(?![A-Za-z0-9./])", excerpt):
        return True
    if not allow_chinese:
        return False
    try:
        expected = Fraction(value)
    except (ValueError, ZeroDivisionError):
        return False
    return any(number == expected for number in _chinese_values(excerpt))


def source_has_numbers(text, *, allow_chinese=True):
    """Conservatively detect supported literal numeric source tokens."""
    if not isinstance(text, str) or len(text) > _MAX_TEXT:
        return False
    if _ARABIC.search(text):
        return True
    return allow_chinese and next(_chinese_values(text), None) is not None
