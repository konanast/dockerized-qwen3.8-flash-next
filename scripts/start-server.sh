#!/usr/bin/env bash
set -Eeuo pipefail

source /opt/engramhalo/config/model-manifest.env
select_target_quant

target_model="/models/$TARGET_DIR/${TARGET_FILES[0]##*/}"
draft_model="/models/$MTP_DIR/$MTP_FILE"
vision_model="/models/$TARGET_DIR/$VISION_FILE"

[[ -r "$target_model" ]] || { echo "Target model is missing: $target_model" >&2; exit 1; }
[[ -r "$draft_model" ]] || { echo "MTP sidecar is missing: $draft_model" >&2; exit 1; }
[[ -e /dev/kfd && -d /dev/dri ]] || { echo "AMD GPU devices /dev/kfd and /dev/dri are required." >&2; exit 1; }

performance_profile=${PERFORMANCE_PROFILE:-balanced}
case "${performance_profile,,}" in
  balanced)
    context_size=${CONTEXT_SIZE:-65536}
    load_mode=mmap
    lazy_mode=on
    ;;
  dedicated)
    context_size=${DEDICATED_CONTEXT_SIZE:-32768}
    load_mode=none
    lazy_mode=off
    ;;
  *)
    echo "Invalid PERFORMANCE_PROFILE value: $performance_profile (use balanced or dedicated)." >&2
    exit 2
    ;;
esac

parallel_slots=${PARALLEL_SLOTS:-1}
if (( parallel_slots != 1 )); then
  echo "EngramHalo MTP is validated only with PARALLEL_SLOTS=1." >&2
  exit 2
fi
if (( context_size > 163840 )); then
  echo "CONTEXT_SIZE exceeds the EngramHalo MTP validation limit of 163840." >&2
  exit 2
fi

args=(
  --model "$target_model"
  --model-draft "$draft_model"
  --host 0.0.0.0
  --port 8080
  --alias "${MODEL_ALIAS:-qwen3.8-flash-next}"
  --ctx-size "$context_size"
  --batch-size "${BATCH_SIZE:-8192}"
  --ubatch-size "${UBATCH_SIZE:-2048}"
  --threads "${CPU_THREADS:-4}"
  --parallel "$parallel_slots"
  --n-gpu-layers "${GPU_LAYERS:-999}"
  --flash-attn on
  --cache-type-k "${KV_CACHE_TYPE:-q8_0}"
  --cache-type-v "${KV_CACHE_TYPE:-q8_0}"
  --load-mode "$load_mode"
  --lazy-mode "$lazy_mode"
  --jinja
  --no-webui
  --spec-type draft-mtp,ngram-mod
  --spec-draft-n-max "${SPEC_DRAFT_N_MAX:-4}"
  --spec-draft-p-min "${SPEC_DRAFT_P_MIN:-0.75}"
)

api_key=${API_KEY:-}
case "$api_key" in
  ""|replace-with-a-long-random-secret)
    echo "API_KEY is missing or still uses the public example value." >&2
    echo "Run ./scripts/init-env.sh or set a strong, unique API_KEY in .env." >&2
    exit 2
    ;;
esac

# Avoid exposing the key in the llama-server process command line. The source
# value remains in the container environment because this deployment is
# intentionally configured from the local, Git-ignored .env file.
umask 077
api_key_file=$(mktemp /tmp/engramhalo-api-key.XXXXXX)
printf '%s\n' "$api_key" > "$api_key_file"
args+=(--api-key-file "$api_key_file")

vision_mode=${ENABLE_VISION:-false}
case "${vision_mode,,}" in
  1|true|yes)
    [[ -r "$vision_model" ]] || { echo "Vision is enabled but the multimodal projector is missing: $vision_model" >&2; exit 1; }
    args+=(--mmproj "$vision_model" --mmproj-offload)
    ;;
  0|false|no)
    ;;
  *)
    echo "Invalid ENABLE_VISION value: ${ENABLE_VISION:-} (use true or false)." >&2
    exit 2
    ;;
esac

export ROCBLAS_USE_HIPBLASLT=1
export LLAMA_MMAP_DROP_BEHIND=2

echo "Starting MODEL_QUANT=$TARGET_QUANT, PERFORMANCE_PROFILE=${performance_profile,,}: load_mode=$load_mode, lazy_mode=$lazy_mode, context=$context_size"
exec llama-server "${args[@]}"
