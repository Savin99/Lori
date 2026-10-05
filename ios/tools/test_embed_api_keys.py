import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "embed_keys", Path(__file__).with_name("embed-api-keys.py")
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class EmbedKeysTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "Secrets").mkdir()
        self.source = self.root / "Secrets/APIKeys.local.json"
        self.source.write_text(
            json.dumps({"elevenLabs": " fixture-eleven ", "openAI": "fixture-openai"})
        )
        self.destination = self.root / "products/Lori.app/PrivateAPIKeys.plist"
        self.env = dict(
            SRCROOT=str(self.root),
            TARGET_BUILD_DIR=str(self.root / "products"),
            UNLOCALIZED_RESOURCES_FOLDER_PATH="Lori.app",
            PLATFORM_NAME="iphoneos",
            CONFIGURATION="Release",
            PRODUCT_BUNDLE_IDENTIFIER="ru.ilyaqa.lori.local",
        )

    def test_device_build_embeds_separate_accounts(self):
        module.embed(self.env)
        self.assertEqual(
            plistlib.loads(self.destination.read_bytes()),
            {
                "elevenlabs-api-key": "fixture-eleven",
                "openai-api-key": "fixture-openai",
            },
        )

    def test_legacy_assistant_field_is_accepted_but_not_embedded(self):
        # Так выглядит личный файл владельца после удаления чата «Спроси свой
        # архив»: поле assistant осталось и не должно ни ломать сборку, ни
        # попадать в IPA.
        self.source.write_text(
            json.dumps({"elevenLabs": "fixture-eleven", "assistant": "fixture-chat"})
        )
        module.embed(self.env)
        embedded = self.destination.read_bytes()
        self.assertEqual(
            plistlib.loads(embedded), {"elevenlabs-api-key": "fixture-eleven"}
        )
        self.assertNotIn(b"fixture-chat", embedded)

    def test_only_legacy_field_leaves_no_resource(self):
        # Ресурс прошлой сборки мог ещё нести ключ ассистента: он удаляется, а
        # новый из одного старого поля не создаётся.
        module.embed(self.env)
        self.source.write_text(json.dumps({"assistant": "fixture-chat"}))
        module.embed(self.env)
        self.assertFalse(self.destination.exists())

    def test_qa_simulator_and_other_bundle_remove_stale_resource(self):
        for field, value in [
            ("CONFIGURATION", "QA"),
            ("PLATFORM_NAME", "iphonesimulator"),
            ("PRODUCT_BUNDLE_IDENTIFIER", "ru.ilyaqa.lori.local.qa"),
        ]:
            with self.subTest(field=field):
                module.embed(self.env)
                module.embed(dict(self.env, **{field: value}))
                self.assertFalse(self.destination.exists())

    def test_removed_source_removes_previous_keys(self):
        module.embed(self.env)
        self.source.unlink()
        module.embed(self.env)
        self.assertFalse(self.destination.exists())

    def test_bad_source_fails_without_exposing_values_or_keeping_old_keys(self):
        for text in [
            '{"assistant": "fixture-secret",',
            '{"unexpected": "fixture-secret"}',
            '{"assistant": 42}',
        ]:
            with self.subTest(text=text):
                self.source.write_text(text)
                with self.assertRaises(ValueError) as failure:
                    module.embed(self.env)
                self.assertNotIn("fixture-secret", str(failure.exception))
                self.assertFalse(self.destination.exists())


if __name__ == "__main__":
    unittest.main()
