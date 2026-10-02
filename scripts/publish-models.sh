#!/usr/bin/env bash
# Modified by Michael Wong for Voiceling, 2026; originally from Yaprflow (Apache-2.0). See NOTICE.
# Packages the two downloadable models and uploads them to the 'models-v1'
# GitHub Release (a pre-release, so /releases/latest stays the app DMG),
# which the app downloads from when a piece is missing:
#   parakeet-v2-encoder.tar.gz   Encoder.mlmodelc (~445MB) from
#                                FluidInference/parakeet-tdt-0.6b-v2-coreml
#                                (release builds bundle it; this is the fallback)
#   qwen25-1.5b-4bit-mlx.tar.gz  mlx-community/Qwen2.5-1.5B-Instruct-4bit,
#                                fetched when the user turns on Polish
# Usage: scripts/publish-models.sh <dir with the Qwen model files>
# (download it with: huggingface-cli download mlx-community/Qwen2.5-1.5B-Instruct-4bit --local-dir <dir>)

set -euo pipefail

REPO_SLUG="M1w234/voiceling"
MODELS_TAG="models-v1"
ENCODER_TARBALL="parakeet-v2-encoder.tar.gz"
GRAMMAR_TARBALL="qwen25-1.5b-4bit-mlx.tar.gz"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENCODER_SRC="$ROOT/Models/parakeet-tdt-0.6b-v2"
GRAMMAR_SRC="${1:?usage: $0 <qwen model dir>}"
STAGE="$(mktemp -d -t voiceling-models.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
export COPYFILE_DISABLE=1   # keep macOS ._ metadata files out of the tarballs

if [ ! -d "$ENCODER_SRC/Encoder.mlmodelc" ]; then
    echo "error: $ENCODER_SRC/Encoder.mlmodelc not found. Run scripts/fetch-models.sh first." >&2
    exit 1
fi
if [ ! -f "$GRAMMAR_SRC/model.safetensors" ]; then
    echo "error: $GRAMMAR_SRC/model.safetensors not found." >&2
    exit 1
fi
if ! command -v gh >/dev/null 2>&1; then
    echo "error: 'gh' CLI not installed. brew install gh" >&2
    exit 1
fi

# Each tarball carries its model's license terms next to the files.
mkdir -p "$STAGE/encoder-extra" "$STAGE/grammar-extra"
cat > "$STAGE/encoder-extra/NOTICE" <<'NOTE'
Encoder.mlmodelc is part of NVIDIA Parakeet TDT 0.6B v2
(https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2), converted to Core ML by
FluidInference (https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml).
Licensed under Creative Commons Attribution 4.0 International:
https://creativecommons.org/licenses/by/4.0/
Unmodified; repackaged as a tarball for Voiceling.
NOTE
cp "$ROOT/LICENSE" "$STAGE/grammar-extra/LICENSE"
cat > "$STAGE/grammar-extra/NOTICE" <<'NOTE'
Qwen2.5-1.5B-Instruct by the Qwen team (Alibaba Cloud)
(https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct), in the 4-bit MLX conversion
by mlx-community (https://huggingface.co/mlx-community/Qwen2.5-1.5B-Instruct-4bit).
Licensed under the Apache License 2.0 (see LICENSE).
Unmodified; repackaged as a tarball for Voiceling.
NOTE

echo "Packaging encoder → $ENCODER_TARBALL ..."
tar czf "$STAGE/$ENCODER_TARBALL" -C "$ENCODER_SRC" "Encoder.mlmodelc" -C "$STAGE/encoder-extra" NOTICE
# GrammarController extracts with --strip-components=1, so entries are ./<file>.
echo "Packaging grammar model → $GRAMMAR_TARBALL ..."
tar czf "$STAGE/$GRAMMAR_TARBALL" --exclude ./.cache -C "$GRAMMAR_SRC" . -C "$STAGE/grammar-extra" .
ls -lh "$STAGE"/*.tar.gz
SUMS="$(cd "$STAGE" && shasum -a 256 ./*.tar.gz | sed 's|  \./|  |')"

NOTES="Model files Voiceling downloads when they are not already in the app.

- \`$ENCODER_TARBALL\`: Encoder.mlmodelc from [FluidInference/parakeet-tdt-0.6b-v2-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml), a Core ML conversion of [NVIDIA Parakeet TDT 0.6B v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2). License: CC BY 4.0.
- \`$GRAMMAR_TARBALL\`: [mlx-community/Qwen2.5-1.5B-Instruct-4bit](https://huggingface.co/mlx-community/Qwen2.5-1.5B-Instruct-4bit), an MLX conversion of [Qwen2.5-1.5B-Instruct](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct) by the Qwen team. License: Apache 2.0.

Files are unmodified and repackaged as tarballs, each with its license notice.

SHA-256:
\`\`\`
$SUMS
\`\`\`"

if gh release view "$MODELS_TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
    echo "Uploading to existing release ${MODELS_TAG}..."
    gh release upload "$MODELS_TAG" "$STAGE/$ENCODER_TARBALL" "$STAGE/$GRAMMAR_TARBALL" \
        --repo "$REPO_SLUG" --clobber
    gh release edit "$MODELS_TAG" --repo "$REPO_SLUG" --notes "$NOTES" --prerelease
else
    echo "Creating release ${MODELS_TAG}..."
    gh release create "$MODELS_TAG" "$STAGE/$ENCODER_TARBALL" "$STAGE/$GRAMMAR_TARBALL" \
        --repo "$REPO_SLUG" \
        --title "Models v1" \
        --prerelease \
        --notes "$NOTES"
fi

echo "$SUMS"
echo "Done."
