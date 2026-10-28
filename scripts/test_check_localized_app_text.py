#!/usr/bin/env python3

import unittest
from pathlib import Path

from check_localized_app_text import (
    SwiftParseError,
    catalog_keys,
    catalog_spanish_keys,
    check_calls,
    find_calls,
    parse_string_literal,
)


SOURCE = Path("Example.swift")


def calls(swift):
    return find_calls(SOURCE, swift)


class StringLiteralTests(unittest.TestCase):
    def test_reads_escapes_and_interpolations(self):
        literal, end = parse_string_literal('"Say \\"hi\\" to \\(user.name(for: "x")) \\u{2026}" + rest', 0)
        self.assertEqual(literal.text, 'Say "hi" to  …')
        self.assertEqual(literal.interpolations, ['user.name(for: "x")'])
        self.assertTrue(literal.is_interpolated)
        self.assertEqual(end, len('"Say \\"hi\\" to \\(user.name(for: "x")) \\u{2026}"'))

    def test_reads_raw_and_multiline_literals(self):
        raw, _ = parse_string_literal('#"C:\\path \\#(value)"#', 0)
        self.assertEqual(raw.text, "C:\\path ")
        self.assertEqual(raw.interpolations, ["value"])

        multiline, _ = parse_string_literal('"""\n        First\n          Second\n        """', 0)
        self.assertEqual(multiline.text, "First\n  Second")

    def test_rejects_unterminated_literals(self):
        with self.assertRaises(SwiftParseError):
            parse_string_literal('"never closed', 0)


class FindCallsTests(unittest.TestCase):
    def test_finds_calls_with_their_arguments(self):
        found = calls(
            'let a = localizedAppText("Save", de: "Sichern")\n'
            'let b = localizedAppText(\n'
            '    "More Models (\\(count))",\n'
            '    de: "Weitere Modelle (\\(count))",\n'
            '    es: "Más modelos (\\(count))"\n'
            ')\n'
        )
        self.assertEqual([call.line for call in found], [1, 2])
        self.assertEqual(found[0].english.text, "Save")
        self.assertEqual(sorted(found[1].arguments), ["de", "es"])
        self.assertEqual(found[1].arguments["es"].interpolations, ["count"])

    def test_finds_calls_nested_in_interpolations_but_not_in_comments_or_text(self):
        found = calls(
            '// localizedAppText("Commented", de: "x")\n'
            '/* localizedAppText("Block", de: "x") */\n'
            'let text = "localizedAppText(\\"Text\\", de: \\"x\\")"\n'
            'let list = localizedAppText("the apps \\(names.joined(separator: localizedAppText("and", de: "und")))", de: "die Apps")\n'
            'func localizedAppText(_ english: String, de german: String) -> String { english }\n'
        )
        self.assertEqual(
            sorted(call.english.text for call in found),
            ["and", "the apps "],
        )

    def test_marks_non_literal_english_text(self):
        found = calls('let a = localizedAppText(title, de: "Titel")\n')
        self.assertIsNone(found[0].english)


class CheckCallsTests(unittest.TestCase):
    def setUp(self):
        self.spanish_keys = catalog_spanish_keys({"strings": {
            "Save": {"localizations": {"es": {"stringUnit": {"state": "translated", "value": "Guardar"}}}},
            "Open": {"localizations": {"es": {"stringUnit": {"state": "translated", "value": ""}}}},
            "%lld words": {"localizations": {"es": {"variations": {"plural": {}}}}},
        }})

    def test_reads_spanish_keys_from_the_catalog(self):
        self.assertEqual(self.spanish_keys, {"Save", "%lld words"})

    def test_plain_text_needs_a_catalog_value_or_inline_spanish(self):
        problems = check_calls(calls(
            'localizedAppText("Save", de: "Sichern")\n'
            'localizedAppText("Open", de: "Öffnen")\n'
            'localizedAppText("Close", de: "Schließen", es: "Cerrar")\n'
        ), self.spanish_keys)
        self.assertEqual(len(problems), 1)
        self.assertIn("'Open'", problems[0])

    def test_interpolated_text_needs_inline_spanish_with_the_same_values(self):
        problems = check_calls(calls(
            'localizedAppText("Hi \\(name)", de: "Hallo \\(name)")\n'
            'localizedAppText("Hi \\(name)", de: "Hallo \\(name)", es: "Hola \\(otherName)")\n'
            'localizedAppText("Hi \\(name)", de: "Hallo \\(name)", es: "Hola \\( name )")\n'
        ), self.spanish_keys)
        self.assertEqual(len(problems), 2)
        self.assertIn("Example.swift:1", problems[0])
        self.assertIn("needs an inline `es:`", problems[0])
        self.assertIn("Example.swift:2", problems[1])

    def test_inline_spanish_must_be_a_literal_and_non_empty(self):
        problems = check_calls(calls(
            'localizedAppText("Save", de: "Sichern", es: spanishSave)\n'
            'localizedAppText("Save", de: "Sichern", es: "")\n'
            'localizedAppText(title, de: "Titel")\n'
        ), self.spanish_keys)
        self.assertEqual(len(problems), 3)

    def test_traditional_chinese_uses_its_own_label_and_catalog_locale(self):
        catalog = {"strings": {
            "Save": {"localizations": {"zh-Hant": {"stringUnit": {"state": "translated", "value": "儲存"}}}},
            "Open": {"localizations": {"zh-Hans": {"stringUnit": {"state": "translated", "value": "打开"}}}},
        }}
        traditional_keys = catalog_keys(catalog, "zh-Hant")
        self.assertEqual(traditional_keys, {"Save"})
        problems = check_calls(calls(
            'localizedAppText("Save", de: "Sichern")\n'
            'localizedAppText("Open", de: "Öffnen", zh: "打开")\n'
            'localizedAppText("Hi \\(name)", de: "Hallo \\(name)", zhHant: "你好，\\(name)")\n'
            'localizedAppText("Hi \\(name)", de: "Hallo \\(name)", es: "Hola \\(name)")\n'
        ), traditional_keys, "zhHant", "zh-Hant")
        self.assertEqual(len(problems), 2)
        self.assertIn("no zh-Hant value", problems[0])
        self.assertIn("'Open'", problems[0])
        self.assertIn("Example.swift:4", problems[1])
        self.assertIn("needs an inline `zhHant:`", problems[1])


if __name__ == "__main__":
    unittest.main()
