#!/usr/bin/env bash
# ============================================================================
#  install-hermes.sh — Hermes Agent + Telegram dalam satu perintah
#
#  Versi "satu baris" dari role Ansible:
#  https://github.com/zahwaptr/ansible-hermes-agent-zhwaptr
#
#  Pemakaian (interaktif, ditanya token & API key):
#    curl -fsSL https://get.zahwajuliana.web.id/install-hermes.sh | bash
#
#  Tanpa pertanyaan (cocok untuk otomatisasi):
#    curl -fsSL https://get.zahwajuliana.web.id/install-hermes.sh | \
#      TELEGRAM_BOT_TOKEN="123:ABC..." TELEGRAM_ALLOWED_USERS="6xxxxxxx5" \
#      HERMES_PROVIDER=deepseek DEEPSEEK_API_KEY="sk-..." bash
#
#  Yang dikerjakan (sama urutannya dengan role Ansible):
#    1. Cek OS (Ubuntu/Debian via apt, Rocky/RHEL via dnf) dan systemd
#    2. Pasang paket dasar, buat user khusus "hermes" bila dijalankan sebagai root
#    3. Pasang Hermes Agent lewat installer resmi Nous Research
#    4. Tulis ~/.hermes/.env (token Telegram, user ID, API key), permission 0600
#    5. Atur provider & model AI (DeepSeek atau OpenRouter)
#    6. Pasang systemd service "hermes-agent" (gateway Telegram, jalan terus)
#
#  Aman dijalankan ulang (idempotent): Hermes yang sudah terpasang tidak
#  dipasang ulang, nilai di .env diperbarui tanpa duplikat, service di-restart.
#
#  Variabel opsional:
#    HERMES_USER            user Linux untuk agent (default: hermes jika root, atau user sekarang)
#    HERMES_PROVIDER        deepseek | openrouter            (default: deepseek)
#    HERMES_MODEL           nama model (default: deepseek-chat / deepseek/deepseek-v4-flash)
#    TELEGRAM_HOME_CHANNEL  chat tujuan laporan otomatis (default: = TELEGRAM_ALLOWED_USERS)
#    HERMES_SERVICE_NAME    nama service systemd (default: hermes-agent)
#    HERMES_SKIP_SERVICE=1  jangan pasang systemd service
# ============================================================================
set -euo pipefail

# Seluruh skrip dibungkus fungsi main dan baru dipanggil di baris terakhir,
# jadi kalau unduhan lewat curl terputus di tengah jalan, tidak ada perintah
# setengah jadi yang ikut tereksekusi.

HERMES_INSTALL_URL="${HERMES_INSTALL_URL:-https://hermes-agent.nousresearch.com/install.sh}"

# ---------- tampilan ----------
if [ -t 1 ]; then
  C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_C=$'\033[36m'; C_0=$'\033[0m'
else
  C_B=""; C_G=""; C_Y=""; C_R=""; C_C=""; C_0=""
fi
step() { printf '\n%s==>%s %s%s%s\n' "$C_C" "$C_0" "$C_B" "$*" "$C_0"; }
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '\n%s✘ %s%s\n' "$C_R" "$*" "$C_0" >&2; exit 1; }

# ---------- input dari keyboard walau skrip di-pipe dari curl ----------
TTY_OK=0
if [ -r /dev/tty ] && { : </dev/tty; } 2>/dev/null; then TTY_OK=1; fi

ask() { # ask VAR "Pertanyaan" [default] [secret]
  local __var="$1" __q="$2" __def="${3:-}" __secret="${4:-}" __ans=""
  if [ -n "${!__var:-}" ]; then return 0; fi           # sudah diisi lewat env
  [ "$TTY_OK" = 1 ] || die "$__var belum diisi dan tidak ada terminal untuk bertanya. Set lewat env, contoh: $__var=... bash"
  while [ -z "$__ans" ]; do
    if [ -n "$__def" ]; then printf '  %s [%s]: ' "$__q" "$__def" >/dev/tty; else printf '  %s: ' "$__q" >/dev/tty; fi
    if [ "$__secret" = secret ]; then IFS= read -rs __ans </dev/tty; printf '\n' >/dev/tty
    else IFS= read -r __ans </dev/tty; fi
    [ -z "$__ans" ] && __ans="$__def"
  done
  printf -v "$__var" '%s' "$__ans"
}

