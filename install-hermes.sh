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
#      HERMES_PROVIDER=deepseek DEEPSEEK_API_KEY="sk-..." \
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
#    TELEGRAM_USER_NAMES    opsional: nama tiap user ID, urutan sama, dipisah koma (default: pakai nama Telegram)
#    AGENT_NAME             nama agent                       (default: Hermes)
#    AGENT_ROLE             peran agent                      (default: asisten AI pribadi)
#    AGENT_ORG              organisasi/perusahaan, "-" = tidak ada
#    AGENT_TASKS            tugas utama, dipisah titik koma ";"
#    HERMES_TZ              zona waktu agent: nama kota, WIB/WITA/WIT, atau Asia/... (default: Asia/Jakarta)
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
  C_B=$'\033[1m'; C_D=$'\033[2m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_C=$'\033[36m'; C_0=$'\033[0m'
else
  C_B=""; C_D=""; C_G=""; C_Y=""; C_R=""; C_C=""; C_0=""
fi
STEP_NO=0
STEP_TOTAL=7
step() { # judul langkah bernomor, supaya orang tahu sudah sampai mana
  STEP_NO=$((STEP_NO + 1))
  printf '\n%s%s━━ Langkah %s dari %s: %s ━━%s\n' "$C_C" "$C_B" "$STEP_NO" "$STEP_TOTAL" "$*" "$C_0"
}
info() { # keterangan berbahasa sederhana, satu argumen = satu baris
  local l
  for l in "$@"; do printf '  %s│ %s%s\n' "$C_D" "$l" "$C_0"; done
}
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '\n%s✘ %s%s\n' "$C_R" "$*" "$C_0" >&2; exit 1; }

# ---------- input dari keyboard walau skrip di-pipe dari curl ----------
TTY_OK=0
if [ -r /dev/tty ] && { : </dev/tty; } 2>/dev/null; then TTY_OK=1; fi

ask() { # ask VAR "Pertanyaan" [default] [secret] [keterangan, baris dipisah \n]
  local __var="$1" __q="$2" __def="${3:-}" __secret="${4:-}" __hint="${5:-}" __ans="" __l __show
  if [ -n "${!__var:-}" ]; then return 0; fi           # sudah diisi lewat env
  if [ "$TTY_OK" != 1 ]; then                          # tanpa terminal: pakai default bila ada
    [ -n "$__def" ] || die "$__var belum diisi dan tidak ada terminal untuk bertanya. Set lewat env, contoh: $__var=... bash"
    printf -v "$__var" '%s' "$__def"
    return 0
  fi
  if [ -n "$__hint" ]; then                            # keterangan hanya muncul kalau memang ditanya
    printf '\n' >/dev/tty
    while IFS= read -r __l; do printf '  %s│ %s%s\n' "$C_D" "$__l" "$C_0" >/dev/tty; done <<<"$__hint"
  fi
  __show="$__def"                                       # default yang panjang cukup diringkas
  if [ "${#__def}" -gt 50 ]; then __show="tekan Enter untuk memakai yang bawaan di atas"; fi
  while [ -z "$__ans" ]; do
    if [ -n "$__def" ]; then printf '  %s [%s]: ' "$__q" "$__show" >/dev/tty; else printf '  %s: ' "$__q" >/dev/tty; fi
    if [ "$__secret" = secret ]; then IFS= read -rs __ans </dev/tty; printf '\n' >/dev/tty
    else IFS= read -r __ans </dev/tty; fi
    [ -z "$__ans" ] && __ans="$__def"
  done
  if [ "$__secret" = secret ]; then
    printf '  %s✔%s Diterima (%s karakter, sengaja tidak ditampilkan)\n' "$C_G" "$C_0" "${#__ans}" >/dev/tty
  fi
  printf -v "$__var" '%s' "$__ans"
}

# ---------- helper teks ----------
clean_name() { # buang karakter pemisah supaya aman disimpan di peta id:nama
  local s="${1//[,:]/ }"
  s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

tz_label() { # nama zona waktu yang ramah dibaca, contoh: WIB (Asia/Jakarta), Asia/Tokyo (UTC+09:00)
  local off
  case "$1" in
    Asia/Jakarta|Asia/Pontianak) printf 'WIB (%s)' "$1" ;;
    Asia/Makassar)               printf 'WITA (%s)' "$1" ;;
    Asia/Jayapura)               printf 'WIT (%s)' "$1" ;;
    *) off="$(TZ="$1" date +%:z 2>/dev/null || true)"
       if [ -n "$off" ]; then printf '%s (UTC%s)' "$1" "$off"; else printf '%s' "$1"; fi ;;
  esac
}

