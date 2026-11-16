#!/bin/bash
# Release IPA → полка IPA на старом Маке (ipa-shelf publish). See IPA_RELEASE.md.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/tools/ipa-release.py" --project-root "$ROOT" --scheme LoriLocal --derived-data build/ipa "$@"