main() {
  printf '%s\n' "${C_B}Hermes Agent + Telegram — installer satu perintah${C_0}"

  # ---------- 1. cek OS ----------
  step "Memeriksa sistem"
  [ "$(uname -s)" = Linux ] || die "Installer ini untuk server Linux. Untuk macOS pakai role Ansible-nya."
  [ -r /etc/os-release ] || die "/etc/os-release tidak ditemukan, distro tidak dikenali."
  # shellcheck disable=SC1091
  . /etc/os-release
  local family=""
  case " ${ID:-} ${ID_LIKE:-} " in
    *" debian "*|*" ubuntu "*) family=debian ;;
    *" rhel "*|*" fedora "*|*" centos "*|*" rocky "*|*" almalinux "*) family=redhat ;;
  esac
  [ -n "$family" ] || die "Distro ${PRETTY_NAME:-?} belum didukung (yang didukung: Ubuntu/Debian, Rocky/RHEL)."
  ok "${PRETTY_NAME:-$ID} terdeteksi (${family})"
  command -v systemctl >/dev/null 2>&1 || [ "${HERMES_SKIP_SERVICE:-0}" = 1 ] \
    || die "systemd tidak ditemukan. Jalankan dengan HERMES_SKIP_SERVICE=1 lalu jalankan 'hermes gateway run' manual."

  local SUDO=""
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "Butuh sudo (atau jalankan sebagai root)."
    SUDO="sudo"
    sudo -v </dev/tty 2>/dev/null || sudo -v || die "Akses sudo ditolak."
  fi

  # ---------- 2. paket dasar + user khusus ----------
  step "Memasang paket dasar"
  if [ "$family" = debian ]; then
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl tar coreutils nano ca-certificates libatomic1 >/dev/null
  else
    $SUDO dnf install -y -q git curl tar coreutils nano ca-certificates libatomic >/dev/null
  fi
  ok "git, curl, tar, coreutils, nano, libatomic terpasang"

  local HUSER
  if [ "$(id -u)" -eq 0 ]; then
    HUSER="${HERMES_USER:-hermes}"
    if ! id "$HUSER" >/dev/null 2>&1; then
      useradd -m -s /bin/bash "$HUSER"
      if [ "$family" = debian ]; then usermod -aG sudo "$HUSER"; else usermod -aG wheel "$HUSER"; fi
      ok "User khusus '$HUSER' dibuat (agent tidak berjalan sebagai root)"
    else
      ok "User '$HUSER' sudah ada"
    fi
  else
    HUSER="${HERMES_USER:-$(id -un)}"
    [ "$HUSER" = "$(id -un)" ] || die "HERMES_USER berbeda dengan user sekarang; jalankan sebagai root untuk memakai user lain."
  fi
  local HHOME; HHOME="$(getent passwd "$HUSER" | cut -d: -f6)"
  local HDIR="$HHOME/.hermes" HBIN="$HHOME/.local/bin/hermes"

  as_user() { # jalankan perintah sebagai user agent, dengan HOME-nya sendiri
    if [ "$(id -un)" = "$HUSER" ]; then (cd "$HHOME" && env HOME="$HHOME" "$@")
    elif [ "$(id -u)" -eq 0 ]; then (cd "$HHOME" && runuser -u "$HUSER" -- env HOME="$HHOME" "$@")
    else die "Tidak bisa menjalankan perintah sebagai $HUSER."; fi
  }

  # ---------- 3. pasang Hermes ----------
  step "Memasang Hermes Agent"
  if [ -x "$HBIN" ]; then
    ok "Hermes sudah terpasang di $HBIN (dilewati)"
  else
    as_user bash -c "set -o pipefail; curl -fsSL '$HERMES_INSTALL_URL' | bash -s -- --non-interactive" \
      || die "Installer Hermes gagal (cek koneksi ke ${HERMES_INSTALL_URL%%/install.sh} dan log di $HDIR/logs/install.log)."
    [ -x "$HBIN" ] || die "Perintah hermes tidak ditemukan di $HBIN setelah instalasi."
    ok "Hermes terpasang: $HBIN"
  fi

  # ---------- 4. data Telegram & AI ----------
  step "Data Telegram dan model AI"
  [ "$TTY_OK" = 1 ] && printf '  %s\n' "Token dari @BotFather, User ID dari @userinfobot." >/dev/tty
  ask TELEGRAM_BOT_TOKEN     "Token bot Telegram" "" secret
  [[ "$TELEGRAM_BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]] || die "Format token Telegram tidak valid (contoh: 123456789:AA...)."
  ask TELEGRAM_ALLOWED_USERS "User ID Telegram yang boleh memerintah (pisahkan koma)"
  [[ "$TELEGRAM_ALLOWED_USERS" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "User ID harus angka, contoh: 6123456789 (beberapa dipisah koma)."
  TELEGRAM_HOME_CHANNEL="${TELEGRAM_HOME_CHANNEL:-${TELEGRAM_ALLOWED_USERS%%,*}}"

  ask HERMES_PROVIDER "Provider AI (deepseek/openrouter)" "deepseek"
  local KEYVAR DEFMODEL
  case "$HERMES_PROVIDER" in
    deepseek)   KEYVAR=DEEPSEEK_API_KEY;   DEFMODEL="deepseek-chat" ;;
    openrouter) KEYVAR=OPENROUTER_API_KEY; DEFMODEL="deepseek/deepseek-v4-flash" ;;
    *) die "Provider '$HERMES_PROVIDER' belum didukung installer ini (pilih deepseek atau openrouter)." ;;
  esac
  ask "$KEYVAR" "API key $HERMES_PROVIDER" "" secret
  HERMES_MODEL="${HERMES_MODEL:-$DEFMODEL}"
  ok "Provider: $HERMES_PROVIDER · model: $HERMES_MODEL"

  # ---------- 5. tulis .env (upsert, tanpa duplikat) + config ----------
  step "Menyimpan konfigurasi"
  as_user mkdir -p "$HDIR"
  as_user touch "$HDIR/.env"
  as_user chmod 600 "$HDIR/.env"
  upsert_env() { # upsert_env KEY VALUE  → ganti baris lama atau tambah baris baru
    local k="$1" v="$2" tmp
    tmp="$(mktemp)"
    as_user cat "$HDIR/.env" | grep -v "^${k}=" >"$tmp" || true
    printf '%s=%s\n' "$k" "$v" >>"$tmp"
    as_user tee "$HDIR/.env" <"$tmp" >/dev/null
    rm -f "$tmp"
  }
  upsert_env TELEGRAM_BOT_TOKEN     "$TELEGRAM_BOT_TOKEN"
  upsert_env TELEGRAM_ALLOWED_USERS "$TELEGRAM_ALLOWED_USERS"
  upsert_env TELEGRAM_HOME_CHANNEL  "$TELEGRAM_HOME_CHANNEL"
  upsert_env "$KEYVAR"              "${!KEYVAR}"
  as_user chmod 600 "$HDIR/.env"
  ok "$HDIR/.env ditulis (permission 600)"

  as_user "$HBIN" config set model.provider "$HERMES_PROVIDER" >/dev/null
  as_user "$HBIN" config set model.default  "$HERMES_MODEL"    >/dev/null
  ok "Model diatur di $HDIR/config.yaml"

  # ---------- 6. systemd service ----------
  local SVC="${HERMES_SERVICE_NAME:-hermes-agent}"
  if [ "${HERMES_SKIP_SERVICE:-0}" = 1 ]; then
    warn "Service dilewati. Jalankan manual: $HBIN gateway run"
  else
    step "Memasang service $SVC (gateway Telegram 24 jam)"
    $SUDO tee "/etc/systemd/system/$SVC.service" >/dev/null <<UNIT
[Unit]
Description=Hermes Agent Telegram Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$HUSER
WorkingDirectory=$HHOME
Environment=HOME=$HHOME
ExecStart=$HBIN gateway run
Restart=on-failure
RestartSec=5
EnvironmentFile=$HDIR/.env

[Install]
WantedBy=multi-user.target
UNIT
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable "$SVC" >/dev/null 2>&1
    $SUDO systemctl restart "$SVC"
    sleep 3
    if $SUDO systemctl is-active --quiet "$SVC"; then ok "Service $SVC berjalan"
    else warn "Service belum aktif. Cek: sudo journalctl -u $SVC -n 50"; fi
  fi

  # ---------- selesai ----------
  printf '\n%s%s Selesai!%s\n' "$C_G" "$C_B" "$C_0"
  cat <<DONE
  Buka Telegram, cari bot kamu, lalu kirim:  Halo
  Kalau dibalas, karyawan AI kamu sudah aktif.

  Perintah berguna:
    sudo systemctl status $SVC        # cek service
    sudo journalctl -u $SVC -f        # lihat log
    sudo -u $HUSER -i hermes model    # ganti provider / model
    sudo -u $HUSER -i hermes doctor   # diagnosis
DONE
}

main "$@"
