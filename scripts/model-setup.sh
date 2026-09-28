#!/usr/bin/env bash
set -Eeuo pipefail

source /opt/engramhalo/config/model-manifest.env
select_target_quant
umask 022

model_root=/models
target_dir="$model_root/$TARGET_DIR"
mtp_dir="$model_root/$MTP_DIR"

target_locals=()
for remote_path in "${TARGET_FILES[@]}"; do
  target_locals+=("$target_dir/${remote_path##*/}")
done
vision_local="$target_dir/$VISION_FILE"
mtp_local="$mtp_dir/$MTP_FILE"

vision_mode=${ENABLE_VISION:-false}
case "${vision_mode,,}" in
  1|true|yes)
    vision_enabled=true
    ;;
  0|false|no)
    vision_enabled=false
    ;;
  *)
    echo "Invalid ENABLE_VISION value: ${ENABLE_VISION:-} (use true or false)." >&2
    exit 2
    ;;
esac

core_ready_file="$model_root/.qwen3.8-flash-next-${TARGET_QUANT}-${TARGET_REVISION}-${MTP_REVISION}.ready"
vision_ready_file="$model_root/.qwen3.8-flash-next-${TARGET_REVISION}-vision.ready"

storage_uid=${MODEL_OWNER_UID:-1000}
storage_gid=${MODEL_OWNER_GID:-1000}
[[ "$storage_uid" =~ ^[0-9]+$ && "$storage_gid" =~ ^[0-9]+$ ]] || {
  echo "MODEL_OWNER_UID and MODEL_OWNER_GID must be numeric." >&2
  exit 2
}

prepare_storage() {
  mkdir -p "$target_dir" "$mtp_dir" /cache/huggingface
  chown -R "$storage_uid:$storage_gid" "$model_root" /cache/huggingface
}

prepare_storage

file_has_size() {
  [[ -f "$1" ]] && [[ "$(stat -c %s "$1")" == "$2" ]]
}

core_files_present() {
  local index
  for index in "${!target_locals[@]}"; do
    file_has_size "${target_locals[$index]}" "${TARGET_SIZES[$index]}" || return 1
  done
  file_has_size "$mtp_local" "$MTP_SIZE"
}

selected_files_present() {
  core_files_present \
    && { [[ "$vision_enabled" == false ]] || file_has_size "$vision_local" "$VISION_SIZE"; }
}

if [[ -f "$core_ready_file" ]] \
  && core_files_present \
  && { [[ "$vision_enabled" == false ]] || { [[ -f "$vision_ready_file" ]] && file_has_size "$vision_local" "$VISION_SIZE"; }; }; then
  prepare_storage
  echo "Pinned $TARGET_QUANT target model, MTP sidecar, and selected vision profile are ready."
  exit 0
fi

if selected_files_present && [[ "${VERIFY_DOWNLOADS:-true}" != "true" ]]; then
  touch "$core_ready_file"
  [[ "$vision_enabled" == true ]] && touch "$vision_ready_file"
  prepare_storage
  echo "Model files have the expected sizes; checksum verification was disabled."
  exit 0
fi

download_mode=${DOWNLOAD_MODEL:-ask}
profile_bytes=$MTP_SIZE
for size in "${TARGET_SIZES[@]}"; do
  profile_bytes=$((profile_bytes + size))
done
if [[ "$vision_enabled" == true ]]; then
  profile_bytes=$((profile_bytes + VISION_SIZE))
fi
full_profile_size=$(awk -v bytes="$profile_bytes" 'BEGIN { printf "%.1f GiB", bytes / 1073741824 }')
[[ "$vision_enabled" == true ]] && full_profile_size+=" including the optional 862.1 MiB projector"
case "${download_mode,,}" in
  1|true|yes)
    ;;
  ask)
    if [[ -t 0 ]]; then
      read -r -p "Required Qwen3.8-Flash-Next files are missing (full profile: $full_profile_size). Download them now? [y/N] " answer
      [[ "$answer" =~ ^[Yy]$ ]] || { echo "Download declined."; exit 1; }
    else
      echo "Required model files are missing and this start is non-interactive. Set DOWNLOAD_MODEL=true in .env to approve downloads (full profile: $full_profile_size), then run docker compose up -d again." >&2
      exit 1
    fi
    ;;
  0|false|no)
    echo "Model is missing. Set DOWNLOAD_MODEL=true in .env, or run: docker compose run --rm -it -e DOWNLOAD_MODEL=ask model-setup" >&2
    exit 1
    ;;
  *)
    echo "Invalid DOWNLOAD_MODEL value: $download_mode (use true, false, or ask)." >&2
    exit 2
    ;;
