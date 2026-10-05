#!/usr/bin/env bash
# Sauvegardes de Digit Gateway : base MySQL + fichiers uploadés (logos, preuves de transfert,
# pièces KYC). Modes :
#   daemon              (défaut) sauvegarde chaque jour à BACKUP_TIME (UTC), test de restauration hebdomadaire
#   once                lance une sauvegarde maintenant
#   verify [fichier]    restaure un dump (le dernier par défaut) dans une base jetable et compte les lignes
#   restore <fichier>   restaure un dump dans la base de production (exige --yes, ÉCRASE les données)
#
# Configuration par variables d'environnement (voir deploy/.env.example).
set -Eeuo pipefail
umask 077

DB_HOST="${DB_HOST:-db}"
DB_NAME="${DB_DATABASE:?DB_DATABASE manquant}"
export MYSQL_PWD="${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD manquant}"
BACKUP_DIR="${BACKUP_DIR:-/backups}"
STORAGE_DIR="${STORAGE_DIR:-/storage}"
BACKUP_TIME="${BACKUP_TIME:-02:30}"                     # HH:MM, UTC
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
MIN_FREE_MB="${BACKUP_MIN_FREE_MB:-1024}"
MIN_DUMP_BYTES="${BACKUP_MIN_DUMP_BYTES:-1024}"        # en dessous : dump jugé anormal
VERIFY_WEEKDAY="${BACKUP_VERIFY_WEEKDAY-7}"             # 1=lundi … 7=dimanche ; vide = désactivé
PASSPHRASE="${BACKUP_PASSPHRASE:-}"                     # chiffre les fichiers (AES-256) si défini
RCLONE_REMOTE="${BACKUP_RCLONE_REMOTE:-}"               # ex. offsite:digit-backups/prod
ALERT_URL="${BACKUP_ALERT_WEBHOOK_URL:-}"
HEARTBEAT_URL="${BACKUP_HEARTBEAT_URL:-}"
STATUS_FILE="$BACKUP_DIR/status.json"
MYSQL_ARGS=(-h "$DB_HOST" -uroot)

# stderr : stdout sert à renvoyer les noms de fichiers des fonctions appelées via $(…).
log() { printf '%s [backup] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

alert() {
  log "ALERTE : $*"
  [ -n "$ALERT_URL" ] || return 0
  # `text` (Slack/Mattermost) et `content` (Discord) : le même message passe partout.
  local msg; msg="Digit Gateway — sauvegarde : $*"
  curl -fsS -m 15 -H 'Content-Type: application/json' \
    -d "{\"text\":\"${msg//\"/\\\"}\",\"content\":\"${msg//\"/\\\"}\"}" "$ALERT_URL" >/dev/null 2>&1 || log "envoi de l'alerte impossible"
}

# État lisible par une supervision externe : /backups/status.json (clés plates, valeurs texte).
# Stocké en clé=valeur (status.env) puis rendu en JSON : pas de dépendance à jq.
write_status() {
  local env="$BACKUP_DIR/status.env" tmp
  tmp="$(mktemp -p "$BACKUP_DIR" .status.XXXXXX)"
  { [ -f "$env" ] && grep -v "^$1=" "$env" || true; printf '%s=%s\n' "$1" "$2"; } > "$tmp"
  mv "$tmp" "$env"
  awk -F= 'BEGIN { printf "{" } { v=substr($0, index($0, "=")+1); gsub(/"/, "\\\"", v); printf "%s\"%s\": \"%s\"", (NR>1 ? ", " : ""), $1, v } END { print "}" }' "$env" > "$tmp.json"
  mv "$tmp.json" "$STATUS_FILE"
}

encrypt_if_needed() { # fichier → fichier(.enc), supprime l'original
  local f="$1"
  [ -n "$PASSPHRASE" ] || { echo "$f"; return; }
  openssl enc -aes-256-cbc -pbkdf2 -salt -pass env:PASSPHRASE -in "$f" -out "$f.enc"
  rm -f "$f"
  echo "$f.enc"
}
export PASSPHRASE

decrypt_to_stdout() { # fichier → flux clair
  case "$1" in
    *.enc) [ -n "$PASSPHRASE" ] || { log "BACKUP_PASSPHRASE requis pour lire $1"; return 1; }
           openssl enc -d -aes-256-cbc -pbkdf2 -pass env:PASSPHRASE -in "$1" ;;
    *) cat "$1" ;;
  esac
}

