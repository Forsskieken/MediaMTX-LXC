#!/usr/bin/env bash
set -euo pipefail

# === CONFIG (poortje) ===
DB_USER="user"
DB_PASS="password"
DB_HOST="192.168.1.32"
DB_AUDIO_URL="http://${DB_USER}:${DB_PASS}@${DB_HOST}/bha-api/audio-receive.cgi"

# === MediaMTX publish target ===
MTX_USER="user"
MTX_PASS="password"
MTX_HOST="127.0.0.1"
MTX_PORT="8554"
MTX_PATH="poortje-audio"

OUT="rtsp://${MTX_USER}:${MTX_PASS}@${MTX_HOST}:${MTX_PORT}/${MTX_PATH}"
echo "[runOnDemand] poortje audio -> ${OUT}" >&2

# Quick preflight so we log the real reason (503 etc)
CODE="$(curl -sS --http1.0 -m 2 -o /dev/null -w '%{http_code}' "${DB_AUDIO_URL}" || true)"
echo "[runOnDemand] preflight HTTP=${CODE}" >&2
[ "${CODE}" = "200" ] || exit 21

# stream
curl --silent --show-error --http1.0 --connect-timeout 2 --max-time 0 "${DB_AUDIO_URL}" \
| /usr/local/bin/ffmpeg -hide_banner -loglevel warning \
    -thread_queue_size 512 \
    -f mulaw -ar 8000 -ac 1 -i pipe:0 \
    -vn \
    -c:a libopus -application lowdelay -b:a 32k -ar 48000 -ac 1 \
    -f rtsp -rtsp_transport tcp \
    -muxdelay 0 -muxpreload 0 \
    "${OUT}"