tz_valid() { # zona waktu dikenal sistem?
  [ -n "$1" ] || return 1
  case "$1" in *..*|/*) return 1 ;; esac
  if [ -d /usr/share/zoneinfo ]; then [ -f "/usr/share/zoneinfo/$1" ]
  else [[ "$1" =~ ^(UTC|[A-Z][A-Za-z_]+/[A-Za-z_/+-]+)$ ]]; fi
}

tz_resolve() { # ubah ketikan bebas (WIB, Bali, Tokyo, asia/kuala lumpur) jadi nama resmi; kosong kalau tidak dikenali
  local raw="$1" key hit
  key="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
  key="$(printf '%s' "$key" | tr ' -' '__')"
  [ -n "$key" ] || return 0
  case "$key" in
    # Indonesia: singkatan
    wib) printf 'Asia/Jakarta'; return 0 ;;
    wita) printf 'Asia/Makassar'; return 0 ;;
    wit) printf 'Asia/Jayapura'; return 0 ;;
    utc|gmt) printf 'UTC'; return 0 ;;
    # Indonesia bagian barat (WIB)
    jakarta|bandung|bogor|depok|bekasi|tangerang|serang|banten|cirebon|tasikmalaya|sukabumi|\
    semarang|solo|surakarta|yogyakarta|yogya|jogja|jogjakarta|magelang|purwokerto|tegal|pekalongan|\
    surabaya|malang|sidoarjo|kediri|madiun|jember|banyuwangi|\
    medan|banda_aceh|aceh|padang|bukittinggi|pekanbaru|riau|batam|tanjung_pinang|jambi|palembang|\
    bengkulu|lampung|bandar_lampung|pangkal_pinang|bangka|belitung|pontianak|singkawang|\
    palangkaraya|palangka_raya|sampit)
      if [ "$key" = pontianak ] || [ "$key" = singkawang ]; then printf 'Asia/Pontianak'; else printf 'Asia/Jakarta'; fi
      return 0 ;;
    # Indonesia bagian tengah (WITA)
    makassar|ujung_pandang|bali|denpasar|badung|kuta|ubud|lombok|mataram|kupang|labuan_bajo|flores|\
    balikpapan|samarinda|banjarmasin|banjarbaru|tarakan|bontang|ikn|nusantara|\
    manado|palu|kendari|gorontalo|parepare|bitung)
      printf 'Asia/Makassar'; return 0 ;;
    # Indonesia bagian timur (WIT)
    jayapura|papua|sorong|manokwari|merauke|timika|nabire|biak|ambon|maluku|ternate|tidore|tual)
      printf 'Asia/Jayapura'; return 0 ;;
    # kota besar Asia yang namanya beda dengan nama resmi
    kl|kuala_lumpur|malaysia) printf 'Asia/Kuala_Lumpur'; return 0 ;;
    singapura|singapore) printf 'Asia/Singapore'; return 0 ;;
    saigon|ho_chi_minh|hcmc|vietnam) printf 'Asia/Ho_Chi_Minh'; return 0 ;;
    hanoi) printf 'Asia/Ho_Chi_Minh'; return 0 ;;
    beijing|peking|china|tiongkok|cina) printf 'Asia/Shanghai'; return 0 ;;
    mumbai|bombay|delhi|new_delhi|india|bangalore|bengaluru) printf 'Asia/Kolkata'; return 0 ;;
    mekah|makkah|mecca|madinah|medina|arab_saudi|saudi) printf 'Asia/Riyadh'; return 0 ;;
    abu_dhabi|uae) printf 'Asia/Dubai'; return 0 ;;
    jepang|japan) printf 'Asia/Tokyo'; return 0 ;;
    korea|korea_selatan) printf 'Asia/Seoul'; return 0 ;;
    filipina|philippines) printf 'Asia/Manila'; return 0 ;;
    thailand) printf 'Asia/Bangkok'; return 0 ;;
    brunei) printf 'Asia/Brunei'; return 0 ;;
    timor_leste|dili) printf 'Asia/Dili'; return 0 ;;
  esac
  # Cocokkan dengan daftar zona waktu sistem, tidak peduli huruf besar/kecil:
  # "tokyo" → Asia/Tokyo, "asia/kuala lumpur" → Asia/Kuala_Lumpur, "europe/london" → Europe/London
  if [ -d /usr/share/zoneinfo ]; then
    if [[ "$key" == */* ]]; then
      hit="$(cd /usr/share/zoneinfo && find . -type f -ipath "./$key" 2>/dev/null | head -1)"
    else
      hit="$(cd /usr/share/zoneinfo && find ./Asia -maxdepth 1 -type f -iname "$key" 2>/dev/null | head -1)"
      [ -n "$hit" ] || hit="$(cd /usr/share/zoneinfo && find . -mindepth 2 -maxdepth 2 -type f -iname "$key" \
                              -not -path './posix/*' -not -path './right/*' 2>/dev/null | head -1)"
    fi
    if [ -n "$hit" ]; then printf '%s' "${hit#./}"; return 0; fi
  elif tz_valid "$raw"; then
    printf '%s' "$raw"
  fi
  return 0
}

