#!/usr/bin/env bash
# ============================================================================
#  install-hermes.sh — Hermes Agent + Telegram dalam satu perintah
#
#  Versi "satu baris" dari role Ansible:
#  https://github.com/zahwaptr/ansible-hermes-agent-zhwaptr
#
#  Pemakaian (interaktif, ditanya token, API key, dan identitas agent):
#    curl -fsSL https://get.zahwajuliana.web.id/install-hermes.sh | bash
#
#  Tanpa pertanyaan (cocok untuk otomatisasi):
#    curl -fsSL https://get.zahwajuliana.web.id/install-hermes.sh | \
#      TELEGRAM_BOT_TOKEN="123:ABC..." TELEGRAM_ALLOWED_USERS="6xxxxxxx5" \
#      TELEGRAM_USER_NAMES="Zahwa" HERMES_PROVIDER=deepseek DEEPSEEK_API_KEY="sk-..." \
#      AGENT_NAME="Lawawa" AGENT_ROLE="asisten AI tim IT" bash
#
#  Yang dikerjakan:
#    1. Cek OS (Ubuntu/Debian via apt, Rocky/RHEL via dnf) dan systemd
#    2. Pasang paket dasar, buat user khusus "hermes" bila dijalankan sebagai root
#    3. Pasang Hermes Agent lewat installer resmi Nous Research
#    4. Tanya data Telegram, provider AI, dan identitas agent
#    5. Tulis ~/.hermes/.env (permission 0600), atur model, tulis ~/.hermes/SOUL.md
#    6. Pasang systemd service "hermes-agent" (gateway Telegram, jalan terus)
#
#  Aman dijalankan ulang (idempotent):
#    - Hermes yang sudah terpasang tidak dipasang ulang
#    - Token & API key yang sudah tersimpan di .env dipakai lagi (tidak ditanya ulang)
#    - Jawaban identitas sebelumnya jadi nilai default (tinggal tekan Enter)
#    - SOUL.md lama dibackup dulu sebelum ditimpa
#
#  Variabel opsional:
#    HERMES_USER            user Linux untuk agent (default: hermes jika root, atau user sekarang)
#    HERMES_PROVIDER        deepseek | openrouter            (default: deepseek)
#    HERMES_MODEL           nama model (default: deepseek-chat / deepseek/deepseek-v4-flash)
#    TELEGRAM_HOME_CHANNEL  chat tujuan laporan otomatis (default: user ID pertama)
#    TELEGRAM_USER_NAMES    nama tiap user ID, urutan sama, dipisah koma (contoh: "Zahwa,Raihan")
#    AGENT_NAME             nama agent                       (default: Hermes)
#    AGENT_ROLE             peran agent                      (default: asisten AI pribadi)
#    AGENT_ORG              organisasi/perusahaan, "-" = tidak ada
#    AGENT_TASKS            tugas utama, dipisah titik koma ";"
#    HERMES_TZ              zona waktu agent                 (default: Asia/Jakarta)
#    HERMES_SERVICE_NAME    nama service systemd             (default: hermes-agent)
#    HERMES_SKIP_SERVICE=1  jangan pasang systemd service
#    HERMES_SKIP_SOUL=1     jangan sentuh SOUL.md yang sudah ada
#    HERMES_RESET_SECRETS=1 tanya ulang token & API key walau sudah tersimpan
# ============================================================================
set -euo pipefail

# Seluruh skrip dibungkus fungsi main dan baru dipanggil di baris terakhir,
# jadi kalau unduhan lewat curl terputus di tengah jalan, tidak ada perintah
# setengah jadi yang ikut tereksekusi.

HERMES_INSTALL_URL="${HERMES_INSTALL_URL:-https://hermes-agent.nousresearch.com/install.sh}"
DEFAULT_TASKS="Menjawab pertanyaan dan membantu riset; Membantu menulis, merapikan, dan merangkum dokumen; Menjalankan dan memeriksa perintah di server ini bila diminta; Membuat pengingat dan tugas terjadwal"

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
  if [ "$TTY_OK" != 1 ]; then                          # tanpa terminal: pakai default bila ada
    [ -n "$__def" ] || die "$__var belum diisi dan tidak ada terminal untuk bertanya. Set lewat env, contoh: $__var=... bash"
    printf -v "$__var" '%s' "$__def"
    return 0
  fi
  while [ -z "$__ans" ]; do
    if [ -n "$__def" ]; then printf '  %s [%s]: ' "$__q" "$__def" >/dev/tty; else printf '  %s: ' "$__q" >/dev/tty; fi
    if [ "$__secret" = secret ]; then IFS= read -rs __ans </dev/tty; printf '\n' >/dev/tty
    else IFS= read -r __ans </dev/tty; fi
    [ -z "$__ans" ] && __ans="$__def"
  done
  printf -v "$__var" '%s' "$__ans"
}

