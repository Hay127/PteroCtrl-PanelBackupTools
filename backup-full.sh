#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONF="${CONF:-$SCRIPT_DIR/backup.conf}"

log() { echo "[$(date '+%F %T')] $*"; }

need() {
  command -v "$1" >/dev/null 2>&1 || { log "ERROR: butuh command: $1"; exit 1; }
}

have() { command -v "$1" >/dev/null 2>&1; }

trim_quotes() { sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"; }

read_env() {
  # usage: read_env /path/.env KEY
  local envfile="$1" key="$2"
  grep -E "^${key}=" "$envfile" 2>/dev/null | head -n1 | cut -d= -f2- | trim_quotes
}

discord_notify() {
  [[ -z "${DISCORD_WEBHOOK_URL:-}" ]] && return 0

  need curl
  need jq

  local msg="$1"
  local payload http attempt max_try delay
  payload="$(jq -n --arg content "$msg" '{content:$content}')"

  max_try="${WEBHOOK_RETRIES:-3}"
  delay="${WEBHOOK_RETRY_DELAY:-2}"

  for attempt in $(seq 1 "$max_try"); do
    http="$(curl -sS -o /tmp/webhook_resp.txt -w "%{http_code}" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "$DISCORD_WEBHOOK_URL" || echo "000")"

    # Discord webhook sukses biasanya 204 (kadang 200)
    if [[ "$http" == "204" || "$http" == "200" ]]; then
      return 0
    fi

    log "WARN: webhook gagal (try $attempt/$max_try) HTTP=$http resp=$(head -c 200 /tmp/webhook_resp.txt 2>/dev/null || true)"
    sleep "$delay"
  done

  return 1
}

compress_setup() {
  case "${COMPRESS:-gzip}" in
    zstd)
      need zstd
      COMP_EXT="tar.zst"
      TAR_COMPRESS_ARGS=(--use-compress-program="zstd -T0 -10")
      ;;
    pigz)
      need pigz
      COMP_EXT="tar.gz"
      TAR_COMPRESS_ARGS=(--use-compress-program="pigz -p 4 -9")
      ;;
    gzip|*)
      need gzip
      COMP_EXT="tar.gz"
      TAR_COMPRESS_ARGS=(-z)
      ;;
  esac
}

compress_db_file() {
  local sql="$1"
  [[ ! -f "$sql" ]] && return 0

  case "${COMPRESS:-gzip}" in
    zstd)
      zstd -T0 -10 -f "$sql" -o "${sql%.sql}.sql.zst"
      rm -f "$sql"
      ;;
    pigz)
      pigz -9 -f "$sql"
      ;;
    gzip|*)
      gzip -9 -f "$sql"
      ;;
  esac
}

build_excludes() {
  local excludes=()

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    excludes+=("--exclude=$line")
  done <<< "${EXTRA_EXCLUDES:-}"

  # kalau mode FULL, jangan auto-exclude vendor/node_modules (kalau ada)
  if [[ "${BACKUP_MODE:-full}" == "full" ]]; then
    local new_ex=()
    for e in "${excludes[@]}"; do
      [[ "$e" == "--exclude=vendor" ]] && continue
      [[ "$e" == "--exclude=node_modules" ]] && continue
      new_ex+=("$e")
    done
    excludes=("${new_ex[@]}")
  fi

  printf "%s\n" "${excludes[@]}"
}

