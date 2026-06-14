#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1:-http://127.0.0.1:5000}"
NO_START="${NO_START:-0}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
APP_PID=""

cleanup() {
  if [[ -n "${APP_PID}" ]] && kill -0 "${APP_PID}" 2>/dev/null; then
    kill "${APP_PID}" 2>/dev/null || true
    wait "${APP_PID}" 2>/dev/null || true
    echo "Stopped temporary Flask process (PID ${APP_PID})."
  fi
}
trap cleanup EXIT

check_ok() {
  local url="$1"
  local name="$2"
  local body
  body="$(curl -fsS --max-time 10 "${url}")" || {
    echo "[FAIL] ${name} -> request failed (${url})" >&2
    exit 1
  }
  echo "[OK] ${name} -> HTTP 200"
  printf '%s' "${body}"
}

if [[ "${NO_START}" != "1" ]]; then
  if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "Python executable not found: ${PYTHON_BIN}" >&2
    exit 1
  fi

  (
    cd "${REPO_ROOT}"
    CLIENT_ID="${CLIENT_ID:-smoke-test-client}" \
    CLIENT_SECRET="${CLIENT_SECRET:-smoke-test-secret}" \
    FLASK_SECRET_KEY="${FLASK_SECRET_KEY:-smoke-test-secret-key}" \
    FLASK_DEBUG="${FLASK_DEBUG:-false}" \
    "${PYTHON_BIN}" app.py
  ) >/tmp/entramap-smoke.log 2>&1 &
  APP_PID=$!

  ready=0
  for _ in $(seq 1 60); do
    if ! kill -0 "${APP_PID}" 2>/dev/null; then
      echo "Flask process exited before startup completed." >&2
      cat /tmp/entramap-smoke.log >&2 || true
      exit 1
    fi
    if curl -fsS --max-time 2 "${BASE_URL}/api/health" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 0.5
  done

  if [[ "${ready}" -ne 1 ]]; then
    echo "Server did not become ready at ${BASE_URL}" >&2
    cat /tmp/entramap-smoke.log >&2 || true
    exit 1
  fi
fi

page_body="$(check_ok "${BASE_URL}/" "Homepage")"
if ! grep -q "og:image" <<< "${page_body}"; then
  echo "[FAIL] Homepage is missing og:image metadata" >&2
  exit 1
fi
if ! grep -q "social-preview.png" <<< "${page_body}"; then
  echo "[FAIL] Homepage is missing social-preview.png metadata" >&2
  exit 1
fi
echo "[OK] Homepage contains OG image metadata"

health_body="$(check_ok "${BASE_URL}/api/health" "Health endpoint")"
if ! grep -Eq '"status"[[:space:]]*:[[:space:]]*"(ok|warning)"' <<< "${health_body}"; then
  echo "[FAIL] Health endpoint response payload is unexpected" >&2
  echo "${health_body}" >&2
  exit 1
fi
echo "[OK] Health payload shape is valid"

image_bytes="$(curl -fsS --max-time 10 -o /tmp/entramap-social-preview.png -w '%{size_download}' "${BASE_URL}/static/brand/social-preview.png")"
if [[ "${image_bytes}" -le 0 ]]; then
  echo "[FAIL] Social preview image response is empty" >&2
  exit 1
fi
echo "[OK] Social preview image bytes: ${image_bytes}"

echo "Smoke check completed successfully."
