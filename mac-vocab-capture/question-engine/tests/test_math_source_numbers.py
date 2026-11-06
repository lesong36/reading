import unittest

from math_source_numbers import source_contains_number, source_has_numbers


class SourceNumberTests(unittest.TestCase):
    def test_actual_chinese_handbook_and_companion_sources(self):
        source = "每行十棵，种了五行。如果每行四棵，可以种多少行？"
        for value in ("10", "5", "4"):
            self.assertTrue(source_contains_number(source, value))
        self.assertFalse(source_contains_number(source, "50"))
        self.assertTrue(source_has_numbers(source))
        self.assertTrue(source_contains_number("正方形周围增加三层", "3"))

    def test_conventional_integer_and_decimal_spellings(self):
        cases = {"每行五棵": "5", "十二人": "12", "一十二人": "12", "两人": "2",
                 "两百米": "200", "二十一层": "21", "一百零二": "102",
                 "一千零一十": "1010", "十万零三十六": "100036",
                 "一万两千三百四十五": "12345", "九千九百九十九万九千九百九十九": "99999999",
                 "零米": "0", "〇米": "0", "负三点五度": "-3.5",
                 "三点〇五": "3.05", "零点一二五": "1/8"}
        for source, value in cases.items():
            with self.subTest(source=source):
                self.assertTrue(source_contains_number(source, value))
                self.assertTrue(source_has_numbers(source))

    def test_full_numeral_boundaries_reject_substrings(self):
        for source, value in (("三十六", "3"), ("三十六", "6"), ("十三", "3"),
                              ("负三点五", "3.5"), ("三点五", "3"), ("二十一", "1"),
                              ("一万零三", "3"), ("两百", "2")):
            with self.subTest(source=source, value=value):
                self.assertFalse(source_contains_number(source, value))

    def test_shorthand_malformed_and_mixed_tokens_are_not_partially_parsed(self):
        for source in ("一百二", "一千二", "十百", "三十十", "两十", "零零三", "二〇二六", "一亿", "三点", "三点两", "三点点五", "万一", "三３", "abc三", "三abc", "三分之一", "壹佰三十", "三千万亿"):
            with self.subTest(source=source):
                self.assertFalse(source_has_numbers(source))
                for value in ("0", "1", "2", "3", "5", "10", "12", "100", "120", "1000", "1200"):
                    self.assertFalse(source_contains_number(source, value))

    def test_ambiguous_compound_units_do_not_bind_thousands(self):
        for source in ("三千克", "两千米", "五千瓦"):
            with self.subTest(source=source):
                self.assertFalse(source_has_numbers(source))
                for value in ("2", "3", "5", "2000", "3000", "5000"):
                    self.assertFalse(source_contains_number(source, value))
        self.assertTrue(source_contains_number("三千人", "3000"))

    def test_exact_arabic_boundaries_and_historical_mode(self):
        for source, value in (("每人25张", "25"), ("余数-3", "-3"), ("3.5米", "3.5"), ("1/8米", "1/8"), ("5千克", "5"), ("3万元", "3"), ("三3", "3")):
            self.assertTrue(source_contains_number(source, value))
            self.assertTrue(source_contains_number(source, value, allow_chinese=False))
            self.assertTrue(source_has_numbers(source))
            self.assertTrue(source_has_numbers(source, allow_chinese=False))
        for source, value in (("125", "25"), ("3.5", "5"), ("-3", "3"), ("abc3", "3"), ("3abc", "3"), ("3.0", "3"), ("1/8", "8")):
            self.assertFalse(source_contains_number(source, value))
            self.assertFalse(source_contains_number(source, value, allow_chinese=False))
        self.assertFalse(source_contains_number("三层", "3", allow_chinese=False))
        self.assertFalse(source_has_numbers("三层", allow_chinese=False))
        self.assertTrue(source_contains_number("3万", "3", allow_chinese=False))

    def test_reject_invalid_values_nontext_and_oversize(self):
        for value in (None, 3, "3e0", "03", "1/0", "3+0", " 3"):
            self.assertFalse(source_contains_number("三", value))
        self.assertFalse(source_has_numbers(None))
        self.assertFalse(source_contains_number("三" * 65537, "3"))
        self.assertFalse(source_has_numbers("三" * 65537))

    def test_source_is_never_modified_or_computed(self):
        source = "十棵×五行"
        before = source
        self.assertFalse(source_contains_number(source, "50"))
        self.assertEqual(source, before)
        self.assertFalse(source_has_numbers("a1 example7 words"))


if __name__ == "__main__":
    unittest.main()
