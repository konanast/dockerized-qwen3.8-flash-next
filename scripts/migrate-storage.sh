#!/usr/bin/env bash
set -Eeuo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
env_file="$project_dir/.env"
source_model_volume=${SOURCE_MODEL_VOLUME:-engramhalo-models}
source_cache_volume=${SOURCE_CACHE_VOLUME:-engramhalo-hf-cache}
allow_merge=false

read_env_value() {
  local key=$1 value
  [[ -f "$env_file" ]] || return 1
  value=$(awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$env_file")
  value=${value#\"}
  value=${value%\"}
  value=${value#\'}
  value=${value%\'}
  [[ -n "$value" ]] || return 1
  printf '%s\n' "$value"
}

model_dir=${MODEL_DIR:-$(read_env_value MODEL_DIR || printf './models')}
cache_dir=${HF_CACHE_DIR:-$(read_env_value HF_CACHE_DIR || printf './cache/huggingface')}
owner_uid=${MODEL_OWNER_UID:-$(read_env_value MODEL_OWNER_UID || id -u)}
owner_gid=${MODEL_OWNER_GID:-$(read_env_value MODEL_OWNER_GID || id -g)}
image_tag=${IMAGE_TAG:-$(read_env_value IMAGE_TAG || printf '2026-09-12')}

usage() {
  cat <<'EOF'
Usage: ./scripts/migrate-storage.sh [options]

Copy the old Docker named volumes into the host directories used by the current
Compose file. Source volumes are retained after a successful copy.

Options:
  --model-dir PATH   Destination for model files (default: MODEL_DIR from .env)
  --cache-dir PATH   Destination for Hugging Face cache (default: HF_CACHE_DIR)
  --merge            Permit copying into non-empty destination directories
  --help             Show this help
EOF
}

while (($#)); do
  case "$1" in
    --model-dir)
      [[ $# -ge 2 ]] || { echo "--model-dir requires a path." >&2; exit 2; }
      model_dir=$2
      shift 2
      ;;
    --cache-dir)
      [[ $# -ge 2 ]] || { echo "--cache-dir requires a path." >&2; exit 2; }
      cache_dir=$2
      shift 2
      ;;
    --merge)
      allow_merge=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

command -v docker >/dev/null || { echo "Docker is required." >&2; exit 1; }
[[ "$owner_uid" =~ ^[0-9]+$ && "$owner_gid" =~ ^[0-9]+$ ]] || {
  echo "MODEL_OWNER_UID and MODEL_OWNER_GID must be numeric." >&2
  exit 2
}

resolve_destination() {
  local path=$1
  if [[ "$path" == /* ]]; then
    realpath -m "$path"
  else
    realpath -m "$project_dir/$path"
  fi
}

model_dir=$(resolve_destination "$model_dir")
cache_dir=$(resolve_destination "$cache_dir")

for destination in "$model_dir" "$cache_dir"; do
  [[ "$destination" != / ]] || { echo "Refusing to use / as a destination." >&2; exit 2; }
  mkdir -p "$destination" || {
    echo "Cannot create $destination. Create it with suitable permissions and retry." >&2
    exit 1
  }
done

helper_image=${MIGRATION_IMAGE:-engramhalo-strix-halo:$image_tag}
if ! docker image inspect "$helper_image" >/dev/null 2>&1; then
  helper_image=registry.fedoraproject.org/fedora-minimal:44
  if ! docker image inspect "$helper_image" >/dev/null 2>&1; then
    echo "Pulling the small Fedora helper image required for the copy."
    docker pull "$helper_image"
  fi
fi

copy_volume() {
  local volume=$1 destination=$2 label=$3

  if ! docker volume inspect "$volume" >/dev/null 2>&1; then
    echo "$label source volume '$volume' does not exist; nothing to migrate."
    return 0
  fi

  running=$(docker ps --quiet --filter "volume=$volume")
  if [[ -n "$running" ]]; then
    echo "$label source volume '$volume' is used by a running container." >&2
    echo "Run 'docker compose down' and retry the migration." >&2
    return 1
  fi

  if [[ "$allow_merge" != true ]] && find "$destination" -mindepth 1 -print -quit | grep -q .; then
    echo "$label destination '$destination' is not empty." >&2
    echo "Use --merge only after confirming its contents should be combined." >&2
    return 1
  fi

  echo "Copying $label from '$volume' to '$destination' ..."
  set +e
  docker run --rm --user 0:0 \
    -e DEST_UID="$owner_uid" -e DEST_GID="$owner_gid" \
    -v "$volume:/from:ro" -v "$destination:/to" \
    "$helper_image" /bin/sh -eu -c '
      if ! find /from -mindepth 1 -print -quit | grep -q .; then
        exit 42
      fi
      cp -a /from/. /to/
      find /from -type f -printf "%P\t%s\n" | while IFS="$(printf "\t")" read -r relative expected; do
        actual=$(stat -c %s "/to/$relative")
        [ "$actual" = "$expected" ] || {
          echo "Verification failed for $relative: expected $expected bytes, found $actual." >&2
          exit 1
        }
      done
      chown -R "$DEST_UID:$DEST_GID" /to
    '
  status=$?
  set -e

  case "$status" in
    0)
      echo "$label migration completed and file sizes were verified."
      ;;
    42)
      echo "$label source volume '$volume' is empty; nothing to migrate."
      ;;
    *)
      echo "$label migration failed with status $status." >&2
      return "$status"
      ;;
  esac
}

copy_volume "$source_model_volume" "$model_dir" "Model"
copy_volume "$source_cache_volume" "$cache_dir" "Cache"

cat <<EOF

Migration finished. Source volumes were not deleted.
Model directory: $model_dir
Cache directory: $cache_dir

Start the updated deployment with:
  docker compose up -d

After the API is healthy and the files are present in the host directories, the
old named volumes can be removed manually if you no longer need the rollback.
EOF
