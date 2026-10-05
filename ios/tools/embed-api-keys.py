#!/usr/bin/env python3
"""Embed personal API keys without putting their values in build arguments or logs."""

import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile


ACCOUNTS = {
    "openAI": "openai-api-key",
    "gemini": "gemini-api-key",
    "elevenLabs": "elevenlabs-api-key",
}

# Чат «Спроси свой архив» удалён 5 октября 2026, а в личном
# Secrets/APIKeys.local.json владельца поле `assistant` осталось. Неизвестное
# поле останавливает сборку, поэтому старое имя принимается и пропускается:
# ломать личную сборку из-за ключа, которым приложение больше не пользуется,
# незачем, а встраивать его в IPA — тем более.
LEGACY_FIELDS = {"assistant"}


def embed(env):
    destination = (
        Path(env["TARGET_BUILD_DIR"])
        / env["UNLOCALIZED_RESOURCES_FOLDER_PATH"]
        / "PrivateAPIKeys.plist"
    )
    # При повторной сборке прежний секрет не должен остаться в QA/симуляторе
    # или в сборке, для которой локальный файл уже удалён.
    destination.unlink(missing_ok=True)
    if (
        env.get("PLATFORM_NAME") != "iphoneos"
        or env.get("CONFIGURATION") == "QA"
        or env.get("PRODUCT_BUNDLE_IDENTIFIER") != "ru.ilyaqa.lori.local"
    ):
        return
    source = Path(env["SRCROOT"]) / "Secrets/APIKeys.local.json"
    if not source.exists():
        return
    try:
        values = json.loads(source.read_text())
        if not isinstance(values, dict) or set(values) - set(ACCOUNTS) - LEGACY_FIELDS:
            raise ValueError()
        # Формат проверяется и у старого поля: число вместо строки — признак
        # испорченного файла, а не повод молча продолжить.
        if any(not isinstance(value, str) for value in values.values()):
            raise ValueError()
        keys = {
            ACCOUNTS[name]: value.strip()
            for name, value in values.items()
            if name in ACCOUNTS and value.strip()
        }
    except (ValueError, OSError):
        # JSONDecodeError может содержать исходную строку: наружу только
        # фиксированное сообщение, без значения ключа или текста исключения.
        raise ValueError(
            "Проверьте формат Secrets/APIKeys.local.json; значения не выводятся."
        ) from None
    if not keys:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".api-keys-", dir=destination.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            plistlib.dump(keys, output, fmt=plistlib.FMT_BINARY)
        os.replace(temporary, destination)
    finally:
        Path(temporary).unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        embed(os.environ)
    except Exception:
        print(
            "error: Не удалось встроить личные ключи. Проверьте Secrets/APIKeys.local.json и каталог сборки.",
            file=sys.stderr,
        )
        sys.exit(1)