dump_db_from_env() {
  local envfile="$1" out_sql="$2" label="$3"

  if [[ ! -f "$envfile" ]]; then
    log "WARN: .env tidak ketemu ($label): $envfile (skip DB dump)"
    return 0
  fi

  local conn host port db user pass
  conn="$(read_env "$envfile" DB_CONNECTION)"
  host="$(read_env "$envfile" DB_HOST)"
  port="$(read_env "$envfile" DB_PORT)"
  db="$(read_env "$envfile" DB_DATABASE)"
  user="$(read_env "$envfile" DB_USERNAME)"
  pass="$(read_env "$envfile" DB_PASSWORD)"

  host="${host:-127.0.0.1}"

  if [[ -z "$conn" || -z "$db" || -z "$user" ]]; then
    log "WARN: DB_* tidak lengkap ($label) di $envfile (skip DB dump)"
    return 0
  fi

  if [[ "$conn" == "mysql" || "$conn" == "mariadb" ]]; then
    need mysqldump
    need stat
    port="${port:-3306}"
    log "DB dump ($label): mysql/mariadb $user@$host:$port/$db"

    local tmpcnf
    tmpcnf="$(mktemp)"
    chmod 600 "$tmpcnf"
    cat >"$tmpcnf" <<EOF
[client]
user=$user
password=$pass
host=$host
port=$port
EOF

    # opsi aman lintas MySQL/MariaDB (hindari error unknown variable)
    local extra_opts=()

    # MySQL punya, MariaDB sering tidak punya
    if mysqldump --help 2>/dev/null | grep -q -- '--set-gtid-purged'; then
      extra_opts+=(--set-gtid-purged=OFF)
    fi

    # MySQL 8 client kadang butuh ini saat dump ke server lama
    if mysqldump --help 2>/dev/null | grep -q -- '--column-statistics'; then
      extra_opts+=(--column-statistics=0)
    fi

    # Dump: harus fail kalau error
    if ! mysqldump --defaults-extra-file="$tmpcnf" \
      --single-transaction --routines --triggers \
      "${extra_opts[@]}" \
      "$db" > "$out_sql"; then
      rm -f "$tmpcnf"
      rm -f "$out_sql"
      log "ERROR: mysqldump gagal ($label)"
      return 1
    fi

    rm -f "$tmpcnf"

    # Validasi dump minimal (biar gak kejadian file 0/13 bytes)
    local sz
    sz="$(stat -c%s "$out_sql" 2>/dev/null || echo 0)"
    if [[ "$sz" -lt 200 ]]; then
      log "ERROR: hasil dump terlalu kecil (${sz} bytes) kemungkinan dump gagal ($label)"
      rm -f "$out_sql"
      return 1
    fi

  elif [[ "$conn" == "pgsql" || "$conn" == "postgres" || "$conn" == "postgresql" ]]; then
    need pg_dump
    need stat
    port="${port:-5432}"
    log "DB dump ($label): postgres $user@$host:$port/$db"

    if ! PGPASSWORD="$pass" pg_dump -h "$host" -p "$port" -U "$user" -F p "$db" > "$out_sql"; then
      rm -f "$out_sql"
      log "ERROR: pg_dump gagal ($label)"
      return 1
    fi

    local sz
    sz="$(stat -c%s "$out_sql" 2>/dev/null || echo 0)"
    if [[ "$sz" -lt 200 ]]; then
      log "ERROR: hasil dump terlalu kecil (${sz} bytes) kemungkinan dump gagal ($label)"
      rm -f "$out_sql"
      return 1
    fi

  else
    log "WARN: DB_CONNECTION=$conn belum didukung ($label). Skip."
    return 0
  fi
}

backup_app() {
  local name="$1" path="$2"

  if [[ ! -d "$path" ]]; then
    log "WARN: folder app $name tidak ada: $path (skip)"
    return 0
  fi

  compress_setup
  log "Backup APP: $name ($path) mode=${BACKUP_MODE:-full} compress=${COMPRESS:-gzip}"

  local envfile="$path/.env"

  # 1) DB dump
  local db_sql="$WORKDIR/${name}_db.sql"
  dump_db_from_env "$envfile" "$db_sql" "$name"
  compress_db_file "$db_sql" || true

  # 2) Nice + ionice (biar VPS adem)
  renice +10 $$ >/dev/null 2>&1 || true
  ionice -c2 -n7 -p $$ >/dev/null 2>&1 || true

  # 3) Files tar
  local tar_out="$WORKDIR/${name}_files.${COMP_EXT}"
  mapfile -t excludes < <(build_excludes)

  tar --xattrs --acls "${TAR_COMPRESS_ARGS[@]}" -cf "$tar_out" \
    "${excludes[@]}" \
    -C "$(dirname "$path")" "$(basename "$path")"

  sha256sum "$tar_out" > "$WORKDIR/${name}_SHA256SUMS.txt" 2>/dev/null || true
}

