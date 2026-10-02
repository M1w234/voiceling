#!/usr/bin/env bash
# Modified by Michael Wong for Voiceling, 2026; originally from Yaprflow (Apache-2.0). See NOTICE.
# Fetches the Parakeet TDT 0.6B v2 Core ML model into ./Models/.
# Run once after cloning the repo.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Models/parakeet-tdt-0.6b-v2"
VAD_DEST="$ROOT/Models/silero-vad"
VAD_MODEL="silero-vad-unified-256ms-v6.0.0.mlmodelc"

PARAKEET_READY=false
VAD_READY=false
if [[ -f "$DEST/parakeet_vocab.json" && -d "$DEST/Encoder.mlmodelc" ]]; then
    PARAKEET_READY=true
fi
if [[ -d "$VAD_DEST/$VAD_MODEL" ]]; then
    VAD_READY=true
fi

if [[ "$PARAKEET_READY" == true && "$VAD_READY" == true ]]; then
    echo "Speech and voice-detection models are already present under $ROOT/Models"
    exit 0
fi

mkdir -p "$ROOT/Models"

if command -v huggingface-cli >/dev/null 2>&1; then
    HF_CLI=(huggingface-cli)
elif command -v hf >/dev/null 2>&1 && hf --help 2>&1 | grep -qi "hugging face"; then
    # Newer releases of huggingface_hub renamed the CLI to `hf`. Verify it is
    # actually Hugging Face: on this Mac, `hf` is also used by Higgsfield.
    HF_CLI=(hf)
else
    echo "error: Hugging Face CLI not installed." >&2
    echo "       Install it with: python3 -m pip install --user huggingface_hub" >&2
    exit 1
fi

# Bypass HF's 'xet' CDN (cas-bridge.xethub.hf.co), which is unreachable on
# some networks (Errno 65 'No route to host'). Forces the standard LFS path.
export HF_HUB_DISABLE_XET=1

if [[ "$PARAKEET_READY" != true ]]; then
    "${HF_CLI[@]}" download "FluidInference/parakeet-tdt-0.6b-v2-coreml" \
        --include "Preprocessor.mlmodelc/*" \
                  "Encoder.mlmodelc/*" \
                  "Decoder.mlmodelc/*" \
                  "JointDecision.mlmodelc/*" \
                  "parakeet_vocab.json" \
        --local-dir "$DEST"
    rm -rf "$DEST/.cache"
fi

if [[ "$VAD_READY" != true ]]; then
    "${HF_CLI[@]}" download "FluidInference/silero-vad-coreml" \
        --include "$VAD_MODEL/*" \
        --local-dir "$VAD_DEST"
    rm -rf "$VAD_DEST/.cache"
fi

echo "Done:"
du -sh "$DEST" "$VAD_DEST"
