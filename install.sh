#!/usr/bin/env bash
# SilentSell (سایلنت‌سل) — one-line / local installer
# ------------------------------------------------------------
#   curl -fsSL https://raw.githubusercontent.com/silent4time/silentsell/main/install.sh | sudo bash
#
# Local zip:
#   sudo bash install.sh /root/silentsell-latest.zip
#
# Any manage.sh command can follow (install, update, migrate, status, ...):
#   sudo bash install.sh /root/silentsell-latest.zip migrate --dry-run
#
# An old "mirza_vali Pro" install (/home/mirza_vali_pro) is found automatically;
# menu option 10 (or the "migrate" command) moves it to /home/silentsell.
# ------------------------------------------------------------
set -euo pipefail

REPO_OWNER="${REPO_OWNER:-silent4time}"
REPO_NAME="${REPO_NAME:-silentsell}"
ZIP_NAME="silentsell-latest.zip"
REPO_ZIP_RAW="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/${ZIP_NAME}"
REPO_ZIP_GITHUB="https://github.com/${REPO_OWNER}/${REPO_NAME}/raw/main/${ZIP_NAME}"
SRC_DIR="/opt/silentsell-src"
WORK="/tmp/silentsell_install_$$"

LOCAL_ZIP=""
if [[ "${1:-}" == *.zip ]]; then
  LOCAL_ZIP="$1"
  shift
fi

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Please run as root (sudo)."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
command -v curl >/dev/null 2>&1 || { apt-get update -y >/dev/null 2>&1; apt-get install -y curl >/dev/null 2>&1; }
command -v unzip >/dev/null 2>&1 || { apt-get update -y >/dev/null 2>&1; apt-get install -y unzip >/dev/null 2>&1; }

mkdir -p "$WORK"
ZIP_FILE="$WORK/${ZIP_NAME}"

pick_local_zip() {
  local c
  for c in "$LOCAL_ZIP" "/root/${ZIP_NAME}" "/home/${ZIP_NAME}"; do
    if [[ -n "$c" && -f "$c" && -s "$c" ]]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

echo "[*] SilentSell installer"
echo "    Install path (default): /home/silentsell"
echo ""

if [[ "${SKIP_LOCAL:-0}" != "1" ]] && LOCAL_FOUND="$(pick_local_zip)"; then
  echo "[*] Using local package: $LOCAL_FOUND"
  cp -f "$LOCAL_FOUND" "$ZIP_FILE"
else
  echo "[*] Downloading ${ZIP_NAME} from GitHub (${REPO_OWNER}/${REPO_NAME})..."
  OK=0
  if [[ -n "${GITHUB_TOKEN:-${GH_TOKEN:-}}" ]]; then
    TOK="${GITHUB_TOKEN:-$GH_TOKEN}"
    if curl -fsSL --connect-timeout 15 --max-time 180 \
      -H "Authorization: token ${TOK}" \
      -o "$ZIP_FILE" "$REPO_ZIP_GITHUB"; then
      OK=1
    fi
  fi
  if [[ "$OK" -ne 1 ]]; then
    if curl -fsSL --connect-timeout 15 --max-time 180 --retry 2 -o "$ZIP_FILE" "$REPO_ZIP_GITHUB"; then
      OK=1
    elif curl -fsSL --connect-timeout 15 --max-time 180 --retry 2 -o "$ZIP_FILE" "$REPO_ZIP_RAW"; then
      OK=1
    fi
  fi
  if [[ "$OK" -ne 1 ]]; then
    echo "[x] Could not download from GitHub."
    echo "    Upload the zip to the server and run: sudo bash install.sh /root/${ZIP_NAME}"
    rm -rf "$WORK"
    exit 1
  fi
fi

if [[ ! -s "$ZIP_FILE" ]] || ! unzip -t "$ZIP_FILE" >/dev/null 2>&1; then
  echo "[x] Package is missing or not a valid zip."
  rm -rf "$WORK"
  exit 1
fi

echo "[*] Extracting..."
mkdir -p "$WORK/out"
unzip -qo "$ZIP_FILE" -d "$WORK/out"

FOUND=""
if [[ -f "$WORK/out/manage.sh" && -d "$WORK/out/patch" ]]; then
  FOUND="$WORK/out"
else
  FOUND="$(find "$WORK/out" -type f -name manage.sh 2>/dev/null | head -1 || true)"
  [[ -n "$FOUND" ]] && FOUND="$(dirname "$FOUND")"
fi

if [[ -z "$FOUND" || ! -f "$FOUND/manage.sh" || ! -f "$FOUND/patch/botapi.php" ]]; then
  echo "[x] This zip is not a SilentSell package (manage.sh / patch/ missing)."
  rm -rf "$WORK"
  exit 1
fi
if ! grep -q 'PROJECT_NAME="silentsell"' "$FOUND/manage.sh"; then
  echo "[x] This package is not SilentSell."
  rm -rf "$WORK"
  exit 1
fi

echo "[*] Installing source to $SRC_DIR ..."
rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"
cp -a "$FOUND"/. "$SRC_DIR/"
chmod +x "$SRC_DIR/manage.sh" "$SRC_DIR/install.sh" 2>/dev/null || true
ln -sf "$SRC_DIR/manage.sh" /usr/local/bin/silentsell
rm -rf "$WORK"

echo "[*] Source OK — command: sudo silentsell"
cd "$SRC_DIR"
if [[ $# -eq 0 && -e /dev/tty ]]; then
  exec bash ./manage.sh < /dev/tty
else
  exec bash ./manage.sh "$@"
fi