build_soul() { # cetak isi SOUL.md dari variabel AGENT_*, TG_IDS, TG_NAMES, HERMES_TZ
  local org="" i t host owner
  host="$(hostname 2>/dev/null || echo server)"
  owner="pemiliknya (Telegram ID ${TG_IDS[0]})"
  if [ -n "${TG_NAMES[0]:-}" ]; then owner="${TG_NAMES[0]}"; fi
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
  local who
  for i in "${!TG_IDS[@]}"; do
    who="Telegram ID ${TG_IDS[$i]}"
    if [ -n "${TG_NAMES[$i]:-}" ]; then who="${TG_NAMES[$i]} (Telegram ID ${TG_IDS[$i]})"; fi
    if [ "$i" -eq 0 ]; then printf -- '- %s, pemilik dan admin utama\n' "$who"
    else printf -- '- %s\n' "$who"; fi
  done
  printf 'Panggil lawan bicara dengan nama tampilan Telegram-nya (nama pengirim pesan).\n'
  printf 'Kalau namanya tercantum di daftar ini, pakai nama dari daftar.\n\n'

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
  if [ "${HERMES_SKIP_SERVICE:-0}" = 1 ]; then STEP_TOTAL=6; fi
  printf '\n%s\n' "${C_B}Hermes Agent + Telegram — installer satu perintah${C_0}"
  info "Installer ini menyiapkan \"karyawan AI\" yang bisa kamu ajak chat lewat Telegram." \
       "Perkiraan waktu: 3 sampai 10 menit, tergantung kecepatan internet." \
       "" \
       "Siapkan 3 hal ini sebelum mulai:" \
       "  1. Token bot Telegram   → dari @BotFather (kirim /newbot)" \
       "  2. User ID Telegram     → dari @userinfobot (kirim pesan apa saja)" \
       "  3. API key AI           → dari platform.deepseek.com atau openrouter.ai" \
       "" \
       "Tips selama instalasi:" \
       "  • Teks di dalam [kurung siku] adalah jawaban bawaan. Tekan Enter untuk memakainya." \
       "  • Saat menempel token/API key, layar sengaja tidak menampilkan apa pun. Itu normal." \
       "  • Tanda ✔ berarti langkah berhasil. Mau batal? Tekan Ctrl+C kapan saja."

  # ---------- 1. cek OS ----------
  step "Memeriksa sistem"
  info "Memastikan server ini memakai sistem operasi yang didukung (Ubuntu/Debian atau Rocky/RHEL)."
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
    if ! sudo -n true 2>/dev/null; then
      info "" "Installer butuh akses administrator (sudo) untuk memasang program." \
           "Kalau muncul \"Password sudo:\", ketik password login server kamu lalu tekan Enter." \
           "Password-nya tidak terlihat saat diketik. Itu normal."
    fi
    sudo -v -p "  Password sudo: " </dev/tty 2>/dev/null || sudo -v -p "  Password sudo: " || die "Akses sudo ditolak. Pastikan password benar dan akun ini boleh memakai sudo."
  fi
  ok "Akses administrator siap"

  # ---------- 2. paket dasar + user khusus ----------
  step "Memasang paket dasar"
  info "Memasang alat-alat kecil yang dibutuhkan Hermes, misalnya git (untuk mengunduh program)" \
       "dan curl (untuk mengakses internet). Biasanya 1 sampai 3 menit. Tunggu sampai muncul tanda ✔."
  if [ "$family" = debian ]; then
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl tar coreutils nano ca-certificates libatomic1 tzdata >/dev/null
  else
    $SUDO dnf install -y -q git curl tar coreutils nano ca-certificates libatomic tzdata >/dev/null
  fi
  ok "git, curl, tar, coreutils, nano, libatomic, tzdata terpasang"

  local HUSER
  if [ "$(id -u)" -eq 0 ]; then
    HUSER="${HERMES_USER:-hermes}"
    if ! id "$HUSER" >/dev/null 2>&1; then
      useradd -m -s /bin/bash "$HUSER"
      if [ "$family" = debian ]; then usermod -aG sudo "$HUSER"; else usermod -aG wheel "$HUSER"; fi
      ok "Akun khusus '$HUSER' dibuat. Agent berjalan di akun ini, bukan root, supaya lebih aman."
    else
      ok "Akun khusus '$HUSER' sudah ada, dipakai lagi"
    fi
  else
    HUSER="${HERMES_USER:-$(id -un)}"
    [ "$HUSER" = "$(id -un)" ] || die "HERMES_USER berbeda dengan user sekarang; jalankan sebagai root untuk memakai user lain."
  fi
  local HHOME; HHOME="$(getent passwd "$HUSER" | cut -d: -f6)"
  local HDIR="$HHOME/.hermes" HBIN="$HHOME/.local/bin/hermes"
  # Untuk tampilan: jangan munculkan nama akun atau /home/<nama>
  local SHOW_DIR="~/.hermes" HCMD="hermes"
  if [ "$(id -un)" != "$HUSER" ]; then SHOW_DIR="$HDIR"; HCMD="sudo -u $HUSER -i hermes"; fi

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
  info "Hermes Agent adalah \"otak\" karyawan AI kamu, buatan Nous Research (gratis, open source)."
  if [ -x "$HBIN" ]; then
    ok "Hermes sudah terpasang di server ini, jadi langkah ini dilewati"
  else
    info "Programnya diunduh dari situs resmi. Biasanya 2 sampai 5 menit. Mohon tunggu."
    as_user bash -c "set -o pipefail; curl -fsSL '$HERMES_INSTALL_URL' | bash -s -- --non-interactive" \
      || die "Installer Hermes gagal (cek koneksi ke ${HERMES_INSTALL_URL%%/install.sh} dan log di $SHOW_DIR/logs/install.log)."
    [ -x "$HBIN" ] || die "Program Hermes tidak ditemukan setelah instalasi. Coba jalankan installer sekali lagi."
    ok "Hermes berhasil dipasang"
  fi

  # ---------- 4a. data Telegram & AI ----------
  step "Menghubungkan Telegram dan AI"
  info "Agar bisa diajak chat, agent butuh \"kunci\" bot Telegram." \
       "Agar bisa berpikir, agent butuh akses ke layanan AI lewat API key."

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
    ok "Token bot dan API key dari instalasi sebelumnya ditemukan, jadi tidak ditanya lagi"
    info "Mau mengganti token atau API key? Batalkan (Ctrl+C), lalu jalankan:" \
         "  curl -fsSL https://get.zahwajuliana.web.id/install-hermes.sh | HERMES_RESET_SECRETS=1 bash"
  fi

  ask TELEGRAM_BOT_TOKEN "Tempel token bot Telegram" "" secret \
"TOKEN BOT = kunci rahasia supaya agent bisa memakai bot Telegram kamu.
Cara mendapatkannya: buka Telegram → cari @BotFather → kirim /newbot → ikuti instruksinya.
Bentuknya: angka, titik dua, lalu huruf acak. Contoh: 123456789:AAH4xYz...
Tempel token lalu tekan Enter. Tulisannya memang tidak muncul di layar."
  TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN// /}"
  [[ "$TELEGRAM_BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]] \
    || die "Format token bot salah. Token yang benar berbentuk angka:huruf (contoh 123456789:AAH4x...). Salin ulang dari @BotFather, lalu jalankan installer lagi."
  ask TELEGRAM_ALLOWED_USERS "Tempel User ID Telegram yang boleh memberi perintah" "" secret \
"USER ID = nomor unik akun Telegram. Hanya nomor yang ditulis di sini yang boleh
memerintah bot. Pesan dari orang lain akan diabaikan, jadi bot kamu aman.
Cara mendapatkannya: buka Telegram → cari @userinfobot → kirim pesan apa saja → salin angka \"Id\".
Contoh: 6123456789. Untuk beberapa orang, pisahkan dengan koma: 6123456789,6987654321
Demi privasi, angkanya juga tidak ditampilkan di layar saat ditempel."
  TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS// /}"
  [[ "$TELEGRAM_ALLOWED_USERS" =~ ^[0-9]+(,[0-9]+)*$ ]] \
    || die "User ID harus berupa angka saja, contoh 6123456789 (beberapa orang dipisah koma). Cek lagi di @userinfobot, lalu jalankan installer lagi."
  TELEGRAM_HOME_CHANNEL="${TELEGRAM_HOME_CHANNEL:-${TELEGRAM_ALLOWED_USERS%%,*}}"

  ask HERMES_PROVIDER "Provider AI, ketik nama saja (deepseek/openrouter)" "deepseek" "" \
"PROVIDER = perusahaan penyedia \"otak\" AI yang dipakai agent.
Ketik NAMA-nya saja (deepseek atau openrouter), BUKAN API key.
Kalau ragu, langsung tekan Enter untuk memakai deepseek (murah dan cukup pintar)."
  HERMES_PROVIDER="$(printf '%s' "$HERMES_PROVIDER" | tr '[:upper:]' '[:lower:]')"
  local KEYVAR DEFMODEL KEYHELP
  case "$HERMES_PROVIDER" in
    deepseek)   KEYVAR=DEEPSEEK_API_KEY;   DEFMODEL="deepseek-chat"
                KEYHELP="buka platform.deepseek.com → login → menu API Keys → Create new API key." ;;
    openrouter) KEYVAR=OPENROUTER_API_KEY; DEFMODEL="deepseek/deepseek-v4-flash"
                KEYHELP="buka openrouter.ai → login → menu Keys → Create Key." ;;
    sk-*) die "Itu API key, bukan nama provider. Jalankan ulang, lalu di pertanyaan provider ketik 'deepseek' atau tekan Enter." ;;
    *) die "Provider '$HERMES_PROVIDER' belum didukung installer ini (pilih deepseek atau openrouter)." ;;
  esac
  ask "$KEYVAR" "Tempel API key $HERMES_PROVIDER" "" secret \