wait_for_db() {
  for _ in $(seq 1 30); do
    mysqladmin --silent "${MYSQL_ARGS[@]}" ping >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

# --------------------------------------------------------------------------- sauvegarde

backup_db() {
  local stamp="$1" out="$BACKUP_DIR/digit-db-$stamp.sql.gz"

  mysqldump "${MYSQL_ARGS[@]}" --single-transaction --routines --triggers --events \
    --set-gtid-purged=OFF --no-tablespaces "$DB_NAME" | gzip -9 > "$out.partial"

  # Un dump tronqué est pire que pas de dump : on exige un gzip valide ET la ligne finale de mysqldump.
  gzip -t "$out.partial"
  # (variable intermédiaire : `grep -q` fermerait le tube trop tôt et, avec pipefail, ferait échouer la ligne)
  local trailer; trailer="$(gzip -dc "$out.partial" | tail -n 5)"
  grep -q 'Dump completed' <<<"$trailer" || { rm -f "$out.partial"; log "dump incomplet"; return 1; }
  [ "$(stat -c %s "$out.partial")" -gt "$MIN_DUMP_BYTES" ] || { rm -f "$out.partial"; log "dump anormalement petit"; return 1; }

  mv "$out.partial" "$out"
  encrypt_if_needed "$out"
}

backup_files() {
  local stamp="$1" out="$BACKUP_DIR/digit-files-$stamp.tar.gz"

  if [ ! -d "$STORAGE_DIR/app" ]; then log "pas de fichiers à sauvegarder ($STORAGE_DIR/app absent)"; return 0; fi

  # storage/app : logos, drapeaux, preuves de transfert et pièces KYC (privées). Les logs et caches sont exclus.
  tar czf "$out.partial" -C "$STORAGE_DIR" app
  gzip -t "$out.partial"
  mv "$out.partial" "$out"
  encrypt_if_needed "$out"
}

run_backup() {
  local stamp; stamp="$(date -u +%Y%m%d-%H%M%S)"
  local free; free="$(df -Pm "$BACKUP_DIR" | awk 'NR==2 {print $4}')"

  if [ "${free:-0}" -lt "$MIN_FREE_MB" ]; then
    alert "espace disque insuffisant sur le serveur (${free} Mo libres, minimum ${MIN_FREE_MB} Mo)."
    return 1
  fi

  log "sauvegarde $stamp…"
  local db_file files_file
  db_file="$(backup_db "$stamp")" || { log "échec de la sauvegarde de la base"; return 1; }
  files_file="$(backup_files "$stamp")" || { log "échec de la sauvegarde des fichiers"; return 1; }

  # Empreintes : détectent une corruption ou un fichier modifié lors d'une restauration ultérieure.
  ( cd "$BACKUP_DIR" && sha256sum "$(basename "$db_file")" ${files_file:+"$(basename "$files_file")"} > "digit-$stamp.sha256" ) 2>/dev/null || true

  log "base : $(basename "$db_file") ($(du -h "$db_file" | cut -f1))"

  prune_local
  upload_offsite "$db_file" "$files_file" "$BACKUP_DIR/digit-$stamp.sha256" || return 1

  write_status last_success "$(date -u +%FT%TZ)"
  write_status last_db_file "$(basename "$db_file")"
  return 0
}

prune_local() {
  find "$BACKUP_DIR" -maxdepth 1 -type f \( -name 'digit-*' \) -mtime "+$RETENTION_DAYS" -delete
}

upload_offsite() {
  [ -n "$RCLONE_REMOTE" ] || return 0
  local f
  for f in "$@"; do
    [ -f "$f" ] || continue
    rclone copy "$f" "$RCLONE_REMOTE" --retries 3 --low-level-retries 5 --timeout 120s || { alert "copie hors serveur échouée ($(basename "$f"))."; return 1; }
  done
  rclone delete "$RCLONE_REMOTE" --min-age "${RETENTION_DAYS}d" >/dev/null 2>&1 || true
  log "copie hors serveur terminée → $RCLONE_REMOTE"
}

# ------------------------------------------------------ test de restauration (verify)

latest_db_dump() { ls -1t "$BACKUP_DIR"/digit-db-*.sql.gz* 2>/dev/null | grep -v '\.partial$' | head -n 1; }

verify_backup() {
  local file="${1:-$(latest_db_dump)}"
  [ -n "$file" ] && [ -f "$file" ] || { alert "aucun dump à vérifier."; return 1; }

  local scratch="digit_restore_check"
  log "vérification de $(basename "$file") dans la base jetable $scratch…"

  # Empreinte (si présente) avant toute restauration.
  local sumfile; sumfile="$(ls -1 "$BACKUP_DIR"/digit-*.sha256 2>/dev/null | while read -r s; do grep -q "$(basename "$file")" "$s" && echo "$s" && break; done || true)"
  if [ -n "${sumfile:-}" ]; then
    ( cd "$BACKUP_DIR" && grep "$(basename "$file")" "$sumfile" | sha256sum -c --quiet - ) || { alert "empreinte invalide pour $(basename "$file") : fichier corrompu."; return 1; }
  fi

  mysql "${MYSQL_ARGS[@]}" -e "DROP DATABASE IF EXISTS $scratch; CREATE DATABASE $scratch;"
  if ! decrypt_to_stdout "$file" | gzip -dc | mysql "${MYSQL_ARGS[@]}" "$scratch"; then
    mysql "${MYSQL_ARGS[@]}" -e "DROP DATABASE IF EXISTS $scratch;" || true
    alert "la restauration de test a ÉCHOUÉ pour $(basename "$file")."
    return 1
  fi

  local tables users txs
  tables="$(mysql "${MYSQL_ARGS[@]}" -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$scratch'")"
  users="$(mysql "${MYSQL_ARGS[@]}" -N -e "SELECT COUNT(*) FROM $scratch.users" 2>/dev/null || echo 0)"
  txs="$(mysql "${MYSQL_ARGS[@]}" -N -e "SELECT COUNT(*) FROM $scratch.transactions" 2>/dev/null || echo 0)"
  mysql "${MYSQL_ARGS[@]}" -e "DROP DATABASE $scratch;"

  if [ "$tables" -lt 5 ]; then
    alert "restauration de test suspecte : seulement $tables tables dans $(basename "$file")."
    return 1
  fi

  log "restauration de test OK : $tables tables, $users utilisateurs, $txs transactions."
  write_status last_verify "$(date -u +%FT%TZ) ($tables tables, $users users, $txs transactions)"
}

