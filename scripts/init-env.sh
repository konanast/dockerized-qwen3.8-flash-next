#!/usr/bin/env bash
set -Eeuo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
example_file="$project_dir/.env.example"
env_file="$project_dir/.env"

[[ -f "$example_file" ]] || {
  echo "Missing $example_file" >&2
  exit 1
}

if [[ -e "$env_file" ]]; then
  echo "$env_file already exists; it was not changed."
  exit 0
fi

if command -v openssl >/dev/null 2>&1; then
  api_key=$(openssl rand -hex 32)
else
  api_key=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
fi

host_uid=$(id -u)
host_gid=$(id -g)
video_gid=$(getent group video 2>/dev/null | cut -d: -f3 || true)
render_gid=$(getent group render 2>/dev/null | cut -d: -f3 || true)
video_gid=${video_gid:-44}
render_gid=${render_gid:-109}

umask 077
sed \
  -e "s|^API_KEY=.*|API_KEY=$api_key|" \
  -e "s|^MODEL_OWNER_UID=.*|MODEL_OWNER_UID=$host_uid|" \
  -e "s|^MODEL_OWNER_GID=.*|MODEL_OWNER_GID=$host_gid|" \
  -e "s|^VIDEO_GID=.*|VIDEO_GID=$video_gid|" \
  -e "s|^RENDER_GID=.*|RENDER_GID=$render_gid|" \
  "$example_file" > "$env_file"

chmod 0600 "$env_file"
echo "Created .env with a random API key and detected host UID/GID values."
echo "Review .env before starting Docker Compose. The file is excluded from Git."