esac

download_items=(
  "$mtp_local:$MTP_SIZE"
)
for index in "${!target_locals[@]}"; do
  download_items+=("${target_locals[$index]}:${TARGET_SIZES[$index]}")
done
if [[ "$vision_enabled" == true ]]; then
  download_items+=("$vision_local:$VISION_SIZE")
fi

remaining_bytes=0
for item in "${download_items[@]}"; do
  destination=${item%:*}
  expected_size=${item##*:}
  if [[ -f "$destination" ]]; then
    current_size=$(stat -c %s "$destination")
  elif [[ -f "${destination}.part" ]]; then
    current_size=$(stat -c %s "${destination}.part")
  else
    current_size=0
  fi
  (( current_size > expected_size )) && current_size=0
  remaining_bytes=$((remaining_bytes + expected_size - current_size))
done

required_bytes=$((remaining_bytes + 2147483648))
available_bytes=$(df -PB1 "$model_root" | awk 'NR == 2 { print $4 }')
if (( available_bytes < required_bytes )); then
  echo "Not enough free disk space in the models volume. Need about $(((required_bytes + 1073741823) / 1073741824)) GiB for the remaining download and safety margin; have $((available_bytes / 1073741824)) GiB." >&2
  exit 1
fi

download_file() {
  local repo=$1 revision=$2 remote_path=$3 destination=$4 expected_size=$5 expected_sha=$6
  local partial="${destination}.part"
  local url="https://huggingface.co/${repo}/resolve/${revision}/${remote_path}"
  local -a headers=()

  if file_has_size "$destination" "$expected_size"; then
    echo "Found ${destination##*/}; verifying it."
  else
    [[ -n "${HF_TOKEN:-}" ]] && headers=(-H "Authorization: Bearer $HF_TOKEN")
    echo "Downloading ${remote_path} ..."
    curl --fail --location --show-error --retry 8 --retry-all-errors \
      --continue-at - --output "$partial" "${headers[@]}" "$url"
    actual_size=$(stat -c %s "$partial")
    [[ "$actual_size" == "$expected_size" ]] || {
      echo "Size mismatch for ${remote_path}: expected $expected_size, got $actual_size." >&2
      exit 1
    }
    mv "$partial" "$destination"
  fi

  if [[ "${VERIFY_DOWNLOADS:-true}" == "true" ]]; then
    echo "$expected_sha  $destination" | sha256sum --check --status || {
      echo "SHA-256 verification failed for ${destination##*/}. Remove it and retry." >&2
      exit 1
    }
  fi
}

if [[ -f "$core_ready_file" ]] && core_files_present; then
  echo "Reusing the verified target model and MTP sidecar."
else
  for index in "${!target_locals[@]}"; do
    download_file "$TARGET_REPO" "$TARGET_REVISION" "${TARGET_FILES[$index]}" \
      "${target_locals[$index]}" "${TARGET_SIZES[$index]}" "${TARGET_SHA256S[$index]}"
  done
  download_file "$MTP_REPO" "$MTP_REVISION" "$MTP_FILE" "$mtp_local" "$MTP_SIZE" "$MTP_SHA256"
  touch "$core_ready_file"
fi
if [[ "$vision_enabled" == true ]]; then
  if [[ -f "$vision_ready_file" ]] && file_has_size "$vision_local" "$VISION_SIZE"; then
    echo "Reusing the verified multimodal projector."
  else
    download_file "$TARGET_REPO" "$TARGET_REVISION" "$VISION_FILE" "$vision_local" "$VISION_SIZE" "$VISION_SHA256"
    touch "$vision_ready_file"
  fi
fi

prepare_storage
echo "$TARGET_QUANT model download and verification complete."