"API KEY = kunci untuk memakai layanan AI. Biaya pemakaian AI ditagihkan ke akun pemilik kunci ini.
Cara mendapatkannya: $KEYHELP
Bentuknya diawali sk-... Tempel lalu tekan Enter (tulisannya tidak muncul di layar).
Jangan bagikan API key ke siapa pun, termasuk lewat screenshot."
  HERMES_MODEL="${HERMES_MODEL:-$DEFMODEL}"
  ok "Layanan AI: $HERMES_PROVIDER, model: $HERMES_MODEL"

  # ---------- 4b. identitas agent (SOUL.md) ----------
  step "Memberi identitas ke agent"
  local PFILE="$HDIR/persona.env"
  local prev_name prev_role prev_org prev_tasks prev_tz
  prev_name="$(file_get "$PFILE" AGENT_NAME)"
  prev_role="$(file_get "$PFILE" AGENT_ROLE)"
  prev_org="$(file_get "$PFILE" AGENT_ORG)"
  prev_tasks="$(file_get "$PFILE" AGENT_TASKS)"
  prev_tz="$(file_get "$PFILE" HERMES_TZ)"

  info "Sekarang kita memberi \"kepribadian\" ke agent: nama, peran, dan tugasnya." \
       "Semua ini ditulis ke file SOUL.md, yang dibaca agent setiap kali mulai percakapan." \
       "Agent otomatis memakai Bahasa Indonesia dan memanggil lawan bicara dengan nama Telegram-nya."
  if [ -n "$prev_name" ]; then
    info "Jawaban dari instalasi sebelumnya sudah diisikan di [kurung siku]. Cukup tekan Enter kalau tidak mau diubah."
  fi

  # Nama tiap user ID (urutan sama dengan TELEGRAM_ALLOWED_USERS)
  local -a TG_IDS=() TG_NAMES=() ENV_NAMES=()
  IFS=',' read -r -a TG_IDS <<<"$TELEGRAM_ALLOWED_USERS"
  if [ -n "${TELEGRAM_USER_NAMES:-}" ]; then IFS=',' read -r -a ENV_NAMES <<<"$TELEGRAM_USER_NAMES"; fi
  local i id nm map=""
  for i in "${!TG_IDS[@]}"; do
    id="${TG_IDS[$i]}"
    nm="$(clean_name "${ENV_NAMES[$i]:-}")"
    TG_NAMES[i]="$nm"
    if [ -n "$nm" ]; then map="${map:+$map,}$id:$nm"; fi
  done

  ask AGENT_NAME "Nama agent" "${prev_name:-Hermes}" "" \