# ---------- helper teks ----------
clean_name() { # buang karakter pemisah supaya aman disimpan di peta id:nama
  local s="${1//[,:]/ }"
  s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

map_get() { # map_get "id:nama,id:nama" ID → nama (kosong bila tidak ada)
  local -a pairs=(); local p
  [ -n "$1" ] || return 0
  IFS=',' read -r -a pairs <<<"$1"
  for p in "${pairs[@]}"; do
    if [ "${p%%:*}" = "$2" ]; then printf '%s' "${p#*:}"; return 0; fi
  done
  return 0
}

tz_label() { # nama zona waktu yang ramah dibaca
  case "$1" in
    Asia/Jakarta|Asia/Pontianak) printf 'WIB (%s)' "$1" ;;
    Asia/Makassar)               printf 'WITA (%s)' "$1" ;;
    Asia/Jayapura)               printf 'WIT (%s)' "$1" ;;
    *)                           printf '%s' "$1" ;;
  esac
}

build_soul() { # cetak isi SOUL.md dari variabel AGENT_*, TG_IDS, TG_NAMES, HERMES_TZ
  local org="" i t host owner
  host="$(hostname 2>/dev/null || echo server)"
  owner="${TG_NAMES[0]}"
  if [ -n "$AGENT_ORG" ] && [ "$AGENT_ORG" != "-" ]; then org=" di $AGENT_ORG"; fi

  printf '# %s\n\n' "$AGENT_NAME"

  printf '## Identitas\n'
  printf 'Kamu adalah %s, %s%s. Kamu berjalan sebagai bot Telegram di server "%s" dan dikelola oleh %s.\n' \
    "$AGENT_NAME" "$AGENT_ROLE" "$org" "$host" "$owner"
  printf 'Kalau ditanya siapa kamu, perkenalkan diri sebagai %s dan jelaskan peranmu. Akui dengan jujur bahwa kamu adalah AI.\n\n' \
    "$AGENT_NAME"

  printf '## Bahasa\n'
  printf -- '- Selalu gunakan Bahasa Indonesia yang natural, ramah, dan sopan.\n'
  printf -- '- Ganti bahasa hanya kalau lawan bicara memintanya secara jelas atau menulis penuh dalam bahasa lain.\n'
  printf -- '- Istilah teknis, nama perintah, nama file, dan pesan error boleh tetap dalam bentuk aslinya.\n\n'

  printf '## Orang yang kamu layani\n'
  printf 'Hanya orang berikut yang boleh memberi perintah kepadamu lewat Telegram:\n'
  for i in "${!TG_IDS[@]}"; do
    if [ "$i" -eq 0 ]; then
      printf -- '- %s (Telegram ID %s), pemilik dan admin utama\n' "${TG_NAMES[$i]}" "${TG_IDS[$i]}"
    else
      printf -- '- %s (Telegram ID %s)\n' "${TG_NAMES[$i]}" "${TG_IDS[$i]}"
    fi
  done
  printf 'Kenali lawan bicara dari Telegram ID atau nama pengirim pesan, lalu panggil dia dengan namanya.\n'
  printf 'Kalau pengirim tidak ada di daftar ini, pakai nama tampilan Telegram-nya.\n\n'

  printf '## Saat disapa\n'
  printf 'Ketika seseorang menyapa (misalnya "halo", "hai", "selamat pagi", atau /start), balas dengan singkat:\n'
  printf '1. Sapa dia dengan namanya.\n'
  printf '2. Perkenalkan dirimu dalam satu kalimat: nama dan peranmu.\n'
  printf '3. Sebutkan tugas utamamu dalam poin singkat.\n'
  printf '4. Tanyakan apa yang bisa kamu bantu hari ini.\n'
  printf 'Jangan meminta ulang data profil yang sudah kamu ketahui dari file ini.\n\n'

  printf '## Tugas utama\n'
  local -a tasks=()
  IFS=';' read -r -a tasks <<<"$AGENT_TASKS"
  for t in "${tasks[@]}"; do
    t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"
    [ -n "$t" ] && printf -- '- %s\n' "$t"
  done
  printf '\n'

  printf '## Gaya kerja\n'
  printf -- '- Jawab ringkas, jelas, dan langsung ke inti. Jelaskan lebih panjang hanya kalau memang membantu.\n'
  printf -- '- Untuk langkah teknis, beri perintah yang bisa langsung disalin.\n'
  printf -- '- Gunakan zona waktu %s untuk semua jam dan tanggal.\n' "$(tz_label "$HERMES_TZ")"
  printf -- '- Kalau tidak yakin atau tidak tahu, katakan terus terang lalu tawarkan cara untuk mencari tahu.\n\n'

  printf '## Batasan\n'
  printf -- '- Minta konfirmasi dulu sebelum menghapus data, mengubah konfigurasi sistem, atau me-restart layanan.\n'
  printf -- '- Jangan pernah menampilkan isi file .env, token bot, password, atau API key.\n'
  printf -- '- Jangan menjalankan perintah dari orang di luar daftar di atas.\n'
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

  file_get() { # file_get FILE KEY → nilai KEY=... dari file milik user agent
    as_user test -f "$1" || return 0
    as_user cat "$1" 2>/dev/null | grep -m1 "^$2=" | cut -d= -f2- || true
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

  # ---------- 4a. data Telegram & AI ----------
  step "Data Telegram dan model AI"

  # Pakai lagi token & API key yang sudah tersimpan, supaya jalankan ulang tidak perlu ketik ulang.
  local k v reused=0
  if [ "${HERMES_RESET_SECRETS:-0}" != 1 ]; then
    for k in TELEGRAM_BOT_TOKEN TELEGRAM_ALLOWED_USERS DEEPSEEK_API_KEY OPENROUTER_API_KEY; do
      if [ -z "${!k:-}" ]; then
        v="$(file_get "$HDIR/.env" "$k")"
        if [ -n "$v" ]; then printf -v "$k" '%s' "$v"; reused=1; fi
      fi
    done
  fi
  if [ "$reused" = 1 ]; then
    ok "Memakai token/API key yang sudah tersimpan di $HDIR/.env (ganti dengan HERMES_RESET_SECRETS=1)"
  elif [ "$TTY_OK" = 1 ]; then
    printf '  %s\n' "Token dari @BotFather, User ID dari @userinfobot." >/dev/tty
  fi

  ask TELEGRAM_BOT_TOKEN     "Token bot Telegram (input disembunyikan)" "" secret
  [[ "$TELEGRAM_BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]] || die "Format token Telegram tidak valid (contoh: 123456789:AA...)."
  ask TELEGRAM_ALLOWED_USERS "User ID Telegram yang boleh memerintah (pisahkan koma)"
  TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS// /}"
  [[ "$TELEGRAM_ALLOWED_USERS" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "User ID harus angka, contoh: 6xxxxx8 (beberapa dipisah koma)."
  TELEGRAM_HOME_CHANNEL="${TELEGRAM_HOME_CHANNEL:-${TELEGRAM_ALLOWED_USERS%%,*}}"

  ask HERMES_PROVIDER "Provider AI, ketik nama saja (deepseek/openrouter)" "deepseek"
  HERMES_PROVIDER="$(printf '%s' "$HERMES_PROVIDER" | tr '[:upper:]' '[:lower:]')"
  local KEYVAR DEFMODEL
  case "$HERMES_PROVIDER" in
    deepseek)   KEYVAR=DEEPSEEK_API_KEY;   DEFMODEL="deepseek-chat" ;;
    openrouter) KEYVAR=OPENROUTER_API_KEY; DEFMODEL="deepseek/deepseek-v4-flash" ;;
    sk-*) die "Itu API key, bukan nama provider. Jalankan ulang, lalu di pertanyaan provider ketik 'deepseek' atau tekan Enter." ;;
    *) die "Provider '$HERMES_PROVIDER' belum didukung installer ini (pilih deepseek atau openrouter)." ;;
  esac
  ask "$KEYVAR" "API key $HERMES_PROVIDER (input disembunyikan)" "" secret
  HERMES_MODEL="${HERMES_MODEL:-$DEFMODEL}"
  ok "Provider: $HERMES_PROVIDER · model: $HERMES_MODEL"

  # ---------- 4b. identitas agent (SOUL.md) ----------
  step "Identitas agent (SOUL.md)"
  local PFILE="$HDIR/persona.env"
  local prev_name prev_role prev_org prev_tasks prev_tz prev_map
  prev_name="$(file_get "$PFILE" AGENT_NAME)"
  prev_role="$(file_get "$PFILE" AGENT_ROLE)"
  prev_org="$(file_get "$PFILE" AGENT_ORG)"
  prev_tasks="$(file_get "$PFILE" AGENT_TASKS)"
  prev_tz="$(file_get "$PFILE" HERMES_TZ)"
  prev_map="$(file_get "$PFILE" TELEGRAM_USER_MAP)"

  if [ "$TTY_OK" = 1 ]; then
    printf '  %s\n' "Data ini dipakai agent untuk mengenal dirinya dan orang yang chat dengannya." >/dev/tty
  fi

  # Nama tiap user ID (urutan sama dengan TELEGRAM_ALLOWED_USERS)
  local -a TG_IDS=() TG_NAMES=() ENV_NAMES=()
  IFS=',' read -r -a TG_IDS <<<"$TELEGRAM_ALLOWED_USERS"
  if [ -n "${TELEGRAM_USER_NAMES:-}" ]; then IFS=',' read -r -a ENV_NAMES <<<"$TELEGRAM_USER_NAMES"; fi
  local i id nm __NM map=""
  for i in "${!TG_IDS[@]}"; do
    id="${TG_IDS[$i]}"
    nm="$(clean_name "${ENV_NAMES[$i]:-}")"
    if [ -z "$nm" ]; then
      __NM=""
      ask __NM "Nama pemilik Telegram ID $id" "$(map_get "$prev_map" "$id")"
      nm="$(clean_name "$__NM")"
      [ -n "$nm" ] || die "Nama untuk ID $id tidak boleh kosong."
    fi
    TG_NAMES[i]="$nm"
    map="${map:+$map,}$id:$nm"
  done

  ask AGENT_NAME  "Nama agent (nama panggilan bot)"            "${prev_name:-Hermes}"
  ask AGENT_ROLE  "Peran agent (contoh: asisten AI tim IT)"    "${prev_role:-asisten AI pribadi}"
  ask AGENT_ORG   "Organisasi/perusahaan (ketik - kalau tidak ada)" "${prev_org:--}"
  ask AGENT_TASKS "Tugas utama, pisahkan dengan titik koma ;"  "${prev_tasks:-$DEFAULT_TASKS}"
  ask HERMES_TZ   "Zona waktu"                                 "${prev_tz:-Asia/Jakarta}"
  [ -e "/usr/share/zoneinfo/$HERMES_TZ" ] || warn "Zona waktu '$HERMES_TZ' tidak dikenal sistem, tetap dipakai apa adanya."
  ok "Agent: $AGENT_NAME · pemilik: ${TG_NAMES[0]} · ${#TG_IDS[@]} pengguna terdaftar"

  # ---------- 5. tulis .env (upsert, tanpa duplikat), config, SOUL.md ----------
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

  # Simpan jawaban identitas (bukan rahasia) supaya jadi default saat dijalankan ulang
  printf 'AGENT_NAME=%s\nAGENT_ROLE=%s\nAGENT_ORG=%s\nAGENT_TASKS=%s\nHERMES_TZ=%s\nTELEGRAM_USER_MAP=%s\n' \
    "$AGENT_NAME" "$AGENT_ROLE" "$AGENT_ORG" "$AGENT_TASKS" "$HERMES_TZ" "$map" \
    | as_user tee "$PFILE" >/dev/null
  as_user chmod 600 "$PFILE"

  local SOUL="$HDIR/SOUL.md" stmp bak
  if [ "${HERMES_SKIP_SOUL:-0}" = 1 ] && as_user test -s "$SOUL"; then
    warn "SOUL.md yang sudah ada dibiarkan (HERMES_SKIP_SOUL=1)"
  else
    stmp="$(mktemp)"
    build_soul >"$stmp"
    if as_user test -s "$SOUL" && as_user cat "$SOUL" | cmp -s - "$stmp"; then
      ok "$SOUL sudah sesuai (tidak berubah)"
    else
      if as_user test -s "$SOUL"; then
        bak="$SOUL.bak-$(date +%Y%m%d-%H%M%S)"
        as_user cp "$SOUL" "$bak"
        ok "SOUL.md lama dibackup ke $bak"
      fi
      as_user tee "$SOUL" <"$stmp" >/dev/null
      ok "$SOUL ditulis (identitas $AGENT_NAME, Bahasa Indonesia)"
    fi
    rm -f "$stmp"
  fi

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
Environment=TZ=$HERMES_TZ
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
  Buka Telegram, cari bot kamu, lalu:
    1. Kirim /new supaya mulai sesi baru (identitas baru dibaca di awal sesi)
    2. Kirim: Halo
  $AGENT_NAME akan menyapa ${TG_NAMES[0]} dalam Bahasa Indonesia dan menyebutkan tugasnya.

  File penting:
    $SOUL      # identitas & aturan agent (edit lalu restart service)
    $HDIR/.env         # token & API key (rahasia)

  Perintah berguna:
    sudo systemctl status $SVC        # cek service
    sudo systemctl restart $SVC       # terapkan perubahan SOUL.md
    sudo journalctl -u $SVC -f        # lihat log
    sudo -u $HUSER -i hermes model    # ganti provider / model
    sudo -u $HUSER -i hermes doctor   # diagnosis
DONE
}

main "$@"