backup_system_configs() {
  compress_setup
  log "Backup system configs (nginx/letsencrypt/pterodactyl/systemd/cron)"

  local out="$WORKDIR/system_configs.${COMP_EXT}"

  # aman walau sebagian path tidak ada
  tar "${TAR_COMPRESS_ARGS[@]}" -cf "$out" \
    /etc/nginx \
    /etc/letsencrypt \
    /etc/pterodactyl \
    /etc/systemd/system \
    /etc/crontab \
    /var/spool/cron/crontabs 2>/dev/null || true

  sha256sum "$out" > "$WORKDIR/system_configs_SHA256SUMS.txt" 2>/dev/null || true
}

cleanup_local() {
  local days="${KEEP_LOCAL_DAYS:-7}"
  log "Cleanup local > ${days} hari di $BACKUP_DIR"
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime "+$days" -print -exec rm -rf {} \; 2>/dev/null || true
}

cleanup_remote_rclone() {
  [[ -z "${RCLONE_REMOTE:-}" ]] && return 0
  if ! have rclone; then
    log "WARN: rclone tidak ada, skip remote cleanup"
    return 0
  fi
  local days="${KEEP_REMOTE_DAYS:-30}"
  log "Cleanup remote rclone > ${days} hari: ${RCLONE_REMOTE}"
  rclone delete "${RCLONE_REMOTE}" --min-age "${days}d" >/dev/null 2>&1 || true
  rclone rmdirs "${RCLONE_REMOTE}" --leave-root >/dev/null 2>&1 || true
}

upload_all() {
  # Rclone
  if [[ -n "${RCLONE_REMOTE:-}" ]]; then
    if ! have rclone; then
      log "WARN: RCLONE_REMOTE diisi tapi rclone tidak terpasang. Skip upload."
    else
      log "Upload via rclone -> ${RCLONE_REMOTE}/$STAMP"
      rclone copy "$WORKDIR" "${RCLONE_REMOTE%/}/$STAMP" --create-empty-src-dirs
      cleanup_remote_rclone || true
    fi
  fi

  # Rsync SSH (opsional)
  if [[ -n "${SSH_DEST:-}" ]]; then
    need rsync
    log "Upload via rsync -> ${SSH_DEST}/$STAMP"
    RSYNC_RSH="ssh ${RSYNC_SSH_OPTS:-}" rsync -aH --delete "$WORKDIR/" "${SSH_DEST%/}/$STAMP/"
  fi
}

main() {
  if [[ ! -f "$CONF" ]]; then
    echo "Config tidak ditemukan: $CONF" >&2
    exit 1
  fi

  # shellcheck disable=SC1090
  source "$CONF"

  need tar
  need sha256sum
  need find
  need flock
  need stat

  # anti dobel jalan
  LOCK_FILE="/var/lock/segeng-full-backup.lock"
  exec 9>"$LOCK_FILE"
  flock -n 9 || { log "Backup sedang berjalan (lock aktif). Keluar."; exit 0; }

  mkdir -p "${BACKUP_DIR:?}"

  STAMP="$(date +%F_%H-%M-%S)"
  WORKDIR="$BACKUP_DIR/$STAMP"
  mkdir -p "$WORKDIR"

  log "===== START FULL BACKUP ($STAMP) ====="
  discord_notify "🟦 Mulai backup FULL: $STAMP" || true

  # Backup panel + ctrlpanel + configs
  backup_app "pterodactyl_panel" "${PTERO_PANEL_PATH:-/var/www/pterodactyl}"
  backup_app "ctrlpanel" "${CTRLPANEL_PATH:-/var/www/ctrlpanel}"
  backup_system_configs || true

  upload_all || true
  cleanup_local || true

  log "===== DONE: OK ($STAMP) ====="
  discord_notify "✅ Backup FULL selesai: $STAMP" || true
}

main "$@"