"NAMA AGENT = nama panggilan karyawan AI kamu, misalnya Lawawa, Aluna, atau Budi.
Nama ini dipakai agent saat memperkenalkan diri."
  ask AGENT_ROLE "Peran agent" "${prev_role:-asisten AI pribadi}" "" \
"PERAN = jabatan agent dalam satu frasa pendek.
Contoh: asisten AI tim IT, admin helpdesk, sekretaris pribadi."
  ask AGENT_ORG "Organisasi/perusahaan" "${prev_org:--}" "" \
"ORGANISASI = nama kantor atau perusahaan tempat agent bekerja, misalnya PT Excellent.
Ketik tanda - (strip) atau tekan Enter kalau tidak ada."
  local task_def="${prev_tasks:-$DEFAULT_TASKS}" task_list="" t
  local -a task_arr=()
  IFS=';' read -r -a task_arr <<<"$task_def"
  for t in "${task_arr[@]}"; do
    t="${t#"${t%%[![:space:]]*}"}"
    if [ -n "$t" ]; then task_list="$task_list"$'\n'"  • $t"; fi
  done
  ask AGENT_TASKS "Tugas utama" "$task_def" "" \
"TUGAS UTAMA = daftar pekerjaan agent. Tugas ini disebutkan agent saat kamu menyapanya.
Daftar bawaan:$task_list
Mau pakai daftar di atas? Langsung tekan Enter.
Mau tulis sendiri? Pisahkan tiap tugas dengan titik koma (;), contoh:
  Membalas pertanyaan pelanggan; Merangkum email harian; Mengingatkan jadwal rapat"
  local tz_in tz_ok tz_hint
  tz_hint="ZONA WAKTU = acuan jam dan tanggal agent, misalnya untuk pengingat.
