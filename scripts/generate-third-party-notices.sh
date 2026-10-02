#!/usr/bin/env bash
# Writes THIRD_PARTY_NOTICES.md: the license and NOTICE text of every Swift package in
# Package.resolved, plus the bundled models. The app ships this file in its Resources.
# Run after package versions change (needs resolved checkouts in build.noindex/).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKOUTS="${CHECKOUTS:-$ROOT/build.noindex/SourcePackages/checkouts}"
RESOLVED="$ROOT/Voiceling.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
OUT="$ROOT/THIRD_PARTY_NOTICES.md"

[ -d "$CHECKOUTS" ] || { echo "error: no package checkouts at $CHECKOUTS; build once first" >&2; exit 1; }

{
    echo "# Third-party notices"
    echo
    echo "Voiceling includes the open-source software and models below. Each is used under its"
    echo "own license, reproduced here. Voiceling's own attributions are in NOTICE."
    python3 - "$RESOLVED" <<'PY' | while IFS=$'\t' read -r name url version; do
import json, sys
for pin in json.load(open(sys.argv[1]))["pins"]:
    print(f'{pin["location"].rstrip("/").removesuffix(".git").rsplit("/", 1)[1]}\t{pin["location"]}\t{pin["state"].get("version", pin["state"].get("revision", "")[:12])}')
PY
        dir="$CHECKOUTS/$name"
        license="$(ls "$dir" 2>/dev/null | grep -i -E '^(license|license|copying)' | head -1 || true)"
        [ -n "$license" ] || { echo "error: no license file for $name" >&2; exit 1; }
        echo
        echo "## $name $version"
        echo
        echo "$url"
        echo
        echo '```'
        cat "$dir/$license"
        echo '```'
        if [ -f "$dir/NOTICE.txt" ]; then
            echo
            echo "NOTICE:"
            echo
            echo '```'
            cat "$dir/NOTICE.txt"
            echo '```'
        fi
    done
    echo
    echo "## Silero VAD (voice activity model, Core ML conversion by FluidInference)"
    echo
    echo "https://github.com/snakers4/silero-vad"
    echo
    echo '```'
    cat "$ROOT/licenses/silero-vad-LICENSE.txt"
    echo '```'
    echo
    echo "## NVIDIA Parakeet TDT 0.6B v2 (speech model, Core ML conversion by FluidInference)"
    echo
    echo "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2 · https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml"
    echo
    echo "Licensed under Creative Commons Attribution 4.0 International: https://creativecommons.org/licenses/by/4.0/"
    echo
    echo "## Qwen2.5-1.5B-Instruct (optional Polish model, downloaded on demand)"
    echo
    echo "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct · MLX 4-bit conversion: https://huggingface.co/mlx-community/Qwen2.5-1.5B-Instruct-4bit"
    echo
    echo "Licensed under the Apache License 2.0 (text in LICENSE)."
} > "$OUT"
echo "wrote $OUT ($(grep -c '^## ' "$OUT") entries)"
