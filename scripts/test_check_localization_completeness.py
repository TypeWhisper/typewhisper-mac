#!/usr/bin/env python3

import unittest

from check_localization_completeness import check_catalog, format_specifiers


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def plural(**forms):
    return {"variations": {"plural": {category: unit(value) for category, value in forms.items()}}}


def catalog(**entries):
    return {"sourceLanguage": "en", "strings": entries, "version": "1.0"}


class FormatSpecifierTests(unittest.TestCase):
    def test_reads_foundation_specifiers(self):
        self.assertEqual(
            format_specifiers("%@ of %lld at %.1f%% (%2$@)"),
            {"@": 2, "lld": 1, "f": 1, "%": 1},
        )

    def test_prose_percent_signs_are_not_specifiers(self):
        self.assertEqual(format_specifiers("0% mutes completely"), {})
        self.assertEqual(format_specifiers("0% schaltet stumm"), {})


class CheckCatalogTests(unittest.TestCase):
    def test_complete_catalog_passes(self):
        missing, mismatches, checked = check_catalog(catalog(**{
            "Save": {"localizations": {"zh-Hans": unit("保存"), "zh-Hant": unit("儲存"), "es": unit("Guardar")}},
            "%lld words": {"localizations": {
                "en": plural(one="%lld word", other="%lld words"),
                "zh-Hans": unit("%lld 个词"),
                "zh-Hant": unit("%lld 個詞"),
                "es": plural(one="%lld palabra", other="%lld palabras"),
            }},
        }))
        self.assertEqual((missing, mismatches, checked), ([], [], 2))

    def test_reports_missing_and_empty_required_languages(self):
        missing, _, _ = check_catalog(catalog(**{
            "Save": {"localizations": {"zh-Hans": unit("保存"), "zh-Hant": unit("儲存")}},
            "Open": {"localizations": {"zh-Hans": unit("打开"), "zh-Hant": unit("開啟"), "es": unit("")}},
            "Words": {"localizations": {
                "zh-Hans": unit("词"),
                "zh-Hant": unit(""),
                "es": {"variations": {"plural": {"one": unit("palabra"), "other": unit("")}}},
            }},
        }))
        self.assertEqual(missing, ["es: Save", "es: Open", "zh-Hant: Words", "es: Words"])

    def test_skips_empty_key_and_untranslatable_keys(self):
        missing, _, checked = check_catalog(catalog(**{
            "": {},
            "%lld": {"shouldTranslate": False},
        }))
        self.assertEqual((missing, checked), ([], 0))

    def test_reports_changed_or_dropped_specifiers_in_any_language(self):
        _, mismatches, _ = check_catalog(catalog(**{
            "Delete %@?": {"localizations": {
                "de": unit("%lld löschen?"),
                "zh-Hans": unit("删除 %@？"),
                "es": unit("¿Eliminar?"),
            }},
        }))
        self.assertEqual(len(mismatches), 2)
        self.assertTrue(mismatches[0].startswith("de: Delete %@?"))
        self.assertTrue(mismatches[1].startswith("es: Delete %@?"))

    def test_compares_with_the_english_localization_of_identifier_keys(self):
        _, mismatches, _ = check_catalog(catalog(**{
            "history.count": {"localizations": {
                "en": unit("%lld entries"),
                "zh-Hans": unit("%lld 个条目"),
                "es": unit("entradas"),
            }},
        }))
        self.assertEqual(len(mismatches), 1)
        self.assertIn("es: history.count", mismatches[0])

    def test_one_form_may_leave_out_the_number_but_other_may_not(self):
        source = {"en": plural(one="Synced 1 change.", other="Synced %lld changes.")}
        ok = check_catalog(catalog(**{"Synced %lld changes.": {"localizations": {
            **source,
            "zh-Hans": plural(one="已同步 %lld 项更改。", other="已同步 %lld 项更改。"),
            "zh-Hant": plural(one="已同步 %lld 項變更。", other="已同步 %lld 項變更。"),
            "es": plural(one="1 cambio sincronizado.", other="%lld cambios sincronizados."),
        }}}))
        self.assertEqual(ok[:2], ([], []))

        _, mismatches, _ = check_catalog(catalog(**{"Synced %lld changes.": {"localizations": {
            **source,
            "zh-Hans": unit("已同步 %lld 项更改。"),
            "es": plural(one="%@ cambio sincronizado.", other="cambios sincronizados."),
        }}}))
        self.assertEqual(len(mismatches), 2)


if __name__ == "__main__":
    unittest.main()
