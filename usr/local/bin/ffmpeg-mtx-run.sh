#!/usr/bin/env bash
# FFmpeg -> MediaMTX (3 cams)
# - ingang/poortje (DoorBird): RTSP video + DoorBird HTTP audio indien beschikbaar, anders silence
# - wachtkamer: RTSP met embedded audio, encode voor stabiele timestamps

set -euo pipefail

ENV_FILE="${1:-}"
[ -n "${ENV_FILE}" ] || { echo "[ERR] No env file given"; exit 10; }
[ -f "${ENV_FILE}" ] || { echo "[ERR] Env file not found: ${ENV_FILE}"; exit 10; }

# shellcheck disable=SC1090
. "${ENV_FILE}"

log(){ echo "[ffmpeg-mtx] $*" >&2; }

: "${CAM:?Missing CAM in env file (ingang|poortje|wachtkamer)}"
: "${SRC_RTSP:?Missing SRC_RTSP in env file}"
: "${DST_VIDEO:?Missing DST_VIDEO in env file}"

MTX_USER="${MTX_USER:-user}"
MTX_PASS="${MTX_PASS:-password}"
MTX_HOST="${MTX_HOST:-127.0.0.1}"
MTX_PORT="${MTX_PORT:-8554}"

RTSP_TRANSPORT="${RTSP_TRANSPORT:-tcp}"
RTSP_TIMEOUT_US="${RTSP_TIMEOUT_US:-5000000}"
GENPTS="${GENPTS:-0}"

OUT_URL="rtsp://${MTX_USER}:${MTX_PASS}@${MTX_HOST}:${MTX_PORT}/${DST_VIDEO}"

ANALYZE_US="${ANALYZE_US:-200000}"
PROBESIZE="${PROBESIZE:-200000}"

COMMON_IN=(
  -rtsp_transport "${RTSP_TRANSPORT}"
  -timeout "${RTSP_TIMEOUT_US}"
  -analyzeduration "${ANALYZE_US}"
  -probesize "${PROBESIZE}"
  -thread_queue_size 512
)


# Optional PTS fix (helps with some DoorBird cams)
if [ "${GENPTS}" = "1" ]; then
  COMMON_IN+=(
    -fflags +genpts
    -use_wallclock_as_timestamps 1
    -avoid_negative_ts make_zero
  )
fi
run_doorbird() {
  local NAME="$1"   # "ingang" or "poortje"
  : "${SRC_AUDIO_HTTP:?Missing SRC_AUDIO_HTTP for DoorBird CAM=${NAME}}"

  # DoorBird audio is often 503 when line is busy; do best-effort preflight
  local CODE
  CODE="$(curl -sS --http1.0 -m 2 -o /dev/null -w '%{http_code}' "${SRC_AUDIO_HTTP}" || true)"
  log "[${NAME}] DoorBird audio preflight HTTP=${CODE}"

  if [ "${CODE}" = "200" ]; then
    log "[${NAME}] starting DoorBird encode (10fps) WITH HTTP audio -> ${OUT_URL}"
exec /usr/local/bin/ffmpeg -hide_banner -loglevel warning \
  "${COMMON_IN[@]}" \
  -i "${SRC_RTSP}" \
  -f lavfi -i "anullsrc=channel_layout=mono:sample_rate=48000" \
  -map 0:v:0 \
  -map 1:a:0 \
  -c:v libx264 -pix_fmt yuv420p -profile:v baseline -level 3.1 \
  -preset ultrafast -tune zerolatency \
  -r 10 -g 20 -keyint_min 20 -sc_threshold 0 \
  -c:a libopus -b:a 48k -ar 48000 -ac 1 \
  -f rtsp -rtsp_transport "${RTSP_TRANSPORT}" \
  "${OUT_URL}"


  else
    log "[${NAME}] HTTP audio not available (HTTP=${CODE}) -> starting WITH SILENCE only -> ${OUT_URL}"
    exec /usr/local/bin/ffmpeg -hide_banner -loglevel warning \
  "${COMMON_IN[@]}" \
  -i "${SRC_RTSP}" \
  -f lavfi -i "anullsrc=channel_layout=mono:sample_rate=16000" \
  -map 0:v:0 \
  -c:v copy \
  -map 1:a:0 \
  -c:a libopus -b:a 48k -ar 48000 -ac 1 \
  -f rtsp -rtsp_transport "${RTSP_TRANSPORT}" \
  "${OUT_URL}"
  fi
}
run_wachtkamer() {
  log "[${CAM}] starting COPY video + AAC audio (no async, robust) -> ${OUT_URL}"
  exec /usr/local/bin/ffmpeg -hide_banner -loglevel warning \
    -fflags +genpts+discardcorrupt \
    -use_wallclock_as_timestamps 1 \
    -avoid_negative_ts make_zero \
    "${COMMON_IN[@]}" \
    -err_detect ignore_err \
    -i "${SRC_RTSP}" \
    -map 0:v:0 \
    -map 0:a:0? \
    -c:v copy \
    -c:a libopus -b:a 48k -ar 48000 -ac 1 \
    -f rtsp -rtsp_transport "${RTSP_TRANSPORT}" \
    "${OUT_URL}"
}



case "${CAM}" in
  ingang)     run_doorbird "ingang" ;;
  poortje)    run_doorbird "poortje" ;;
  wachtkamer) run_wachtkamer ;;
  *)
    log "[ERR] Unknown CAM='${CAM}'. Use: ingang|poortje|wachtkamer"
    exit 11
    ;;
esac
