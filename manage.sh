#!/usr/bin/env bash
# ============================================================================
#  SilentSell (سایلنت‌سل) — پنل مدیریت نصب
#  نسخه: با فایل VERSION هم‌خوان است
#
#  اجرا:
#    sudo virabot              (بعد از نصب)
#    sudo bash manage.sh
#
#  One-line install (from any directory, interactive menu works):
#    curl -fsSL https://raw.githubusercontent.com/silent4time/virabot/main/install.sh | sudo bash
#  Or:
#    sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/silent4time/virabot/main/install.sh)"
# ============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
#  تنظیمات
# ---------------------------------------------------------------------------
GITHUB_REPO="${GITHUB_REPO:-https://github.com/silent4time/virabot.git}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
PROJECT_NAME="virabot"
ZIP_NAME="${PROJECT_NAME}-latest.zip"
BACKUP_ROOT="/root/${PROJECT_NAME}-backups"
# نام قبلی پروژه (mirza_vali Pro) — نصب‌های قدیمی با «migrate» منتقل می‌شوند
LEGACY_NAME="mirza_vali_pro"
LEGACY_STATE_DIR="/etc/${LEGACY_NAME}"
LICENSE_API_DEFAULT="https://license.example.com/api/verify.php"
DEFAULT_INSTALL_DIR="/home/${PROJECT_NAME}"
STATE_DIR="/etc/${PROJECT_NAME}"
INSTANCES_DIR="${STATE_DIR}/instances"
STATE_FILE="${STATE_DIR}/install.env"   # active / last-selected instance
SERVICE_NAME="${PROJECT_NAME}-tunnel"
APACHE_SITE="${PROJECT_NAME}"           # overridden per instance
INSTANCE_ID=""
# مسیر پیش‌فرض قرار دادن zip روی سرور (شما zip را اینجا می‌گذارید)
ZIP_DROP_DIR="${ZIP_DROP_DIR:-/home}"

# رنگ‌ها
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ---------------------------------------------------------------------------
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }
info() { echo -e "${CYAN}[i]${NC} $*"; }

# Network helpers with timeouts (prevent infinite hang)
safe_curl() {
  curl -fsSL --connect-timeout 15 --max-time 180 --retry 2 --retry-delay 2 "$@"
}

safe_git_clone() {
  local repo="$1" dir="$2"
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 git clone --depth 1 --branch "$GITHUB_BRANCH" "$repo" "$dir"
  else
    git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 clone --depth 1 --branch "$GITHUB_BRANCH" "$repo" "$dir"
  fi
}



# فقط مسیرهای نسخهٔ خیلی قدیمی را پاک کن — هرگز نمونهٔ ثبت‌شده را حذف نکن
cleanup_stale_install_dirs() {
  local active="${1:-}"
  local stale_dirs=()
  local d registered=""
  # مسیرهای همه نمونه‌های ثبت‌شده
  if [[ -d "$INSTANCES_DIR" ]]; then
    local f
    for f in "$INSTANCES_DIR"/*.env; do
      [[ -f "$f" ]] || continue
      registered+="$(grep -E '^INSTALL_DIR=' "$f" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')"$'
'
    done
  fi
  for d in "${stale_dirs[@]}"; do
    if [[ -n "$active" && "$d" == "$active" ]]; then
      continue
    fi
    if echo "$registered" | grep -qx "$d"; then
      continue
    fi
    if [[ -d "$d" ]]; then
      info "Removing leftover install dir: $d"
      rm -rf "$d"
      ok "Removed $d"
    fi
  done
}

# --- Multi-instance helpers ---
instance_id_from_path() {
  local p="${1:-}"
  local id
  id="$(basename "$p" | tr -c 'A-Za-z0-9._-' '_' | sed 's/^_*//;s/_*$//')"
  [[ -z "$id" ]] && id="mv$(date +%s)"
  echo "$id"
}

instance_state_file() {
  local id="${1:-$INSTANCE_ID}"
  echo "${INSTANCES_DIR}/${id}.env"
}

apply_instance_identity() {
  # Set APACHE_SITE / INSTANCE_ID from INSTALL_DIR
  INSTANCE_ID="$(instance_id_from_path "${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}")"
  APACHE_SITE="ss-${INSTANCE_ID}"
  STATE_FILE="$(instance_state_file "$INSTANCE_ID")"
}