Cukup ketik nama kota atau singkatannya, installer akan mencarikan zona waktunya:
  • Indonesia : WIB, WITA, WIT, atau nama kota (Jakarta, Bandung, Surabaya, Medan,
                Bali, Makassar, Balikpapan, Manado, Jayapura, Ambon, dll.)
  • Asia lain : Singapore, Kuala Lumpur, Bangkok, Tokyo, Seoul, Dubai, dll.
  • Nama resmi juga boleh, contoh: Asia/Jakarta atau Asia/Tokyo
Tekan Enter untuk memakai yang ada di [kurung siku]."
  tz_in="${HERMES_TZ:-}"
  while :; do
    if [ -z "$tz_in" ]; then
      HERMES_TZ=""
      ask HERMES_TZ "Zona waktu (nama kota atau WIB/WITA/WIT)" "${prev_tz:-Asia/Jakarta}" "" "$tz_hint"
      tz_in="$HERMES_TZ"
    fi
    tz_ok="$(tz_resolve "$tz_in")"
    if [ -n "$tz_ok" ] && tz_valid "$tz_ok"; then HERMES_TZ="$tz_ok"; break; fi
    if [ "$TTY_OK" != 1 ]; then
      warn "Zona waktu '$tz_in' tidak dikenali, jadi dipakai Asia/Jakarta (WIB)."
      HERMES_TZ="Asia/Jakarta"; break
    fi
    warn "Zona waktu '$tz_in' tidak ditemukan. Coba ketik nama kota lain yang terdekat, atau WIB/WITA/WIT."
    tz_in=""; tz_hint=""
  done
  ok "Zona waktu: $(tz_label "$HERMES_TZ") · jam di sana sekarang $(TZ="$HERMES_TZ" date +%H:%M 2>/dev/null || echo '?')"
  ok "Identitas siap: $AGENT_NAME, $AGENT_ROLE · ${#TG_IDS[@]} orang boleh memberi perintah"

  # ---------- 5. tulis .env (upsert, tanpa duplikat), config, SOUL.md ----------
  step "Menyimpan pengaturan"
  info "Semua jawaban tadi disimpan di server ini, di folder $SHOW_DIR."
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
  ok ".env disimpan: berisi token & API key, dikunci supaya hanya akun agent yang bisa membacanya"

  as_user "$HBIN" config set model.provider "$HERMES_PROVIDER" >/dev/null
  as_user "$HBIN" config set model.default  "$HERMES_MODEL"    >/dev/null
  ok "config.yaml disimpan: berisi pilihan layanan dan model AI"

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
      ok "SOUL.md sudah sesuai, tidak ada yang berubah"
    else
      if as_user test -s "$SOUL"; then
        bak="$SOUL.bak-$(date +%Y%m%d-%H%M%S)"
        as_user cp "$SOUL" "$bak"
        ok "SOUL.md lama dicadangkan dulu sebagai ${bak##*/}"
      fi
      as_user tee "$SOUL" <"$stmp" >/dev/null
      ok "SOUL.md disimpan: berisi kepribadian dan aturan $AGENT_NAME"
    fi
    rm -f "$stmp"
  fi

  # ---------- 6. systemd service ----------
  local SVC="${HERMES_SERVICE_NAME:-hermes-agent}"
  if [ "${HERMES_SKIP_SERVICE:-0}" = 1 ]; then
    warn "Service tidak dipasang (HERMES_SKIP_SERVICE=1). Nyalakan agent secara manual dengan: $HCMD gateway run"
  else
    step "Menyalakan agent 24 jam"
    info "Agent dipasang sebagai \"service\": programnya berjalan terus di latar belakang," \
         "tetap hidup walau terminal ditutup, dan menyala sendiri kalau server di-restart."
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
    if $SUDO systemctl is-active --quiet "$SVC"; then ok "Agent menyala (service: $SVC)"
    else
      warn "Agent belum berhasil menyala. Penyebab paling umum: token bot atau API key salah."
      info "Lihat pesan error-nya dengan: sudo journalctl -u $SVC -n 50"
    fi
  fi

  # ---------- selesai ----------
  printf '\n%s%s━━ Selesai! %s sudah siap bekerja ━━%s\n' "$C_G" "$C_B" "$AGENT_NAME" "$C_0"
  cat <<DONE

  Cara mencoba:
    1. Buka Telegram, cari bot kamu (nama yang kamu buat di @BotFather).
    2. Kirim /new   → memulai percakapan baru supaya identitas terbaru dipakai.
    3. Kirim Halo   → $AGENT_NAME akan menyapamu dan menyebutkan tugasnya.
  Kalau tidak dibalas dalam 1 menit, lihat penyebabnya dengan: sudo journalctl -u $SVC -n 50

  File penting:
    $SHOW_DIR/SOUL.md
        → kepribadian & aturan agent. Setelah diedit, jalankan: sudo systemctl restart $SVC
    $SHOW_DIR/.env
        → token & API key. Rahasia, jangan dibagikan.

  Perintah yang sering dipakai:
DONE
  local row
  for row in "sudo systemctl status $SVC|cek apakah agent sedang berjalan" \
             "sudo systemctl restart $SVC|nyalakan ulang agent" \
             "sudo journalctl -u $SVC -f|lihat aktivitas agent secara langsung (keluar: Ctrl+C)" \
             "$HCMD model|ganti layanan/model AI" \
             "$HCMD doctor|periksa kalau ada masalah"; do
    printf '    %-38s → %s\n' "${row%%|*}" "${row#*|}"
  done
}

main "$@"