restore_backup() {
  local file="${1:-}" confirm="${2:-}"
  [ -f "$file" ] || { log "fichier introuvable : $file"; return 1; }
  [ "$confirm" = "--yes" ] || { log "ATTENTION : écrase la base '$DB_NAME'. Relancez avec --yes pour confirmer."; return 2; }

  log "restauration de $(basename "$file") dans $DB_NAME…"
  decrypt_to_stdout "$file" | gzip -dc | mysql "${MYSQL_ARGS[@]}" "$DB_NAME"
  log "restauration terminée."
}

# --------------------------------------------------------------------------- boucle

seconds_until_next_run() {
  local now target
  now="$(date -u +%s)"
  target="$(date -u -d "today $BACKUP_TIME" +%s)"
  [ "$target" -gt "$now" ] || target="$(date -u -d "tomorrow $BACKUP_TIME" +%s)"
  echo $((target - now))
}

cycle() {
  if ! wait_for_db; then alert "base de données injoignable."; write_status last_failure "$(date -u +%FT%TZ)"; return 1; fi

  if run_backup; then
    [ -n "$HEARTBEAT_URL" ] && curl -fsS -m 15 "$HEARTBEAT_URL" >/dev/null 2>&1 || true
    if [ -n "$VERIFY_WEEKDAY" ] && [ "$(date -u +%u)" = "$VERIFY_WEEKDAY" ]; then verify_backup || true; fi
  else
    write_status last_failure "$(date -u +%FT%TZ)"
    alert "la sauvegarde du $(date -u +%F) a ÉCHOUÉ."
    return 1
  fi
}

mkdir -p "$BACKUP_DIR"

case "${1:-daemon}" in
  once)    cycle ;;
  verify)  wait_for_db; verify_backup "${2:-}" ;;
  restore) wait_for_db; restore_backup "${2:-}" "${3:-}" ;;
  daemon)
    [ -n "$RCLONE_REMOTE" ] || log "AVERTISSEMENT : aucune copie hors serveur configurée (BACKUP_RCLONE_REMOTE) — une panne du serveur perdrait aussi les sauvegardes."
    [ -n "$PASSPHRASE" ]   || log "AVERTISSEMENT : sauvegardes non chiffrées (BACKUP_PASSPHRASE vide) ; elles contiennent des données personnelles et des pièces KYC."
    log "planification : tous les jours à $BACKUP_TIME UTC, conservation ${RETENTION_DAYS} jours."
    while true; do
      sleep "$(seconds_until_next_run)"
      cycle || true
    done ;;
  *) echo "Usage : backup.sh [daemon|once|verify [fichier]|restore <fichier> --yes]" >&2; exit 64 ;;
esac