list_instance_ids() {
  mkdir -p "$INSTANCES_DIR"
  local f
  for f in "$INSTANCES_DIR"/*.env; do
    [[ -f "$f" ]] || continue
    basename "$f" .env
  done
  # migrate legacy single install.env into instances/
  if [[ -f "${STATE_DIR}/install.env" ]] && [[ ! -f "${INSTANCES_DIR}/$(grep -E '^INSTALL_DIR=' "${STATE_DIR}/install.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | xargs -I{} basename {} 2>/dev/null || echo legacy).env" ]]; then
    :
  fi
}

count_instances() {
  list_instance_ids | grep -c . || true
}

pick_free_port() {
  local p="${1:-8091}"
  local max=$((p + 50))
  while [[ $p -lt $max ]]; do
    if ! ss -tln 2>/dev/null | grep -qE ":${p}\s"; then
      # also check our instance envs for claimed ports
      if ! grep -Rqs "MIRZA_HTTP_PORT=\"${p}\"" "$INSTANCES_DIR" 2>/dev/null; then
        echo "$p"
        return 0
      fi
    fi
    p=$((p + 1))
  done
  echo "$((8091 + RANDOM % 100))"
}

# Write instance env + active pointer
save_state() {
  mkdir -p "$STATE_DIR" "$INSTANCES_DIR"
  apply_instance_identity
  local file
  file="$(instance_state_file "$INSTANCE_ID")"
  cat > "$file" <<EOF
INSTANCE_ID="${INSTANCE_ID}"
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
DB_NAME="${DB_NAME:-}"
DB_USER="${DB_USER:-}"
DB_PASS="${DB_PASS:-}"
ENABLE_TELEGRAM="${ENABLE_TELEGRAM:-true}"
TELEGRAM_TOKEN="${TELEGRAM_TOKEN:-}"
TELEGRAM_USERNAME="${TELEGRAM_USERNAME:-}"
ADMIN_ID="${ADMIN_ID:-}"
ENABLE_BALE="${ENABLE_BALE:-true}"
BALE_TOKEN="${BALE_TOKEN:-}"
BALE_ADMIN_ID="${BALE_ADMIN_ID:-}"
BALE_REPORT_GROUP_ID="${BALE_REPORT_GROUP_ID:-}"
BALE_PROVIDER_TOKEN="${BALE_PROVIDER_TOKEN:-}"
TELEGRAM_REPORT_GROUP_ID="${TELEGRAM_REPORT_GROUP_ID:-}"
WEBHOOK_SECRET="${WEBHOOK_SECRET:-}"
DOMAIN="${DOMAIN:-}"
LICENSE_KEY="${LICENSE_KEY:-}"
LICENSE_API_URL="${LICENSE_API_URL:-}"
DOMAIN_MODE="${DOMAIN_MODE:-2}"
MIRZA_HTTP_PORT="${MIRZA_HTTP_PORT:-8091}"
APACHE_SITE="${APACHE_SITE}"
GITHUB_REPO="${GITHUB_REPO}"
INSTALLED_VERSION="$(version_of "${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}" 2>/dev/null || echo unknown)"
INSTALLED_AT="$(date -Is)"
EOF
  chmod 600 "$file"
  # active pointer (compat with old scripts)
  cp -f "$file" "${STATE_DIR}/install.env"
  STATE_FILE="$file"
  ok "Install state saved: $file"
}

load_state() {
  local want="${1:-}"
  mkdir -p "$INSTANCES_DIR"
  # migrate legacy
  if [[ -f "${STATE_DIR}/install.env" && ! -d "$INSTANCES_DIR" ]] || [[ -f "${STATE_DIR}/install.env" ]]; then
    if [[ ! -f "$(instance_state_file "$(instance_id_from_path "$(grep -E '^INSTALL_DIR=' "${STATE_DIR}/install.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')")")" ]]; then
      local leg_dir leg_id leg_file
      leg_dir="$(grep -E '^INSTALL_DIR=' "${STATE_DIR}/install.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)"
      if [[ -n "$leg_dir" ]]; then
        leg_id="$(instance_id_from_path "$leg_dir")"
        leg_file="$(instance_state_file "$leg_id")"
        if [[ ! -f "$leg_file" ]]; then
          cp -f "${STATE_DIR}/install.env" "$leg_file"
          echo "INSTANCE_ID="${leg_id}"" >> "$leg_file"
          echo "APACHE_SITE="mv-${leg_id}"" >> "$leg_file"
        fi
      fi
    fi
  fi

  local file=""
  if [[ -n "$want" && -f "$(instance_state_file "$want")" ]]; then
    file="$(instance_state_file "$want")"
  elif [[ -n "${INSTANCE_ID:-}" && -f "$(instance_state_file "$INSTANCE_ID")" ]]; then
    file="$(instance_state_file "$INSTANCE_ID")"
  elif [[ -f "${STATE_DIR}/install.env" ]]; then
    file="${STATE_DIR}/install.env"
  fi
  if [[ -n "$file" && -f "$file" ]]; then
    # shellcheck disable=SC1090
    source "$file"
    apply_instance_identity
    STATE_FILE="$file"
  fi
}

# Interactive select when more than one instance
select_instance() {
  local purpose="${1:-manage}"
  local ids=()
  mapfile -t ids < <(list_instance_ids)
  # also ensure legacy pointer counted
  if [[ ${#ids[@]} -eq 0 && -f "${STATE_DIR}/install.env" ]]; then
    load_state
    return 0
  fi
  if [[ ${#ids[@]} -eq 0 ]]; then
    warn "No installed instance found."
    return 1
  fi
  if [[ ${#ids[@]} -eq 1 ]]; then
    load_state "${ids[0]}"
    info "Selected instance: ${ids[0]}  (${INSTALL_DIR:-?})"
    return 0
  fi
  echo ""
  echo -e "${BOLD}Select instance for: ${purpose}${NC}"
  local i=1 id
  for id in "${ids[@]}"; do
    local p d
    p="$(grep -E '^INSTALL_DIR=' "$(instance_state_file "$id")" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')"
    d="$(grep -E '^DOMAIN=' "$(instance_state_file "$id")" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')"
    echo "  $i) $id   path=$p   domain=${d:-none}"
    i=$((i + 1))
  done
  local choice
  read -rp "  Number: " choice
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 || "$choice" -gt ${#ids[@]} ]]; then
    err "Invalid selection"
    return 1
  fi
  load_state "${ids[$((choice - 1))]}"
  ok "Active instance: $INSTANCE_ID -> $INSTALL_DIR"
  return 0
}

show_instances_banner_line() {
  local n
  n="$(count_instances)"
  n="${n//$'
'/}"
  if [[ -z "$n" || "$n" == "0" ]]; then
    if [[ -f "${STATE_DIR}/install.env" ]]; then
      load_state
      echo -e "  Status  : ${GREEN}Installed${NC}  ->  ${INSTALL_DIR:-?}  (v${INSTALLED_VERSION:-?})"
    else
      echo -e "  Status  : ${YELLOW}Not installed${NC}"
    fi
  elif [[ "$n" == "1" ]]; then
    load_state "$(list_instance_ids | head -1)"
    echo -e "  Status  : ${GREEN}Installed${NC}  ->  ${INSTALL_DIR:-?}  (v${INSTALLED_VERSION:-?})"
  else
    echo -e "  Status  : ${GREEN}${n} instances${NC}"
    local id
    for id in $(list_instance_ids); do
      local p
      p="$(grep -E '^INSTALL_DIR=' "$(instance_state_file "$id")" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')"
      echo -e "             • ${id}: ${p}"
    done
  fi
}

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "This script must be run as root:"
    echo "  sudo bash $0"
    exit 1
  fi
}

version_of() {
  local dir="${1:-.}"
  if [[ -f "${dir}/VERSION" ]]; then
    cat "${dir}/VERSION" | tr -d '[:space:]'
  else
    echo "unknown"
  fi
}

# load_state / save_state defined above (multi-instance)

pause() {
  echo ""
  if [[ -t 0 ]]; then
    read -rp "Press Enter to return to menu... " _ || true
  else
    sleep 1
  fi
}

ask() {
  local prompt="$1" default="${2:-}" var
  if [[ -n "$default" ]]; then
    read -rp "$prompt [$default]: " var
    echo "${var:-$default}"
  else
    read -rp "$prompt: " var
    echo "$var"
  fi
}

ask_yn() {
  local prompt="$1" default="${2:-y}" var
  read -rp "$prompt [y/n] (default: $default): " var
  var="${var:-$default}"
  [[ "$var" =~ ^[YyیY] ]] && echo "true" || echo "false"
}

# Force a numeric ID (Telegram/Bale user or group). Rejects @username and empty.
ask_id_number() {
  local prompt="$1" default="${2:-}" var
  while true; do
    if [[ -n "$default" ]]; then
      read -rp "$prompt [ID number] [$default]: " var
      var="${var:-$default}"
    else
      read -rp "$prompt [ID number]: " var
    fi
    var="$(echo "$var" | tr -d '[:space:]')"
    if [[ -z "$var" ]]; then
      echo -e "${YELLOW}[!] Required. Enter numeric ID only (example: 4313495246). Not username.${NC}" >&2
      continue
    fi
    if [[ "$var" =~ ^-?[0-9]+$ ]]; then
      echo "$var"
      return 0
    fi
    echo -e "${YELLOW}[!] Invalid. Enter numeric ID number only (digits). Example: 4313495246${NC}" >&2
  done
}

# مسیر خود اسکریپت / ریپوی محلی (اگر از داخل کلون اجرا شود)
# اگر با curl | bash اجرا شود، BASH_SOURCE ممکن است /dev/fd/... باشد → از گیت‌هاب کلون می‌کنیم
_bootstrap_source() {
  local candidate=""
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || true)"
  fi

  # Already running from a source tree that has patch/ — use it, do not re-clone
  if [[ -n "$candidate" && -d "${candidate}/patch" && -f "${candidate}/patch/botapi.php" ]]; then
    SCRIPT_DIR="$candidate"
    HAS_LOCAL_PATCH="true"
    cd "$SCRIPT_DIR" || true
    return 0
  fi

  # Running from a partial tree (manage.sh only, no patch yet)
  if [[ -n "$candidate" && -f "${candidate}/manage.sh" ]]; then
    SCRIPT_DIR="$candidate"
    if [[ -d "${candidate}/patch" && -f "${candidate}/patch/botapi.php" ]]; then
      HAS_LOCAL_PATCH="true"
    else
      HAS_LOCAL_PATCH="false"
      warn "Folder patch/ is missing in $candidate"
      warn "Upload the full 'patch' folder to GitHub (botapi.php, index.php, ...)."
    fi
    cd "$SCRIPT_DIR" || true
    return 0
  fi

  # Fresh run: clone into /opt (never delete the directory we are running from)
  local cache="/opt/${PROJECT_NAME}-src"
  local cwd
  cwd="$(pwd -P 2>/dev/null || pwd)"
  mkdir -p /opt

  # اگر سورس قبلی کامل است، کلون نکن (منو سریع باز شود)
  if [[ -f "${cache}/manage.sh" && -d "${cache}/patch" && -f "${cache}/patch/botapi.php" ]]; then
    SCRIPT_DIR="$cache"
    HAS_LOCAL_PATCH="true"
    cd "$SCRIPT_DIR" || true
    ok "Source ready (cached): $cache"
    return 0
  fi

  info "Downloading latest version from GitHub (timeout 120s)..."
  command -v git >/dev/null 2>&1 || { apt-get update -y >/dev/null 2>&1; apt-get install -y git >/dev/null 2>&1; }
  if [[ "$cwd" != "$cache" && "$candidate" != "$cache" ]]; then
    rm -rf "$cache"
  fi
  if [[ ! -d "$cache/.git" && ! -f "$cache/manage.sh" ]]; then
    if ! safe_git_clone "$GITHUB_REPO" "$cache"; then
      err "GitHub clone failed or timed out: $GITHUB_REPO"
      err "Put ${ZIP_NAME} in /root and run: sudo bash install.sh /root/${ZIP_NAME}"
      exit 1
    fi
  fi
  SCRIPT_DIR="$cache"
  if [[ -d "${cache}/patch" && -f "${cache}/patch/botapi.php" ]]; then
    HAS_LOCAL_PATCH="true"
  else
    HAS_LOCAL_PATCH="false"
    warn "Clone OK but patch/ folder is missing on GitHub."
    warn "Upload patch/ (all PHP files) via GitHub website, then run install again."
  fi
  ok "Source ready: $cache"
  cd "$SCRIPT_DIR" || true
}

# If this process was started via "curl | bash", stdin is the script pipe
# and the menu cannot read key presses. Re-exec from a real file on a TTY.
_reexec_if_piped() {
  # Already marked as re-exec'd
  if [[ "${MIRZA_REEXEC:-}" == "1" ]]; then
    return 0
  fi
  # stdin is a terminal? OK
  if [[ -t 0 ]]; then
    return 0
  fi
  # Prefer the cloned/local manage.sh on disk
  local target="${SCRIPT_DIR}/manage.sh"
  if [[ ! -f "$target" ]]; then
    target="/opt/${PROJECT_NAME}-src/manage.sh"
  fi
  if [[ ! -f "$target" ]]; then
    # Last resort: save ourselves to /tmp
    target="/tmp/${PROJECT_NAME}-manage.sh"
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
      cp -f "${BASH_SOURCE[0]}" "$target"
    else
      safe_curl "https://raw.githubusercontent.com/silent4time/${PROJECT_NAME}/main/manage.sh" -o "$target" || true
    fi
  fi
  if [[ -f "$target" ]]; then
    chmod +x "$target"
    info "Switching to interactive mode (menu input enabled)..."
    cd "$(dirname "$target")" 2>/dev/null || true
    export MIRZA_REEXEC=1
    exec sudo -E env MIRZA_REEXEC=1 bash "$target" "$@"
  fi
}

SCRIPT_DIR=""
HAS_LOCAL_PATCH="false"

# ===========================================================================
#  منوی اصلی
# ===========================================================================
show_banner() {
  clear
  local ver
  ver="$(version_of "$SCRIPT_DIR")"
  echo -e "${BOLD}${CYAN}"
  cat << EOF
+==========================================================+
|                                                          |
|             SilentSell  -  Management Panel              |
|                   Telegram  +  Bale                      |
|                                                          |
+==========================================================+
EOF
  echo -e "${NC}"
  echo -e "  Version : ${BOLD}v${ver}${NC}"
  show_instances_banner_line
  if has_legacy; then
    warn "Old mirza_vali Pro install found — option 10 moves it to SilentSell."
  fi
  echo ""
}

show_menu() {
  echo -e "${BOLD}  Main Menu:${NC}"
  echo "  -------------------------------------"
  echo "   1)  Install SilentSell (new instance OK)"
  echo "   2)  Update SilentSell"
  echo "   3)  Remove SilentSell"
  echo "   4)  Reset (webhooks / tunnel / domain)"
  echo "   5)  Renew SSL certificate"
  echo "   6)  Help & Parameters"
  echo "   7)  Status"
  echo "   8)  Configure bots & groups (Telegram / Bale)"
  echo "   9)  List instances (multi-install)"
  if has_legacy; then
    echo "  10)  Move old mirza_vali Pro install to SilentSell"
  fi
  echo "   0)  Exit"
  echo "  -------------------------------------"
  echo ""
}

# ===========================================================================
#  ۱) نصب
# ===========================================================================
do_install() {
  echo ""
  echo -e "${BOLD}=== Install SilentSell ===${NC}"
  echo ""

  if [[ "$HAS_LOCAL_PATCH" != "true" ]]; then
    err "Cannot install: patch/ folder not found."
    err "On GitHub upload the full project including folder: patch/"
    err "Required files: patch/botapi.php patch/index.php patch/function.php ..."
    return 1
  fi

  echo ""
  info "Multi-instance: each install uses its own path / domain / database / bot tokens."
  info "Example second instance: /home/${PROJECT_NAME}2 + different domain and DB."

  INSTALL_DIR="$(ask 'Install path' "$DEFAULT_INSTALL_DIR")"
  INSTALL_DIR="${INSTALL_DIR%/}"
  if [[ "$INSTALL_DIR" != /* ]]; then
    INSTALL_DIR="/home/${INSTALL_DIR}"
  fi
  apply_instance_identity

  # اگر همین مسیر از قبل ثبت شده، تأیید بازنویسی
  if [[ -f "$(instance_state_file "$INSTANCE_ID")" ]]; then
    warn "Instance already exists: $INSTANCE_ID ($INSTALL_DIR)"
    local cont
    cont="$(ask_yn 'Overwrite this instance?' 'n')"
    [[ "$cont" != "true" ]] && return 0
  elif [[ -d "$INSTALL_DIR" && -f "$INSTALL_DIR/config.php" ]]; then
    warn "Folder exists with config.php: $INSTALL_DIR"
    local cont2
    cont2="$(ask_yn 'Continue install into this folder?' 'n')"
    [[ "$cont2" != "true" ]] && return 0
  fi

  # پیشنهاد نام DB یکتا بر اساس instance
  local def_db def_user
  def_db="ss_${INSTANCE_ID//[^A-Za-z0-9]/_}"
  def_db="${def_db:0:32}"
  def_user="u_${INSTANCE_ID:0:12}"
  def_user="${def_user//[^A-Za-z0-9]/}"
  DB_NAME="$(ask 'Database name' "$def_db")"
  DB_USER="$(ask 'Database user' "$def_user")"
  if [[ -z "${DB_PASS:-}" ]]; then
    DB_PASS="$(openssl rand -hex 12)"
    ok "Database password generated: $DB_PASS  (save it!)"
  else
    DB_PASS="$(ask 'Database password' "$DB_PASS")"
  fi

  ENABLE_TELEGRAM="$(ask_yn 'Enable Telegram bot?' 'y')"
  if [[ "$ENABLE_TELEGRAM" == "true" ]]; then
    TELEGRAM_TOKEN="$(ask 'Telegram bot token (BotFather)')"
    TELEGRAM_USERNAME="$(ask 'Telegram bot username (without @)')"
    ADMIN_ID="$(ask_id_number 'Telegram admin ID number')"
    TELEGRAM_REPORT_GROUP_ID="$(ask_id_number 'Telegram report group ID number (optional — Enter to skip later)' '0')"
    [[ "$TELEGRAM_REPORT_GROUP_ID" == "0" ]] && TELEGRAM_REPORT_GROUP_ID=""
  else
    TELEGRAM_TOKEN="disabled"
    TELEGRAM_USERNAME="disabled"
    ADMIN_ID="$(ask_id_number 'Admin ID number (panel access)')"
    TELEGRAM_REPORT_GROUP_ID=""
  fi

  ENABLE_BALE="$(ask_yn 'Enable Bale bot?' 'y')"
  if [[ "$ENABLE_BALE" == "true" ]]; then
    BALE_TOKEN="$(ask 'Bale bot token (my.bale.ai)')"
    BALE_ADMIN_ID="$(ask_id_number 'Bale admin ID number')"
    BALE_REPORT_GROUP_ID="$(ask_id_number 'Bale report group ID number (required)')"
    BALE_PROVIDER_TOKEN="$(ask 'Bale Pay provider token (optional)' '')"
  else
    BALE_TOKEN="disabled"
    BALE_ADMIN_ID=""
    BALE_REPORT_GROUP_ID=""
    BALE_PROVIDER_TOKEN=""
  fi

  WEBHOOK_SECRET="$(openssl rand -hex 16)"

  echo ""
  echo "Internet access:"
  echo "  1) My own domain + SSL"
  echo "  2) Temporary Cloudflare tunnel (testing)"
  DOMAIN_MODE="$(ask 'Choose (1 or 2)' '2')"
  DOMAIN=""
  if [[ "$DOMAIN_MODE" == "1" ]]; then
    DOMAIN="$(ask 'Domain (without https://)')"
  fi

  echo ""
  info "Starting installation..."

  # --- پکیج‌ها ---
  info "Installing packages (apache2, mariadb, php)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || warn "apt-get update had an error, continuing..."
  # Apache + mod_php (same stack as other bots on this server — no Nginx)
  apt-get install -y apache2 mariadb-server php libapache2-mod-php php-mysql php-curl \
    php-mbstring php-gd php-xml php-zip unzip git curl openssl dnsutils >/dev/null
  # Install pdo_mysql for every installed PHP version (CLI vs Apache can differ, e.g. 8.2 vs 8.4)
  for ver in $(ls /etc/php 2>/dev/null || true); do
    apt-get install -y "php${ver}-mysql" >/dev/null 2>&1 || true
    phpenmod -v "$ver" pdo_mysql >/dev/null 2>&1 || true
  done
  if ! command -v composer >/dev/null 2>&1; then
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer >/dev/null 2>&1 || true
  fi
  ok "Packages installed."

  # Stop Nginx if present so it does not fight Apache on port 80
  if systemctl list-unit-files 2>/dev/null | grep -q '^nginx'; then
    systemctl stop nginx 2>/dev/null || true
    systemctl disable nginx 2>/dev/null || true
    warn "Nginx was found and has been stopped/disabled to avoid conflict with Apache."
  fi

  a2enmod rewrite headers >/dev/null 2>&1 || true
  systemctl enable --now mariadb >/dev/null 2>&1 || true
  systemctl enable --now apache2 >/dev/null 2>&1 || true

  # --- دیتابیس ---
  info "Creating database..."
  mysql -uroot -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -uroot -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';" 2>/dev/null || true
  mysql -uroot -e "ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
  mysql -uroot -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"
  ok "Database ready."

  # --- سورس پایه میرزا ---
  if [[ -d "$INSTALL_DIR" ]]; then
    warn "Existing folder found — creating backup..."
    mv "$INSTALL_DIR" "${INSTALL_DIR}-backup-$(date +%Y%m%d%H%M%S)"
  fi
  mkdir -p "$(dirname "$INSTALL_DIR")"
  info "Downloading base mirzabot source from GitHub..."
  git clone --quiet https://github.com/mahdiMGF2/mirzabot.git "$INSTALL_DIR"
  PATCH_BASE_COMMIT="fcd9afeb0e80b67db21cc21611dc91a07c0feee0"
  (cd "$INSTALL_DIR" && git checkout --quiet "$PATCH_BASE_COMMIT") || warn "Could not checkout pinned commit"
  ok "Base source ready."

  if [[ -f "$INSTALL_DIR/composer.json" && ! -d "$INSTALL_DIR/vendor" ]]; then
    info "Installing Composer dependencies..."
    (cd "$INSTALL_DIR" && composer install --no-dev --no-interaction --optimize-autoloader) || warn "composer install failed"
  fi

  # --- اعمال پچ ---
  info "Applying SilentSell patch..."
  apply_patch_files "$INSTALL_DIR"
  write_config "$INSTALL_DIR"
  echo "$(version_of "$SCRIPT_DIR")" > "$INSTALL_DIR/VERSION"
  echo "$PROJECT_NAME" > "$INSTALL_DIR/PROJECT_NAME"
  ok "Patch applied."

  # --- جداول ---
  info "Building database tables..."
  if ! (cd "$INSTALL_DIR" && php table.php); then
    err "php table.php failed. Check: cd $INSTALL_DIR && php table.php"
    exit 1
  fi
  # Verify critical tables exist
  local tbl_ok
  tbl_ok="$(mysql -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" -N -e "SHOW TABLES LIKE 'setting';" 2>/dev/null || true)"
  if [[ -z "$tbl_ok" ]]; then
    err "Table 'setting' was not created in database ${DB_NAME}."
    err "Fix PHP MySQL extension then run: cd $INSTALL_DIR && php table.php"
    exit 1
  fi
  ok "Database tables ready."
  if [[ -n "${BALE_PROVIDER_TOKEN:-}" && "$BALE_PROVIDER_TOKEN" != "0" ]]; then
    mysql -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" -e \
      "UPDATE PaySetting SET ValuePay='${BALE_PROVIDER_TOKEN}' WHERE NamePay='merchant_balepay';" 2>/dev/null || true
    mysql -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" -e \
      "UPDATE PaySetting SET ValuePay='onbalepay' WHERE NamePay='balepaystatus';" 2>/dev/null || true
    ok "Bale Pay token saved and enabled in database."
  fi

  # Report groups + Bale overrides in DB
  if [[ -n "${BALE_REPORT_GROUP_ID:-}" ]]; then
    mysql -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" -e \
      "INSERT INTO PaySetting (NamePay, ValuePay) VALUES ('bale_report_group_id','${BALE_REPORT_GROUP_ID}') ON DUPLICATE KEY UPDATE ValuePay='${BALE_REPORT_GROUP_ID}';" 2>/dev/null || \
    mysql -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" -e \
      "UPDATE PaySetting SET ValuePay='${BALE_REPORT_GROUP_ID}' WHERE NamePay='bale_report_group_id';" 2>/dev/null || true
    ok "Bale report group ID number saved: ${BALE_REPORT_GROUP_ID}"
  fi
  if [[ -n "${BALE_ADMIN_ID:-}" ]]; then
    mysql -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" -e \
      "UPDATE PaySetting SET ValuePay='${BALE_ADMIN_ID}' WHERE NamePay='bale_admin_id';" 2>/dev/null || true
  fi
  if [[ -n "${BALE_TOKEN:-}" && "$BALE_TOKEN" != "disabled" ]]; then
    mysql -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" -e \
      "UPDATE PaySetting SET ValuePay='${BALE_TOKEN}' WHERE NamePay='bale_bot_token';" 2>/dev/null || true
  fi
  if [[ -n "${TELEGRAM_REPORT_GROUP_ID:-}" && "$TELEGRAM_REPORT_GROUP_ID" != "0" ]]; then
    mysql -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" -e \
      "UPDATE setting SET Channel_Report='${TELEGRAM_REPORT_GROUP_ID}';" 2>/dev/null || true
    ok "Telegram report group ID number saved: ${TELEGRAM_REPORT_GROUP_ID}"
  fi
  chown -R www-data:www-data "$INSTALL_DIR" 2>/dev/null || true

  # --- Apache ---
  info "Configuring Apache..."
  # Dedicated listen port avoids fighting other bots that already own *:80 default site.
  # Cloudflare tunnel and (optional) proxy can target this port.
  apply_instance_identity
  MIRZA_HTTP_PORT="$(pick_free_port "${MIRZA_HTTP_PORT:-8091}")"
  info "Dedicated Apache port for this instance: ${MIRZA_HTTP_PORT} (site: ${APACHE_SITE})"
  # Listen on a dedicated port so other Apache bots / other instances are not disturbed
  cat > "/etc/apache2/conf-available/${APACHE_SITE}-port.conf" <<EOF
# SilentSell instance ${INSTANCE_ID} dedicated port
Listen ${MIRZA_HTTP_PORT}
EOF
  a2enconf "${APACHE_SITE}-port" >/dev/null 2>&1 || true

  cat > "/etc/apache2/sites-available/${APACHE_SITE}.conf" <<EOF
# SilentSell — isolated from other Apache bots via dedicated port ${MIRZA_HTTP_PORT}
<VirtualHost *:${MIRZA_HTTP_PORT}>
    ServerAdmin webmaster@localhost
    DocumentRoot ${INSTALL_DIR}
    DirectoryIndex index.php index.html

    <Directory ${INSTALL_DIR}>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${APACHE_SITE}-error.log
    CustomLog \${APACHE_LOG_DIR}/${APACHE_SITE}-access.log combined
</VirtualHost>
EOF
  a2ensite "${APACHE_SITE}.conf" >/dev/null 2>&1 || a2ensite "${APACHE_SITE}" >/dev/null 2>&1 || true

  # Public domain on :80 (needed for Let's Encrypt + Telegram/Bale webhooks)
  if [[ -n "${DOMAIN:-}" && "$DOMAIN_MODE" == "1" ]]; then
    setup_domain_vhost "$DOMAIN"
  fi

  # Do NOT disable other sites (000-default, other bots)
  if apache2ctl configtest >/dev/null 2>&1; then
    systemctl reload apache2
  else
    warn "Apache configtest failed — check: apache2ctl configtest"
  fi
  ok "Apache ready (port ${MIRZA_HTTP_PORT}, path ${INSTALL_DIR})."

  # --- دامنه / تونل ---
  setup_connectivity

  # --- وبهوک ---
  register_webhooks

  # System command like official `mirza`
  install_command

  save_state
  echo ""
  
  # دسترسی آپاچی به مسیر زیر /home
  if [[ "$INSTALL_DIR" == /home/* ]]; then
    chmod o+x /home 2>/dev/null || true
    chmod o+x "$(dirname "$INSTALL_DIR")" 2>/dev/null || true
  fi
  chown -R www-data:www-data "$INSTALL_DIR" 2>/dev/null || true

  # پاک‌سازی مسیر قدیمی پیش‌فرض (اگر نصب جدید جای دیگری است)
  cleanup_stale_install_dirs "$INSTALL_DIR"

  ok "Install complete — $PROJECT_NAME v$(version_of "$INSTALL_DIR")"
  echo "  Path:   $INSTALL_DIR"
  echo "  URL:    https://${DOMAIN:-YOUR_DOMAIN}"
  echo "  DB:     $DB_NAME / $DB_USER / $DB_PASS"
  echo ""
}

# کپی فایل‌های پچ از ریپوی محلی یا دانلود از گیت‌هاب
apply_patch_files() {
  local target="$1"
  local src_patch=""

  if [[ "$HAS_LOCAL_PATCH" == "true" ]]; then
    src_patch="${SCRIPT_DIR}/patch"
  fi

  # اگر پچ محلی نبود، zip داخل /home را امتحان کن
  if [[ -z "$src_patch" || ! -d "$src_patch" ]]; then
    local latest_zip=""
    if [[ -d "${ZIP_DROP_DIR:-/home}" ]]; then
      latest_zip="$(ls -1t "${ZIP_DROP_DIR:-/home}"/${PROJECT_NAME}*.zip 2>/dev/null | head -1 || true)"
    fi
    if [[ -n "$latest_zip" && -f "$latest_zip" ]]; then
      info "Using local zip for patch: $latest_zip"
      local ztmp
      ztmp="$(mktemp -d)"
      command -v unzip >/dev/null 2>&1 || apt-get install -y unzip >/dev/null 2>&1 || true
      unzip -qo "$latest_zip" -d "$ztmp"
      if [[ -d "$ztmp/patch" ]]; then
        src_patch="$ztmp/patch"
      else
        src_patch="$(find "$ztmp" -type d -name patch 2>/dev/null | head -1 || true)"
      fi
      # نگه داشتن ztmp تا پایان کپی — با trap پاک نمی‌کنیم چون ساده است
      export _MIRZA_ZIP_TMP="$ztmp"
    fi
  fi

  if [[ -z "$src_patch" || ! -d "$src_patch" ]]; then
    info "Downloading patch files from GitHub..."
    local tmp
    tmp="$(mktemp -d)"
    if safe_git_clone "$GITHUB_REPO" "$tmp/repo" 2>/dev/null; then
      src_patch="$tmp/repo/patch"
      export _MIRZA_ZIP_TMP="$tmp"
    else
      err "Could not clone from GitHub: $GITHUB_REPO"
      err "Re-run: curl -fsSL https://raw.githubusercontent.com/silent4time/${PROJECT_NAME}/main/install.sh | sudo bash"
      exit 1
    fi
  fi

  for f in botapi.php function.php index.php admin.php keyboard.php table.php Eylan.php apply_eylan_panels.php eylan_diag.php eylan_wg_diag.php Connectix.php apply_connectix_panels.php apply_fixes.php license_client.php version apply_branding.php; do
    if [[ -f "${src_patch}/${f}" ]]; then
      cp -f "${src_patch}/${f}" "${target}/${f}"
    else
      warn "Patch file missing: $f"
    fi
  done
  if [[ -d "${src_patch}/cronbot" ]]; then
    mkdir -p "${target}/cronbot"
    cp -f "${src_patch}/cronbot/"*.php "${target}/cronbot/" 2>/dev/null || true
  fi
  # هوک‌های پنل ایلان/کانکتیکس و رفع اشکال‌ها در نصب تازه هم باید اجرا شوند
  for p in apply_eylan_panels.php apply_connectix_panels.php apply_fixes.php; do
    if [[ -f "${target}/${p}" ]]; then
      (cd "$target" && timeout 30 php "$p") 2>/dev/null || warn "$p skipped"
    fi
  done
  # برندینگ متن‌های درباره/گزارش ربات
  if [[ -f "${target}/apply_branding.php" && -f "${target}/lang/fa.php" ]]; then
    php "${target}/apply_branding.php" 2>/dev/null || true
  fi
}


write_config() {
  local target="$1"
  local tpl="${SCRIPT_DIR}/patch/config.template.php"
  if [[ ! -f "$tpl" ]]; then
    # از گیت‌هاب یا از خود target بعد از پچ
    if [[ -f "${target}/../patch/config.template.php" ]]; then
      tpl="${target}/../patch/config.template.php"
    elif [[ -f "${SCRIPT_DIR}/patch/config.template.php" ]]; then
      tpl="${SCRIPT_DIR}/patch/config.template.php"
    else
      # اگر فقط در temp کلون شده
      tpl="$(find /tmp -name 'config.template.php' 2>/dev/null | head -1 || true)"
    fi
  fi
  # آخرین تلاش: از داخل ریپوی موقت که apply ممکن است ساخته باشد
  if [[ ! -f "$tpl" ]]; then
    cat > "${target}/config.php" <<CFGEOF
<?php
\$request_exec_timeout = null;
\$dbhost = '127.0.0.1';
\$dbname = '${DB_NAME}';
\$usernamedb = '${DB_USER}';
\$passworddb = '${DB_PASS}';
\$options = [
    PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
    PDO::ATTR_EMULATE_PREPARES => false,
    PDO::MYSQL_ATTR_INIT_COMMAND => "SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci",
];
\$dsn = "mysql:host=\$dbhost;dbname=\$dbname;charset=utf8mb4";
try {
    \$pdo = new PDO(\$dsn, \$usernamedb, \$passworddb, \$options);
} catch (\\PDOException \$e) {
    error_log("Database connection failed: " . \$e->getMessage());
    die("error: database connection failed");
}
\$APIKEY = '${TELEGRAM_TOKEN}';
\$adminnumber = '${ADMIN_ID}';
\$domainhosts = '${DOMAIN:-PENDING}';
\$usernamebot = '${TELEGRAM_USERNAME}';
\$ENABLE_TELEGRAM = ${ENABLE_TELEGRAM};
\$ENABLE_BALE     = ${ENABLE_BALE};
\$TELEGRAM_APIKEY = \$APIKEY;
\$BALE_APIKEY = '${BALE_TOKEN}';
\$BALE_ADMIN_ID = '${BALE_ADMIN_ID}';
\$BALE_REPORT_GROUP_ID = '${BALE_REPORT_GROUP_ID}';
\$BALE_PROVIDER_TOKEN = '${BALE_PROVIDER_TOKEN}';
\$TELEGRAM_API_BASE = 'https://api.telegram.org/bot';
\$BALE_API_BASE     = 'https://tapi.bale.ai/bot';
\$WEBHOOK_SECRET_TOKEN = '${WEBHOOK_SECRET}';
\$LICENSE_ENABLED = true;
\$LICENSE_KEY = '${LICENSE_KEY:-}';
\$LICENSE_API_URL = '${LICENSE_API_URL:-}';
if (!defined('BALE_ID_OFFSET')) {
    define('BALE_ID_OFFSET', 9000000000000);
}
CFGEOF
    return
  fi

  sed \
    -e "s|{{DB_HOST}}|127.0.0.1|g" \
    -e "s|{{DB_NAME}}|${DB_NAME}|g" \
    -e "s|{{DB_USER}}|${DB_USER}|g" \
    -e "s|{{DB_PASS}}|${DB_PASS}|g" \
    -e "s|{{TELEGRAM_TOKEN}}|${TELEGRAM_TOKEN}|g" \
    -e "s|{{ADMIN_ID}}|${ADMIN_ID}|g" \
    -e "s|{{TELEGRAM_USERNAME}}|${TELEGRAM_USERNAME}|g" \
    -e "s|{{ENABLE_TELEGRAM}}|${ENABLE_TELEGRAM}|g" \
    -e "s|{{ENABLE_BALE}}|${ENABLE_BALE}|g" \
    -e "s|{{BALE_TOKEN}}|${BALE_TOKEN}|g" \
    -e "s|{{BALE_ADMIN_ID}}|${BALE_ADMIN_ID:-}|g" \
    -e "s|{{BALE_REPORT_GROUP_ID}}|${BALE_REPORT_GROUP_ID:-}|g" \
    -e "s|{{BALE_PROVIDER_TOKEN}}|${BALE_PROVIDER_TOKEN:-}|g" \
    -e "s|{{WEBHOOK_SECRET}}|${WEBHOOK_SECRET}|g" \
    -e "s|{{DOMAIN}}|${DOMAIN:-PENDING}|g" \
    -e "s|{{LICENSE_KEY}}|${LICENSE_KEY:-}|g" \
    -e "s|{{LICENSE_API_URL}}|${LICENSE_API_URL:-}|g" \
    "$tpl" > "${target}/config.php"
}


# ---------------------------------------------------------------------------
#  Apache vhost for public domain (port 80) + Let's Encrypt SSL
# ---------------------------------------------------------------------------
setup_domain_vhost() {
  local domain="$1"
  domain="${domain#https://}"
  domain="${domain#http://}"
  domain="${domain%%/*}"
  [[ -z "$domain" ]] && return 1

  info "Creating Apache vhost for ${domain}..."
  cat > "/etc/apache2/sites-available/${APACHE_SITE}-domain.conf" <<EOF
<VirtualHost *:80>
    ServerName ${domain}
    DocumentRoot ${INSTALL_DIR}
    DirectoryIndex index.php index.html

    <Directory ${INSTALL_DIR}>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${APACHE_SITE}-domain-error.log
    CustomLog \${APACHE_LOG_DIR}/${APACHE_SITE}-domain-access.log combined
</VirtualHost>
EOF
  a2ensite "${APACHE_SITE}-domain.conf" >/dev/null 2>&1 || true
  apache2ctl configtest >/dev/null 2>&1 && systemctl reload apache2 || true
  ok "HTTP vhost enabled for ${domain}"
}

obtain_ssl() {
  local domain="$1"
  domain="${domain#https://}"
  domain="${domain#http://}"
  domain="${domain%%/*}"
  [[ -z "$domain" ]] && return 1

  info "Installing certbot (if needed)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y certbot python3-certbot-apache >/dev/null 2>&1 || {
    warn "Could not install certbot packages."
    return 1
  }

  info "Waiting for DNS to resolve ${domain} (up to 90s)..."
  local ok_dns=0 i
  for i in $(seq 1 18); do
    if dig -4 +short "$domain" @1.1.1.1 2>/dev/null | grep -Eq '^[0-9]+\.'; then
      ok_dns=1
      break
    fi
    sleep 5
  done
  if [[ "$ok_dns" != "1" ]]; then
    warn "DNS for ${domain} not resolving yet. SSL skipped."
    warn "After DNS works, run Reset menu option 4 (Domain + SSL + webhooks)."
    return 1
  fi
  ok "DNS resolved for ${domain}"

  info "Requesting Let's Encrypt certificate (automatic)..."
  # Non-interactive: agree TOS, no email prompt if possible, redirect HTTP->HTTPS
  if certbot --apache -d "$domain" --non-interactive --agree-tos --register-unsafely-without-email --redirect; then
    ok "SSL active: https://${domain}"
    return 0
  fi

  warn "certbot failed. Common causes: DNS not pointing here, port 80 blocked, Cloudflare proxy orange-cloud."
  warn "Tip: keep Cloudflare record on DNS only (grey cloud), then retry Reset → Domain + SSL."
  return 1
}

setup_connectivity() {
  if [[ "$DOMAIN_MODE" == "2" ]]; then
    info "Setting up Cloudflare tunnel..."
    if ! command -v cloudflared >/dev/null 2>&1; then
      curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
        -o /usr/local/bin/cloudflared
      chmod +x /usr/local/bin/cloudflared
    fi
    mkdir -p "$STATE_DIR"
    cat > "${STATE_DIR}/tunnel.env" <<ENVEOF
INSTALL_DIR="${INSTALL_DIR}"
ENABLE_TELEGRAM="${ENABLE_TELEGRAM}"
TELEGRAM_TOKEN="${TELEGRAM_TOKEN}"
ENABLE_BALE="${ENABLE_BALE}"
BALE_TOKEN="${BALE_TOKEN}"
WEBHOOK_SECRET="${WEBHOOK_SECRET}"
MIRZA_HTTP_PORT="${MIRZA_HTTP_PORT:-8091}"
ENVEOF
    chmod 600 "${STATE_DIR}/tunnel.env"

    cat > "/usr/local/bin/${PROJECT_NAME}-tunnel-refresh.sh" <<'REFRESHEOF'
#!/usr/bin/env bash
set -uo pipefail
source /etc/virabot/tunnel.env
LOGFILE="/var/log/silentsell-cloudflared.log"
: > "$LOGFILE"
cloudflared tunnel --url http://localhost:${MIRZA_HTTP_PORT:-8091} >> "$LOGFILE" 2>&1 &
CF_PID=$!
DOMAIN=""
for i in $(seq 1 30); do
  DOMAIN="$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$LOGFILE" | head -1 | sed 's|https://||')"
  [[ -n "$DOMAIN" ]] && break
  sleep 1
done
if [[ -n "$DOMAIN" ]]; then
  echo "$(date -Is) New tunnel URL: https://$DOMAIN" >> "$LOGFILE"
  sed -i "s|\\\$domainhosts = '.*';|\\\$domainhosts = '${DOMAIN}';|" "${INSTALL_DIR}/config.php" || true
  sleep 8
  register_webhook() {
    local url="$1" label="$2"
    local attempt result
    for attempt in 1 2 3 4 5; do
      result="$(curl -s -F "url=${url}" "$3" || echo '{"ok":false}')"
      echo "$(date -Is) ${label} webhook attempt ${attempt}: ${result}" >> "$LOGFILE"
      if [[ "$result" == *'"ok":true'* ]]; then return 0; fi
      sleep 5
    done
    return 1
  }
  if [[ "$ENABLE_TELEGRAM" == "true" ]]; then
    register_webhook "https://${DOMAIN}/index.php?secret=${WEBHOOK_SECRET}" "Telegram" \
      "https://api.telegram.org/bot${TELEGRAM_TOKEN}/setWebhook"
  fi
  if [[ "$ENABLE_BALE" == "true" ]]; then
    register_webhook "https://${DOMAIN}/index.php?platform=bale&secret=${WEBHOOK_SECRET}" "Bale" \
      "https://tapi.bale.ai/bot${BALE_TOKEN}/setWebhook"
  fi
fi
wait "$CF_PID"
REFRESHEOF
    chmod +x "/usr/local/bin/${PROJECT_NAME}-tunnel-refresh.sh"

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<SERVICEEOF
[Unit]
Description=${PROJECT_NAME} Cloudflare tunnel
After=network-online.target apache2.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/${PROJECT_NAME}-tunnel-refresh.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICEEOF
    systemctl daemon-reload
    systemctl enable --now "${SERVICE_NAME}.service"

    info "Waiting for tunnel (up to 25s)..."
    DOMAIN=""
    for i in $(seq 1 25); do
      DOMAIN="$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' /var/log/${PROJECT_NAME}-cloudflared.log 2>/dev/null | head -1 | sed 's|https://||')"
      [[ -n "$DOMAIN" ]] && break
      sleep 1
    done
    if [[ -z "$DOMAIN" ]]; then
      warn "Tunnel URL not found. Check: systemctl status ${SERVICE_NAME}"
    else
      ok "Tunnel active: https://$DOMAIN"
      sed -i "s|domainhosts = 'PENDING'|domainhosts = '${DOMAIN}'|; s|{{DOMAIN}}|${DOMAIN}|g" "${INSTALL_DIR}/config.php" || true
    fi
  else
    # Own domain: ensure vhost + automatic SSL
    if [[ -z "${DOMAIN:-}" ]]; then
      err "Domain is empty."
      return 1
    fi
    DOMAIN="${DOMAIN#https://}"
    DOMAIN="${DOMAIN#http://}"
    DOMAIN="${DOMAIN%%/*}"
    info "Configuring domain: $DOMAIN"
    setup_domain_vhost "$DOMAIN"
    obtain_ssl "$DOMAIN"
    if [[ -f "${INSTALL_DIR}/config.php" ]]; then
      # Avoid set -u expanding $domainhosts inside double quotes
      sed -i "s|\\\$domainhosts = '.*';|\\\$domainhosts = '${DOMAIN}';|" "${INSTALL_DIR}/config.php" 2>/dev/null || true
    fi
    ok "Domain ready: https://${DOMAIN}"
  fi
}

register_webhooks() {
  if [[ "$DOMAIN_MODE" == "2" ]]; then
    info "Webhooks will be registered by the tunnel service."
    return 0
  fi
  if [[ -z "${DOMAIN:-}" ]]; then
    warn "Domain is empty — webhooks not registered."
    return 0
  fi
  if [[ "$ENABLE_TELEGRAM" == "true" ]]; then
    local r
    r="$(curl -s -F "url=https://${DOMAIN}/index.php?secret=${WEBHOOK_SECRET}" \
      "https://api.telegram.org/bot${TELEGRAM_TOKEN}/setWebhook" || true)"
    info "Telegram webhook: $r"
  fi
  if [[ "$ENABLE_BALE" == "true" ]]; then
    local r
    r="$(curl -s -F "url=https://${DOMAIN}/index.php?platform=bale&secret=${WEBHOOK_SECRET}" \
      "https://tapi.bale.ai/bot${BALE_TOKEN}/setWebhook" || true)"
    info "Bale webhook: $r"
  fi
}

# ===========================================================================
#  ۲) آپدیت
# ===========================================================================
do_update() {
  echo ""
  if has_legacy; then
    info "Old mirza_vali Pro install found — moving it to SilentSell first."
    do_migrate
    if has_legacy; then
      err "Move did not finish; update cancelled."
      return 1
    fi
  fi
  if ! select_instance "update"; then return 1; fi
  apply_instance_identity
  echo -e "${BOLD}=== Update SilentSell (latest) ===${NC}"
  echo ""
  load_state

  if [[ -z "${INSTALL_DIR:-}" || ! -d "${INSTALL_DIR:-}" ]]; then
    err "No active install found. Run Install first."
    return 1
  fi

  local current newv
  current="$(version_of "$INSTALL_DIR")"
  info "Current version on server: v${current}"

  # بک‌آپ فایل‌های حیاتی (بیرون از /home تا پوشه‌ها شلوغ نشود)
  local bak="${BACKUP_ROOT}/${INSTANCE_ID}-update-$(date +%Y%m%d-%H%M%S)"
  info "Creating backup..."
  mkdir -p "$bak"
  chmod 700 "$BACKUP_ROOT" "$bak"
  for f in config.php botapi.php function.php index.php admin.php keyboard.php table.php VERSION; do
    [[ -f "${INSTALL_DIR}/${f}" ]] && cp -a "${INSTALL_DIR}/${f}" "${bak}/" || true
  done
  ok "Backup: $bak"

  local tmp src_patch=""
  tmp="$(mktemp -d)"

  # اولویت ۱: آخرین zip داخل ZIP_DROP_DIR (مثلاً /home/virabot-latest.zip)
  local latest_zip=""
  if [[ -d "${ZIP_DROP_DIR}" ]]; then
    latest_zip="$(ls -1t "${ZIP_DROP_DIR}"/${PROJECT_NAME}*.zip 2>/dev/null | head -1 || true)"
  fi

  if [[ -n "$latest_zip" && -f "$latest_zip" ]]; then
    info "Found local zip: $latest_zip"
    info "Extracting and using as update source..."
    mkdir -p "$tmp/zipout"
    if command -v unzip >/dev/null 2>&1; then
      unzip -qo "$latest_zip" -d "$tmp/zipout"
    else
      apt-get install -y unzip >/dev/null 2>&1 || true
      unzip -qo "$latest_zip" -d "$tmp/zipout"
    fi
    # پیدا کردن پوشه‌ای که patch/ یا manage.sh دارد
    if [[ -d "$tmp/zipout/patch" ]]; then
      src_patch="$tmp/zipout/patch"
      [[ -f "$tmp/zipout/VERSION" ]] && cp -f "$tmp/zipout/VERSION" "$tmp/VERSION" || true
    else
      local found
      found="$(find "$tmp/zipout" -type d -name patch 2>/dev/null | head -1 || true)"
      if [[ -n "$found" ]]; then
        src_patch="$found"
        [[ -f "$(dirname "$found")/VERSION" ]] && cp -f "$(dirname "$found")/VERSION" "$tmp/VERSION" || true
      fi
    fi
  fi

  # اولویت ۲: دانلود virabot-latest.zip از GitHub (ریشه ریپو)
  if [[ -z "$src_patch" ]]; then
    local gh_zip_url="https://raw.githubusercontent.com/silent4time/${PROJECT_NAME}/${GITHUB_BRANCH}/${ZIP_NAME}"
    local gh_zip_url2="https://github.com/silent4time/${PROJECT_NAME}/raw/${GITHUB_BRANCH}/${ZIP_NAME}"
    info "Downloading ${ZIP_NAME} from GitHub..."
    mkdir -p "$tmp/zipout"
    if safe_curl "$gh_zip_url" -o "$tmp/latest.zip" 2>/dev/null || safe_curl "$gh_zip_url2" -o "$tmp/latest.zip" 2>/dev/null; then
      unzip -qo "$tmp/latest.zip" -d "$tmp/zipout" 2>/dev/null || true
      # ممکن است zip بیرونی فقط install + virabot-latest.zip تو در تو داشته باشد
      if [[ ! -d "$tmp/zipout/patch" ]]; then
        local inner
        inner="$(find "$tmp/zipout" -maxdepth 2 -name "${PROJECT_NAME}*.zip" 2>/dev/null | head -1 || true)"
        if [[ -n "$inner" && -f "$inner" ]]; then
          mkdir -p "$tmp/zipinner"
          unzip -qo "$inner" -d "$tmp/zipinner"
          if [[ -d "$tmp/zipinner/patch" ]]; then
            rm -rf "$tmp/zipout"
            mv "$tmp/zipinner" "$tmp/zipout"
          fi
        fi
      fi
      if [[ -d "$tmp/zipout/patch" ]]; then
        src_patch="$tmp/zipout/patch"
        [[ -f "$tmp/zipout/VERSION" ]] && cp -f "$tmp/zipout/VERSION" "$tmp/VERSION" || true
        ok "Update package downloaded from GitHub."
      else
        local found
        found="$(find "$tmp/zipout" -type d -name patch 2>/dev/null | head -1 || true)"
        if [[ -n "$found" ]]; then
          src_patch="$found"
          [[ -f "$(dirname "$found")/VERSION" ]] && cp -f "$(dirname "$found")/VERSION" "$tmp/VERSION" || true
          ok "Update package downloaded from GitHub."
        fi
      fi
    else
      warn "Could not download ${ZIP_NAME} from GitHub."
    fi
  fi

  # اولویت ۳: کلون ریپو (اگر پوشه patch روی گیت‌هاب آپلود شده باشد)
  if [[ -z "$src_patch" ]]; then
    info "Fetching latest from GitHub git: $GITHUB_REPO (branch $GITHUB_BRANCH)..."
    if safe_git_clone "$GITHUB_REPO" "$tmp/repo" 2>/dev/null; then
      if [[ -d "$tmp/repo/patch" ]]; then
        src_patch="$tmp/repo/patch"
        [[ -f "$tmp/repo/VERSION" ]] && cp -f "$tmp/repo/VERSION" "$tmp/VERSION" || true
        ok "Latest version fetched from GitHub."
      else
        # zip داخل کلون
        local z
        z="$(find "$tmp/repo" -maxdepth 2 -name "${ZIP_NAME}" 2>/dev/null | head -1 || true)"
        if [[ -n "$z" ]]; then
          mkdir -p "$tmp/zipout"
          unzip -qo "$z" -d "$tmp/zipout"
          if [[ -d "$tmp/zipout/patch" ]]; then
            src_patch="$tmp/zipout/patch"
            [[ -f "$tmp/zipout/VERSION" ]] && cp -f "$tmp/zipout/VERSION" "$tmp/VERSION" || true
            ok "Extracted patch from repo zip."
          fi
        fi
      fi
    fi
  fi

  if [[ -z "$src_patch" || ! -d "$src_patch" ]]; then
    err "patch/ folder not found in update source."
    err "On GitHub upload file: ${ZIP_NAME} (must contain folder patch/)"
    err "Or put a zip in ${ZIP_DROP_DIR}/"
    rm -rf "$tmp"
    return 1
  fi

  info "Applying patch files..."
  for f in botapi.php function.php index.php admin.php keyboard.php table.php Eylan.php apply_eylan_panels.php eylan_diag.php eylan_wg_diag.php Connectix.php apply_connectix_panels.php apply_fixes.php license_client.php version apply_branding.php; do
    if [[ -f "${src_patch}/${f}" ]]; then
      cp -f "${src_patch}/${f}" "${INSTALL_DIR}/${f}"
      ok "  $f"
    else
      warn "  missing: $f"
    fi
  done
  # cronbot (backup etc.)
  if [[ -d "${src_patch}/cronbot" ]]; then
    mkdir -p "${INSTALL_DIR}/cronbot"
    cp -f "${src_patch}/cronbot/"*.php "${INSTALL_DIR}/cronbot/" 2>/dev/null || true
    ok "  cronbot/"
  fi

  if [[ -f "$tmp/VERSION" ]]; then
    cp -f "$tmp/VERSION" "${INSTALL_DIR}/VERSION"
  elif [[ -f "$(dirname "$src_patch")/VERSION" ]]; then
    cp -f "$(dirname "$src_patch")/VERSION" "${INSTALL_DIR}/VERSION"
  fi
  echo "$PROJECT_NAME" > "${INSTALL_DIR}/PROJECT_NAME"

  chown -R www-data:www-data "$INSTALL_DIR" 2>/dev/null || true

  # Ensure license_client present + seed key from config into PaySetting
  if [[ -f "${INSTALL_DIR}/license_client.php" ]]; then
    ok "  license_client.php"
  else
    warn "  license_client.php missing after update"
  fi
  (cd "$INSTALL_DIR" && php -r '
require "config.php";
if (!isset($pdo)) exit(0);
$key = isset($LICENSE_KEY) ? trim((string)$LICENSE_KEY) : "";
if ($key === "" || strpos($key, "{{") !== false) exit(0);
try {
  $st = $pdo->prepare("SELECT ValuePay FROM PaySetting WHERE NamePay=?");
  $st->execute(["mv_license_key"]);
  $row = $st->fetch(PDO::FETCH_ASSOC);
  if (!$row || trim((string)($row["ValuePay"] ?? "")) === "") {
    $pdo->prepare("INSERT INTO PaySetting (NamePay, ValuePay) VALUES (?, ?) ON DUPLICATE KEY UPDATE ValuePay=VALUES(ValuePay)")->execute(["mv_license_key", $key]);
    echo "license key seeded to DB\n";
  }
} catch (Throwable $e) {}
') 2>/dev/null || true

  info "Syncing database tables (no data loss)..."
  (cd "$INSTALL_DIR" && timeout 60 php table.php) 2>/dev/null || true

  if [[ -f "${INSTALL_DIR}/apply_eylan_panels.php" ]]; then
    info "Applying Eylan panel hooks..."
    (cd "$INSTALL_DIR" && timeout 30 php apply_eylan_panels.php) 2>/dev/null || warn "apply_eylan_panels skipped"
  fi
  if [[ -f "${INSTALL_DIR}/apply_connectix_panels.php" ]]; then
    info "Applying Connectix panel hooks..."
    (cd "$INSTALL_DIR" && timeout 30 php apply_connectix_panels.php) 2>/dev/null || warn "apply_connectix_panels skipped"
  fi
  if [[ -f "${INSTALL_DIR}/apply_fixes.php" ]]; then
    info "Applying bug fixes..."
    (cd "$INSTALL_DIR" && timeout 30 php apply_fixes.php) 2>/dev/null || warn "apply_fixes skipped"
  fi

  # Branding (about / report texts)
  if [[ -f "${INSTALL_DIR}/apply_branding.php" && -f "${INSTALL_DIR}/lang/fa.php" ]]; then
    info "Applying branding..."
    (cd "$INSTALL_DIR" && timeout 15 php apply_branding.php) 2>/dev/null || warn "branding skipped"
  fi

  newv="$(version_of "$INSTALL_DIR")"
  save_state
  rm -rf "$tmp"
  cleanup_stale_install_dirs "$INSTALL_DIR"
  ok "Update done: v${current} -> v${newv}"
  info "If needed, re-register webhooks from the Reset menu."
}


# ===========================================================================
#  ۳) ریست
# ===========================================================================
do_reset() {
  echo ""
  if ! select_instance "reset"; then return 1; fi
  apply_instance_identity
  echo -e "${BOLD}=== Reset SilentSell ===${NC}"
  echo ""
  load_state

  if [[ -z "${INSTALL_DIR:-}" || ! -d "${INSTALL_DIR:-}" ]]; then
    err "No active install found."
    return 1
  fi

  echo "What should be reset?"
  echo "  1) Re-register webhooks only"
  echo "  2) Restart tunnel service + webhooks"
  echo "  3) Clear user steps (stuck menus) — step field only"
  echo "  4) Set domain + auto SSL + webhooks"
  echo "  0) Cancel"
  local choice
  read -rp "Choice: " choice

  case "$choice" in
    1)
      DOMAIN_MODE="${DOMAIN_MODE:-1}"
      register_webhooks
      ok "Webhooks re-registered."
      ;;
    2)
      if systemctl list-unit-files | grep -q "${SERVICE_NAME}"; then
        systemctl restart "${SERVICE_NAME}" || true
        ok "Tunnel service restarted."
        sleep 5
        DOMAIN="$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' /var/log/${PROJECT_NAME}-cloudflared.log 2>/dev/null | head -1 | sed 's|https://||' || true)"
        if [[ -n "$DOMAIN" ]]; then
          sed -i "s|\\\$domainhosts = '.*';|\\\$domainhosts = '${DOMAIN}';|" "${INSTALL_DIR}/config.php" || true
          ok "New tunnel URL: https://$DOMAIN"
        fi
      else
        warn "Tunnel service not installed (you may be using your own domain)."
        register_webhooks
      fi
      ;;
    3)
      if [[ -n "${DB_NAME:-}" && -n "${DB_USER:-}" && -n "${DB_PASS:-}" ]]; then
        mysql -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" -e "UPDATE user SET step='home' WHERE step NOT IN ('home','none','');" 2>/dev/null \
          && ok "User steps reset." \
          || err "Database connection error."
      else
        err "Database credentials not found in state file."
      fi
      ;;
    4)
      DOMAIN="$(ask 'Domain (without https://)' "${DOMAIN:-bot.example.com}")"
      DOMAIN="${DOMAIN#https://}"
      DOMAIN="${DOMAIN#http://}"
      DOMAIN="${DOMAIN%%/*}"
      DOMAIN_MODE="1"
      setup_domain_vhost "$DOMAIN"
      obtain_ssl "$DOMAIN"
      sed -i "s|\\\$domainhosts = '.*';|\\\$domainhosts = '${DOMAIN}';|" "${INSTALL_DIR}/config.php" || true
      save_state
      register_webhooks
      ok "Domain/SSL/webhooks done for https://${DOMAIN}"
      ;;
    *) info "Cancelled." ;;
  esac
}

# ===========================================================================
#  ۴) حذف کامل
# ===========================================================================
do_remove() {
  echo ""
  if ! select_instance "remove"; then return 1; fi
  apply_instance_identity
  echo -e "${BOLD}${RED}=== Full remove SilentSell ===${NC}"
  echo ""
  load_state

  warn "This cannot be undone. It will remove:"
  echo "  - Install folder: ${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
  echo "  - Database: ${DB_NAME:-?}"
  echo "  - Tunnel service and Apache site"
  echo "  - State files in $STATE_DIR"
  echo ""
  local conf
  conf="$(ask_yn 'Are you sure? Delete everything?' 'n')"
  [[ "$conf" != "true" ]] && { info "Cancelled."; return 0; }

  # وبهوک را حذف کن
  if [[ "${ENABLE_TELEGRAM:-}" == "true" && -n "${TELEGRAM_TOKEN:-}" && "$TELEGRAM_TOKEN" != "disabled" ]]; then
    curl -s "https://api.telegram.org/bot${TELEGRAM_TOKEN}/deleteWebhook" >/dev/null || true
  fi
  if [[ "${ENABLE_BALE:-}" == "true" && -n "${BALE_TOKEN:-}" && "$BALE_TOKEN" != "disabled" ]]; then
    curl -s "https://tapi.bale.ai/bot${BALE_TOKEN}/deleteWebhook" >/dev/null || true
  fi

  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload 2>/dev/null || true
  rm -f "/usr/local/bin/${PROJECT_NAME}-tunnel-refresh.sh"
  rm -f "/var/log/${PROJECT_NAME}-cloudflared.log"

  a2dissite "${APACHE_SITE}.conf" >/dev/null 2>&1 || a2dissite "${APACHE_SITE}" >/dev/null 2>&1 || true
  a2disconf "${APACHE_SITE}-port" >/dev/null 2>&1 || true
  rm -f "/etc/apache2/sites-available/${APACHE_SITE}.conf"
  rm -f "/etc/apache2/sites-enabled/${APACHE_SITE}.conf"
  rm -f "/etc/apache2/sites-available/${APACHE_SITE}-domain.conf"
  rm -f "/etc/apache2/sites-enabled/${APACHE_SITE}-domain.conf"
  rm -f "/etc/apache2/conf-available/${APACHE_SITE}-port.conf"
  rm -f "/etc/apache2/conf-enabled/${APACHE_SITE}-port.conf"
  a2dissite "${APACHE_SITE}-domain.conf" >/dev/null 2>&1 || true
  apache2ctl configtest >/dev/null 2>&1 && systemctl reload apache2 2>/dev/null || true

  if [[ -n "${INSTALL_DIR:-}" && -d "${INSTALL_DIR}" ]]; then
    rm -rf "${INSTALL_DIR}"
    ok "Install folder removed."
  fi

  if [[ -n "${DB_NAME:-}" ]]; then
    mysql -uroot -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`;" 2>/dev/null || true
    if [[ -n "${DB_USER:-}" && "$DB_USER" != "root" ]]; then
      mysql -uroot -e "DROP USER IF EXISTS '${DB_USER}'@'localhost';" 2>/dev/null || true
    fi
    ok "Database removed."
  fi

  # remove only this instance state (keep other instances)
  rm -f "$(instance_state_file "$INSTANCE_ID")"
  # refresh active pointer
  local remaining
  remaining="$(list_instance_ids | head -1 || true)"
  if [[ -n "$remaining" ]]; then
    cp -f "$(instance_state_file "$remaining")" "${STATE_DIR}/install.env"
  else
    rm -f "${STATE_DIR}/install.env"
  fi
  # do not delete whole STATE_DIR if other instances remain
  if [[ -z "$(list_instance_ids)" ]]; then
    rm -rf "$STATE_DIR"
  fi
  ok "Full removal complete."
}


# ===========================================================================
#  Renew SSL (like official Mirza menu option 5)
# ===========================================================================
do_renew_ssl() {
  echo ""
  if ! select_instance "ssl"; then return 1; fi
  apply_instance_identity
  echo -e "${BOLD}=== Renew SSL certificate ===${NC}"
  echo ""
  load_state

  local domain="${DOMAIN:-}"
  if [[ -z "$domain" && -n "${INSTALL_DIR:-}" && -f "${INSTALL_DIR}/config.php" ]]; then
    domain="$(grep -E '\\\$domainhosts' "${INSTALL_DIR}/config.php" 2>/dev/null | head -1 | cut -d"'" -f2 || true)"
  fi
  if [[ -z "$domain" ]]; then
    domain="$(ask 'Domain (without https://)' '')"
  fi
  domain="${domain#https://}"; domain="${domain#http://}"; domain="${domain%%/*}"
  if [[ -z "$domain" ]]; then
    err "No domain provided."
    return 1
  fi

  info "Domain: $domain"
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y certbot python3-certbot-apache >/dev/null 2>&1 || true

  if [[ -d "/etc/letsencrypt/live/${domain}" ]]; then
    info "Existing certificate found — renewing..."
    if certbot renew --cert-name "$domain" --non-interactive; then
      ok "Certificate renewed for $domain"
    else
      warn "certbot renew failed — trying full re-issue..."
      certbot --apache -d "$domain" --non-interactive --agree-tos --register-unsafely-without-email --redirect || {
        err "SSL renew failed. Check DNS and port 80."
        return 1
      }
    fi
  else
    info "No existing cert — requesting new certificate..."
    setup_domain_vhost "$domain"
    obtain_ssl "$domain" || return 1
  fi

  systemctl reload apache2 2>/dev/null || true
  if [[ -n "${INSTALL_DIR:-}" && -f "${INSTALL_DIR}/config.php" ]]; then
    sed -i "s|\\\$domainhosts = '.*';|\\\$domainhosts = '${domain}';|" "${INSTALL_DIR}/config.php" || true
  fi
  DOMAIN="$domain"
  DOMAIN_MODE="1"
  save_state 2>/dev/null || true
  ok "SSL ready: https://${domain}"
}


# ===========================================================================
#  8) Configure Telegram / Bale bots & groups
# ===========================================================================
do_configure_platforms() {
  echo ""
  if ! select_instance "configure"; then return 1; fi
  apply_instance_identity
  echo -e "${BOLD}=== Configure bots & groups ===${NC}"
  echo ""
  load_state
  if [[ -z "${INSTALL_DIR:-}" || ! -d "${INSTALL_DIR:-}" ]]; then
    err "No active install found. Run Install first."
    return 1
  fi

  echo "  Current:"
  echo "    Telegram bot:   ${TELEGRAM_USERNAME:-?} / token set=$([ -n "${TELEGRAM_TOKEN:-}" ] && [ "${TELEGRAM_TOKEN}" != disabled ] && echo yes || echo no)"
  echo "    Telegram admin: ${ADMIN_ID:-?}"
  echo "    Telegram group: ${TELEGRAM_REPORT_GROUP_ID:-$(grep -oP "Channel_Report.?=.?\\K[^,]*" 2>/dev/null || echo '?')}"
  echo "    Bale token:     $([ -n "${BALE_TOKEN:-}" ] && [ "${BALE_TOKEN}" != disabled ] && echo yes || echo no)"
  echo "    Bale admin:     ${BALE_ADMIN_ID:-?}"
  echo "    Bale group:     ${BALE_REPORT_GROUP_ID:-?}"
  echo ""
  echo "  1) Change Telegram bot (token / username / admin ID number + webhook)"
  echo "  2) Change Telegram report group (ID number)"
  echo "  3) Change Bale bot (token / admin ID number + webhook)"
  echo "  4) Change Bale report group (ID number)"
  echo "  0) Back"
  echo ""
  local c
  read -rp "  Select: " c
  case "$c" in
    1)
      ENABLE_TELEGRAM="true"
      TELEGRAM_TOKEN="$(ask 'Telegram bot token (BotFather)' "${TELEGRAM_TOKEN:-}")"
      TELEGRAM_USERNAME="$(ask 'Telegram bot username (without @)' "${TELEGRAM_USERNAME:-}")"
      ADMIN_ID="$(ask_id_number 'Telegram admin ID number' "${ADMIN_ID:-}")"
      # config.php
      if [[ -f "${INSTALL_DIR}/config.php" ]]; then
        sed -i "s|\\\$APIKEY = '.*';|\\\$APIKEY = '${TELEGRAM_TOKEN}';|" "${INSTALL_DIR}/config.php" 2>/dev/null || true
        sed -i "s|\\\$TELEGRAM_APIKEY = '.*';|\\\$TELEGRAM_APIKEY = '${TELEGRAM_TOKEN}';|" "${INSTALL_DIR}/config.php" 2>/dev/null || true
        sed -i "s|\\\$usernamebot = '.*';|\\\$usernamebot = '${TELEGRAM_USERNAME}';|" "${INSTALL_DIR}/config.php" 2>/dev/null || true
        # admin id in admin table / config if present
        sed -i "s|\\\$adminnumber = '.*';|\\\$adminnumber = '${ADMIN_ID}';|" "${INSTALL_DIR}/config.php" 2>/dev/null || true
        sed -i "s|\\\$adminnumber = [0-9]*;|\\\$adminnumber = ${ADMIN_ID};|" "${INSTALL_DIR}/config.php" 2>/dev/null || true
      fi
      if [[ -n "${DB_USER:-}" && -n "${DB_NAME:-}" ]]; then
        mysql -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" -e \
          "UPDATE admin SET id_admin='${ADMIN_ID}' WHERE id_admin IS NOT NULL LIMIT 1;" 2>/dev/null || true
      fi
      save_state
      register_webhooks
      ok "Telegram bot settings updated + webhook re-registered."
      ;;
    2)
      TELEGRAM_REPORT_GROUP_ID="$(ask_id_number 'Telegram report group ID number' "${TELEGRAM_REPORT_GROUP_ID:-}")"
      if [[ -n "${DB_USER:-}" && -n "${DB_NAME:-}" ]]; then
        mysql -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" -e \
          "UPDATE setting SET Channel_Report='${TELEGRAM_REPORT_GROUP_ID}';" 2>/dev/null \
          && ok "Telegram report group saved: ${TELEGRAM_REPORT_GROUP_ID}" \
          || err "Could not update setting.Channel_Report"
      fi
      save_state
      ;;
    3)
      ENABLE_BALE="true"
      BALE_TOKEN="$(ask 'Bale bot token (my.bale.ai)' "${BALE_TOKEN:-}")"
      BALE_ADMIN_ID="$(ask_id_number 'Bale admin ID number' "${BALE_ADMIN_ID:-}")"
      if [[ -f "${INSTALL_DIR}/config.php" ]]; then
        sed -i "s|\\\$BALE_APIKEY = '.*';|\\\$BALE_APIKEY = '${BALE_TOKEN}';|" "${INSTALL_DIR}/config.php" 2>/dev/null || true
        sed -i "s|\\\$BALE_ADMIN_ID = '.*';|\\\$BALE_ADMIN_ID = '${BALE_ADMIN_ID}';|" "${INSTALL_DIR}/config.php" 2>/dev/null || true
        sed -i "s|\\\$ENABLE_BALE = .*;|\\\$ENABLE_BALE = true;|" "${INSTALL_DIR}/config.php" 2>/dev/null || true
      fi
      if [[ -n "${DB_USER:-}" && -n "${DB_NAME:-}" ]]; then
        mysql -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" -e \
          "UPDATE PaySetting SET ValuePay='${BALE_TOKEN}' WHERE NamePay='bale_bot_token';" 2>/dev/null || true
        mysql -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" -e \
          "UPDATE PaySetting SET ValuePay='${BALE_ADMIN_ID}' WHERE NamePay='bale_admin_id';" 2>/dev/null || true
      fi
      save_state
      register_webhooks
      ok "Bale bot settings updated + webhook re-registered."
      ;;
    4)
      BALE_REPORT_GROUP_ID="$(ask_id_number 'Bale report group ID number' "${BALE_REPORT_GROUP_ID:-}")"
      if [[ -f "${INSTALL_DIR}/config.php" ]]; then
        sed -i "s|\\\$BALE_REPORT_GROUP_ID = '.*';|\\\$BALE_REPORT_GROUP_ID = '${BALE_REPORT_GROUP_ID}';|" "${INSTALL_DIR}/config.php" 2>/dev/null || true
      fi
      if [[ -n "${DB_USER:-}" && -n "${DB_NAME:-}" ]]; then
        mysql -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" -e \
          "UPDATE PaySetting SET ValuePay='${BALE_REPORT_GROUP_ID}' WHERE NamePay='bale_report_group_id';" 2>/dev/null || true
      fi
      save_state
      ok "Bale report group ID number saved: ${BALE_REPORT_GROUP_ID}"
      ;;
    0|*) info "Back." ;;
  esac
}

# ===========================================================================
#  Help & Parameters (like official Mirza menu option 6)
# ===========================================================================
do_help() {
  echo ""
  echo -e "${BOLD}=== Help & Parameters ===${NC}"
  echo ""
  echo "  One-liner (from any directory):"
  echo "    curl -fsSL https://raw.githubusercontent.com/silent4time/${PROJECT_NAME}/main/install.sh | sudo bash"
  echo ""
  echo "  CLI commands:  sudo ${PROJECT_NAME} <command>"
  echo "    install   — Install SilentSell"
  echo "    update    — Update from GitHub zip"
  echo "    migrate   — Move an old mirza_vali Pro install (add --dry-run to only show the plan)"
  echo "    remove    — Full uninstall"
  echo "    reset     — Webhooks / tunnel / domain tools"
  echo "    renew     — Renew SSL certificate"
  echo "    status    — System status"
  echo "    help      — This screen"
  echo ""
  echo "  Paths:"
  echo "    Bot:     ${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
  echo "    State:   ${STATE_DIR}"
  echo "    Source:  /opt/${PROJECT_NAME}-src"
  echo "    Backups: ${BACKUP_ROOT}"
  echo "    Apache:  port 8091 + domain vhost :80/:443"
  echo ""
  echo "  Notes:"
  echo "    - Dual platform: Telegram + Bale"
  echo "    - Uses Apache (not Nginx) to avoid conflict with other bots"
  echo "    - Database tables are verified during install"
  echo "    - Official Mirza 'Free→Pro migrate' is NOT applicable here"
  echo ""
}

# ===========================================================================
#  ۵) وضعیت
# ===========================================================================

do_list_instances() {
  echo ""
  echo -e "${BOLD}=== Installed instances ===${NC}"
  mkdir -p "$INSTANCES_DIR"
  local ids=()
  mapfile -t ids < <(list_instance_ids)
  if [[ ${#ids[@]} -eq 0 ]]; then
    if [[ -f "${STATE_DIR}/install.env" ]]; then
      load_state
      echo "  (legacy) path=${INSTALL_DIR:-?} domain=${DOMAIN:-?} db=${DB_NAME:-?}"
    else
      echo "  None."
    fi
    return 0
  fi
  local id
  for id in "${ids[@]}"; do
    # shellcheck disable=SC1090
    source "$(instance_state_file "$id")"
    echo "  -- $id"
    echo "     path:    ${INSTALL_DIR:-?}"
    echo "     domain:  ${DOMAIN:-?}"
    echo "     db:      ${DB_NAME:-?} / ${DB_USER:-?}"
    echo "     port:    ${MIRZA_HTTP_PORT:-?}"
    echo "     apache:  ${APACHE_SITE:-mv-$id}"
    echo "     version: ${INSTALLED_VERSION:-?}"
    echo ""
  done
  info "Update/Remove/Reset will ask which instance when more than one exists."
}

do_status() {
  echo ""
  echo -e "${BOLD}=== System status ===${NC}"
  echo ""
  load_state

  echo "  Project:         $PROJECT_NAME"
  echo "  Script version:  v$(version_of "$SCRIPT_DIR")"
  if [[ -f "$STATE_FILE" ]]; then
    echo "  Installed ver:   v${INSTALLED_VERSION:-?}"
    echo "  Path:            ${INSTALL_DIR:-?}"
    echo "  Domain:          ${DOMAIN:-?}"
    echo "  Telegram:        ${ENABLE_TELEGRAM:-?}"
    echo "  Bale:            ${ENABLE_BALE:-?}"
    echo "  Database:        ${DB_NAME:-?} / ${DB_USER:-?}"
    echo "  Installed at:    ${INSTALLED_AT:-?}"
  else
    echo "  Install:         Not installed"
  fi
  echo ""
  echo "  Services:"
  if systemctl is-active --quiet apache2 2>/dev/null; then
    ok "apache2 is active"
  else
    warn "apache2 inactive or not installed"
  fi
  if systemctl is-active --quiet mariadb 2>/dev/null || systemctl is-active --quiet mysql 2>/dev/null; then
    ok "mariadb/mysql is active"
  else
    warn "database inactive"
  fi
  if systemctl list-unit-files 2>/dev/null | grep -q "${SERVICE_NAME}"; then
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
      ok "Cloudflare tunnel is active"
    else
      warn "Cloudflare tunnel installed but inactive"
    fi
  else
    info "Cloudflare tunnel not installed (likely custom domain)"
  fi
  echo ""
}

# ===========================================================================
#  Move an old mirza_vali Pro install to SilentSell (same domain, DB, bots)
# ===========================================================================
install_command() {
  local src="/opt/${PROJECT_NAME}-src/manage.sh"
  [[ -f "$src" ]] || src="${SCRIPT_DIR}/manage.sh"
  chmod +x "$src" 2>/dev/null || true
  ln -sf "$src" "/usr/local/bin/${PROJECT_NAME}" 2>/dev/null || true
}

legacy_instances() {
  local f
  for f in "${LEGACY_STATE_DIR}"/instances/*.env; do
    [[ -f "$f" ]] && echo "$f"
  done
  return 0
}

has_legacy() {
  [[ -n "$(legacy_instances)" ]]
}

# /home/mirza_vali_pro -> /home/virabot, /home/mirza_vali_pro2 -> /home/virabot2; other paths stay
migrated_path() {
  local p="$1" base
  base="$(basename "$p")"
  if [[ "$base" == "${LEGACY_NAME}"* ]]; then
    echo "$(dirname "$p")/${PROJECT_NAME}${base#"$LEGACY_NAME"}"
  else
    echo "$p"
  fi
}

site_files() {
  local site="$1" f
  for f in "/etc/apache2/sites-available/${site}.conf" \
           "/etc/apache2/sites-available/${site}-domain.conf" \
           "/etc/apache2/sites-available/${site}-domain-le-ssl.conf" \
           "/etc/apache2/conf-available/${site}-port.conf"; do
    [[ -f "$f" ]] && echo "$f"
  done
  return 0
}

is_enabled() {
  local f="$1"
  if [[ "$f" == */conf-available/* ]]; then
    [[ -e "/etc/apache2/conf-enabled/$(basename "$f")" ]]
  else
    [[ -e "/etc/apache2/sites-enabled/$(basename "$f")" ]]
  fi
}

apache_toggle() {
  local action="$1" f="$2" name
  name="$(basename "$f" .conf)"
  if [[ "$f" == */conf-available/* ]]; then
    "a2${action}conf" -q "$name" >/dev/null 2>&1 || true
  else
    "a2${action}site" -q "$name" >/dev/null 2>&1 || true
  fi
}

# Proves that Apache serves DIR for this instance (own domain, or the instance port for tunnels)
probe_install() {
  local dir="$1" domain="$2" mode="$3" port="$4" name body=""
  name="ss-probe-$(openssl rand -hex 6).html"
  echo "ok-${name}" > "${dir}/${name}"
  chmod 644 "${dir}/${name}"
  if [[ "$mode" == "1" && -n "$domain" ]]; then
    body="$(curl -skL --max-time 15 --resolve "${domain}:443:127.0.0.1" --resolve "${domain}:80:127.0.0.1" "http://${domain}/${name}" 2>/dev/null || true)"
  elif [[ -n "$port" ]]; then
    body="$(curl -s --max-time 15 "http://127.0.0.1:${port}/${name}" 2>/dev/null || true)"
  fi
  rm -f "${dir}/${name}"
  [[ "$body" == "ok-${name}" ]]
}

dump_database() {
  local db="$1" user="$2" pass="$3" out="$4"
  if mysqldump --single-transaction --quick --routines --triggers "$db" 2>/dev/null | gzip > "$out" && zgrep -q 'CREATE TABLE' "$out"; then
    return 0
  fi
  MYSQL_PWD="$pass" mysqldump -u"$user" --single-transaction --quick --no-tablespaces "$db" 2>/dev/null | gzip > "$out" && zgrep -q 'CREATE TABLE' "$out"
}

# Runs in a subshell so a failure cannot leave half-set variables behind
migrate_one() (
  set -eE -o pipefail
  local envf="$1" dry="$2"
  INSTALL_DIR=""; DOMAIN=""; DOMAIN_MODE=""; APACHE_SITE=""; MIRZA_HTTP_PORT=""
  DB_NAME=""; DB_USER=""; DB_PASS=""
  # shellcheck disable=SC1090
  source "$envf"
  local old_dir="${INSTALL_DIR%/}" old_site="${APACHE_SITE:-}"
  [[ -n "$old_site" ]] || old_site="mv-$(instance_id_from_path "$old_dir")"
  local new_dir
  new_dir="$(migrated_path "$old_dir")"
  INSTALL_DIR="$new_dir"
  apply_instance_identity
  local new_site="$APACHE_SITE" new_id="$INSTANCE_ID"
  local bdir="${BACKUP_ROOT}/migrate-${new_id}-$(date +%Y%m%d-%H%M%S)"
  local files=() f
  mapfile -t files < <(site_files "$old_site")

  echo ""
  echo -e "${BOLD}  ${old_dir}  ->  ${new_dir}${NC}"
  echo "    domain:   ${DOMAIN:-none}   (mode ${DOMAIN_MODE:-?}, port ${MIRZA_HTTP_PORT:-?})"
  echo "    database: ${DB_NAME:-?}  (kept as is)"
  echo "    apache:   ${old_site}* -> ${new_site}*"
  for f in "${files[@]}"; do
    echo "              $(basename "$f")$(is_enabled "$f" && echo '  [enabled]' || true)"
  done
  echo "    settings: ${envf} -> $(instance_state_file "$new_id")"
  echo "    backup:   ${bdir}/  (files, database, settings, apache)"

  [[ -d "$old_dir" ]] || { err "Install folder not found: $old_dir"; exit 1; }
  if [[ "$new_dir" != "$old_dir" && -e "$new_dir" ]]; then
    err "Target already exists: $new_dir"
    exit 1
  fi
  [[ ${#files[@]} -gt 0 ]] || { err "No Apache files named ${old_site}*; cannot move safely."; exit 1; }

  if [[ "$dry" == "true" ]]; then
    if probe_install "$old_dir" "${DOMAIN:-}" "${DOMAIN_MODE:-1}" "${MIRZA_HTTP_PORT:-}"; then
      ok "Check: ${old_dir} answers on ${DOMAIN:-port ${MIRZA_HTTP_PORT:-?}} (the after-move test will work)"
    else
      warn "Check: could not confirm that ${old_dir} answers on ${DOMAIN:-port ${MIRZA_HTTP_PORT:-?}}"
    fi
    exit 0
  fi

  mkdir -p "${bdir}/apache"
  chmod 700 "$BACKUP_ROOT" "$bdir"
  info "Backup: files..."
  tar -czf "${bdir}/files.tgz" -C "$(dirname "$old_dir")" "$(basename "$old_dir")"
  info "Backup: database ${DB_NAME}..."
  dump_database "$DB_NAME" "$DB_USER" "$DB_PASS" "${bdir}/db.sql.gz" || { err "Database backup failed; nothing changed."; exit 1; }
  cp -a "$LEGACY_STATE_DIR" "${bdir}/settings"
  for f in "${files[@]}"; do cp -a "$f" "${bdir}/apache/"; done
  ok "Backup ready: ${bdir}"

  local new_files=() was_enabled=() nf
  rollback() {
    trap - ERR
    err "$1 — undoing..."
    for nf in "${new_files[@]}"; do apache_toggle dis "$nf"; rm -f "$nf"; done
    for f in "${was_enabled[@]}"; do apache_toggle en "$f"; done
    apache2ctl configtest >/dev/null 2>&1 && systemctl reload apache2 || true
    if [[ "$new_dir" != "$old_dir" ]]; then rm -rf "$new_dir"; fi
    err "Nothing changed: the bot still runs from ${old_dir}. Backup: ${bdir}"
    exit 1
  }
  trap 'rollback "unexpected error (line $LINENO)"' ERR

  if [[ "$new_dir" != "$old_dir" ]]; then
    info "Copying ${old_dir} -> ${new_dir}..."
    cp -a "$old_dir" "$new_dir"
  fi
  for f in "${files[@]}"; do
    nf="$(dirname "$f")/$(basename "$f" | sed "s#^${old_site}#${new_site}#")"
    sed -e "s#${old_dir}#${new_dir}#g" -e "s#${old_site}#${new_site}#g" "$f" > "$nf"
    new_files+=("$nf")
    if is_enabled "$f"; then
      was_enabled+=("$f")
      apache_toggle dis "$f"
      apache_toggle en "$nf"
    fi
  done
  apache2ctl configtest >/dev/null 2>&1 || rollback "Apache config test failed"
  systemctl reload apache2 || rollback "Apache reload failed"
  sleep 2
  probe_install "$new_dir" "${DOMAIN:-}" "${DOMAIN_MODE:-1}" "${MIRZA_HTTP_PORT:-}" \
    || rollback "the bot did not answer from ${new_dir}"
  ok "Apache now serves ${new_dir}"
  trap - ERR

  local u
  for u in root www-data; do
    if crontab -u "$u" -l 2>/dev/null | grep -qF "$old_dir"; then
      crontab -u "$u" -l > "${bdir}/crontab-${u}"
      sed "s#${old_dir}#${new_dir}#g" "${bdir}/crontab-${u}" | crontab -u "$u" -
      ok "Cron paths updated for ${u}"
    fi
  done

  GITHUB_REPO="https://github.com/silent4time/${PROJECT_NAME}.git"
  echo "$PROJECT_NAME" > "${new_dir}/PROJECT_NAME"
  chown -R www-data:www-data "$new_dir" 2>/dev/null || true
  save_state
  for f in "${files[@]}"; do rm -f "$f"; done
  if [[ "$new_dir" != "$old_dir" ]]; then
    mv "$old_dir" "${bdir}/old-install"
  fi
  rm -f "$envf"
  ok "Moved: ${old_dir} -> ${new_dir}  (old folder kept in ${bdir}/old-install)"
)

do_migrate() {
  local dry="false"
  [[ "${1:-}" == "--dry-run" || "${1:-}" == "-n" ]] && dry="true"
  echo ""
  echo -e "${BOLD}=== Move mirza_vali Pro -> SilentSell ===${NC}"
  local envs=() e rc
  mapfile -t envs < <(legacy_instances)
  if [[ ${#envs[@]} -eq 0 ]]; then
    info "No old mirza_vali Pro install found."
    install_command
    return 0
  fi
  [[ "$dry" == "true" ]] && info "Dry run — nothing will be changed."
  for e in "${envs[@]}"; do
    set +e
    migrate_one "$e" "$dry"
    rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
      err "Stopped."
      return 1
    fi
  done
  [[ "$dry" == "true" ]] && return 0

  local bdir="${BACKUP_ROOT}/legacy-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$bdir"
  chmod 700 "$bdir"
  [[ -d "$LEGACY_STATE_DIR" ]] && mv "$LEGACY_STATE_DIR" "${bdir}/etc-${LEGACY_NAME}"
  if [[ -d "/opt/${LEGACY_NAME}-src" && "$(readlink -f "$SCRIPT_DIR")" != "/opt/${LEGACY_NAME}-src" ]]; then
    mv "/opt/${LEGACY_NAME}-src" "${bdir}/src"
  fi
  [[ -L "/usr/local/bin/${LEGACY_NAME}" ]] && rm -f "/usr/local/bin/${LEGACY_NAME}"
  if systemctl list-unit-files 2>/dev/null | grep -q "^${LEGACY_NAME}-tunnel"; then
    warn "Old tunnel service ${LEGACY_NAME}-tunnel is still installed; run Reset > 2 for the new one."
  fi
  install_command
  ok "Done. Manage the bot with:  sudo ${PROJECT_NAME}"
  return 0
}

# ===========================================================================
#  Main loop
# ===========================================================================
main() {
  need_root
  _bootstrap_source
  _reexec_if_piped "$@"

  # Direct arguments (non-interactive flags still work after re-exec)
  case "${1:-}" in
    install) do_install; exit 0 ;;
    update)  do_update;  exit 0 ;;
    migrate) do_migrate "${2:-}"; exit 0 ;;
    reset)   do_reset;   exit 0 ;;
    remove|uninstall) do_remove; exit 0 ;;
    renew|ssl) do_renew_ssl; exit 0 ;;
    status)  do_status;  exit 0 ;;
    help|--help|-h) do_help; exit 0 ;;
  esac

  while true; do
    show_banner
    show_menu
    local choice
    read -rp "  Select option: " choice
    case "$choice" in
      1) do_install; pause ;;
      2) do_update;  pause ;;
      3) do_remove;  pause ;;
      4) do_reset;   pause ;;
      5) do_renew_ssl; pause ;;
      6) do_help; pause ;;
      7) do_status;  pause ;;
      8) do_configure_platforms; pause ;;
      9) do_list_instances; pause ;;
      10) do_migrate; pause ;;
      0|q|Q)
        echo ""
        info "Exiting. Goodbye."
        exit 0
        ;;
      *)
        warn "Invalid option."
        sleep 1
        ;;
    esac
  done
}

main "$@"
