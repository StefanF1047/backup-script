#!/usr/bin/env bash
#
# backup.sh - Safely back up folders and files listed in backup.json.
#
# Usage:
#   ./backup.sh <output_folder> [config_file]
#
# backup.json must contain an array of RELATIVE paths (folders or files), e.g.:
#   {
#     "folders": [
#       "folders",
#       "documents",
#       "media/photos",
#       "configs/nginx.conf",
#       ".bashrc"
#     ]
#   }
#
# Behavior:
#   - Errors out immediately if backup.json is missing or malformed.
#   - Refuses to run without an explicit output folder.
#   - Additive backup: existing files are kept, new files are added.
#     Nothing is ever deleted from the destination.
#   - Directories are copied recursively.
#   - Individual files are copied into the same relative path in the output.
#

set -euo pipefail
IFS=$'\n\t'

# ---------- Paths ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE="${SCRIPT_DIR}/backup.json"

# ---------- Logging ----------
log()   { printf '[%s] [INFO ] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
ok()    { printf '[%s] [ OK  ] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn()  { printf '[%s] [WARN ] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
err()   { printf '[%s] [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

die() { err "$*"; exit 1; }

# ---------- Usage ----------
usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <output_folder> [config_file]

  <output_folder>  Required. Folder where the backup will be written.
                   It will be created if it does not exist.

  [config_file]    Optional. Default: ${SCRIPT_DIR}/backup.json

Example:
  $(basename "$0") /mnt/backup/$(date +%Y-%m-%d)
EOF
  exit 1
}

# ---------- Argument check ----------
if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
fi

OUTPUT_DIR_ARG="$1"
[[ -n "${OUTPUT_DIR_ARG// }" ]] || die "Output folder argument is empty."

if [[ $# -eq 2 ]]; then
  CONFIG_FILE="$2"
fi

# ---------- Dependency check ----------
for cmd in jq rsync realpath; do
  command -v "$cmd" >/dev/null 2>&1 \
    || die "Required command '$cmd' not found. Please install it (jq, rsync, coreutils)."
done

# ---------- Config existence ----------
if [[ ! -e "$CONFIG_FILE" ]]; then
  err "Config file not found: $CONFIG_FILE"
  cat >&2 <<EOF

Create a file named 'backup.json' next to this script with content like:

  {
    "folders": [
      "folders",
      "documents",
      "projects/my-app",
      "configs/nginx.conf",
      ".bashrc"
    ]
  }

Rules:
  - Top-level key MUST be "folders".
  - Value MUST be an array of strings.
  - Each string is a RELATIVE path (relative to this script's directory).
    Use "documents/photos", NOT "/home/user/documents/photos".
  - Each entry must be an existing file or directory.

EOF
  exit 1
fi

# ---------- Config validation ----------
if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
  die "Invalid JSON in config file: $CONFIG_FILE"
fi

if ! jq -e 'has("folders") and (.folders | type == "array")' "$CONFIG_FILE" >/dev/null 2>&1; then
  die "Config 'folders' key missing or not an array in: $CONFIG_FILE"
fi

mapfile -t FOLDERS < <(jq -r '.folders[]? | select(type == "string")' "$CONFIG_FILE")

if [[ ${#FOLDERS[@]} -eq 0 ]]; then
  die "No valid entries in '$CONFIG_FILE' under 'folders'."
fi

# ---------- Resolve + validate output dir ----------
mkdir -p "$OUTPUT_DIR_ARG" 2>/dev/null \
  || die "Cannot create output folder: $OUTPUT_DIR_ARG"
[[ -d "$OUTPUT_DIR_ARG" ]] \
  || die "Output path is not a directory: $OUTPUT_DIR_ARG"
OUTPUT_DIR="$(realpath -e "$OUTPUT_DIR_ARG")" \
  || die "Cannot resolve output folder: $OUTPUT_DIR_ARG"
[[ -w "$OUTPUT_DIR" ]] \
  || die "Output folder is not writable: $OUTPUT_DIR"

# Refuse to back up the output folder into itself
OUTPUT_PREFIX="${OUTPUT_DIR%/}/"

log "Backup script started"
log "Script directory : $SCRIPT_DIR"
log "Config file      : $CONFIG_FILE"
log "Output directory : $OUTPUT_DIR"
log "Entries in config: ${#FOLDERS[@]}"

# ---------- Backup run log ----------
RUN_LOG="${OUTPUT_DIR}/backup.log"
touch "$RUN_LOG" 2>/dev/null \
  || die "Cannot write to run log: $RUN_LOG"
# Tee everything after this point
exec > >(tee -a "$RUN_LOG") 2>&1

# ---------- Loop ----------
TOTAL=0
SUCCESS=0
SKIPPED=0
FAILED=0
declare -a FAILED_LIST=()
declare -a SKIPPED_LIST=()

START_ALL=$(date +%s)

for src_rel in "${FOLDERS[@]}"; do
  TOTAL=$((TOTAL + 1))
  echo
  log "------------------------------------------------------------"
  log "[$TOTAL/${#FOLDERS[@]}] Processing: '$src_rel'"

  # Reject absolute paths early
  if [[ "$src_rel" == /* ]]; then
    warn "Entry is an absolute path; skipping: $src_rel"
    SKIPPED=$((SKIPPED + 1))
    SKIPPED_LIST+=("$src_rel (absolute path)")
    continue
  fi

  SRC="${SCRIPT_DIR}/${src_rel}"
  SRC="$(realpath -m "$SRC")"   # -m allows non-existent

  log "  Source: $SRC"

  if [[ ! -e "$SRC" ]]; then
    warn "Source does not exist; skipping: $SRC"
    SKIPPED=$((SKIPPED + 1))
    SKIPPED_LIST+=("$src_rel (missing)")
    continue
  fi

  # [FILE SUPPORT] Accept both directories and regular files.
  if [[ ! -d "$SRC" && ! -f "$SRC" ]]; then
    warn "Source is neither a file nor a directory; skipping: $SRC"
    SKIPPED=$((SKIPPED + 1))
    SKIPPED_LIST+=("$src_rel (not file/dir)")
    continue
  fi

  # Never allow the output folder to end up inside the source
  if [[ -d "$SRC" && "${SRC%/}/" == "$OUTPUT_PREFIX"* ]]; then
    warn "Output folder is inside source '$src_rel'; skipping to avoid recursion."
    SKIPPED=$((SKIPPED + 1))
    SKIPPED_LIST+=("$src_rel (output inside source)")
    continue
  fi

  DEST="${OUTPUT_DIR}/${src_rel}"
  log "  Destination: $DEST"
  mkdir -p "$(dirname "$DEST")"

  START_ONE=$(date +%s)

  # Additive backup:
  #   -a  archive (perms, times, symlinks, owner/group)
  #   -H  preserve hard links
  #   -A  preserve ACLs
  #   -X  preserve xattrs
  #   --ignore-existing  -> do NOT overwrite existing files
  #   (no --delete, no --remove-source-files)
  #
  # [FILE SUPPORT] Directories: rsync SRC/ -> DEST/ (copy contents).
  #                Files:       rsync SRC  -> DEST  (DEST is the file path).
  if [[ -d "$SRC" ]]; then
    RSYNC_SRC="$SRC/"
    RSYNC_DST="$DEST/"
    KIND="directory"
  else
    RSYNC_SRC="$SRC"
    RSYNC_DST="$DEST"
    KIND="file"
  fi

  if rsync -aHAX \
        --ignore-existing \
        --info=name \
        --human-readable \
        --stats \
        "$RSYNC_SRC" "$RSYNC_DST"; then
    END_ONE=$(date +%s)
    DUR=$((END_ONE - START_ONE))
    if [[ "$KIND" == "directory" ]]; then
      SIZE=$(du -sh "$DEST" 2>/dev/null | awk '{print $1}')
    else
      SIZE=$(du -h "$DEST" 2>/dev/null | awk '{print $1}')
    fi
    ok "Backed up $KIND '$src_rel' -> '$DEST'  (size: ${SIZE:-?}, ${DUR}s)"
    SUCCESS=$((SUCCESS + 1))
  else
    rc=$?
    err "rsync failed for '$src_rel' (exit $rc)"
    FAILED=$((FAILED + 1))
    FAILED_LIST+=("$src_rel (rsync exit $rc)")
  fi
done

END_ALL=$(date +%s)
DUR_ALL=$((END_ALL - START_ALL))

# ---------- Manifest ----------
MANIFEST="${OUTPUT_DIR}/manifest.txt"
{
  echo "Backup manifest"
  echo "Generated : $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Host      : $(hostname)"
  echo "Config    : $CONFIG_FILE"
  echo "Output    : $OUTPUT_DIR"
  echo
  echo "Entries attempted:"
  printf '  - %s\n' "${FOLDERS[@]}"
} > "$MANIFEST"

# ---------- Summary ----------
echo
log "=================== BACKUP SUMMARY ==================="
log "Total entries : $TOTAL"
ok  "Succeeded     : $SUCCESS"
log "Skipped       : $SKIPPED"
if (( SKIPPED > 0 )); then
  for s in "${SKIPPED_LIST[@]}"; do warn "  - $s"; done
fi
if (( FAILED > 0 )); then
  err "Failed        : $FAILED"
  for f in "${FAILED_LIST[@]}"; do err "  - $f"; done
else
  log "Failed        : 0"
fi
log "Elapsed       : ${DUR_ALL}s"
log "Output folder : $OUTPUT_DIR"
log "Run log       : $RUN_LOG"
log "Manifest      : $MANIFEST"
log "====================================================="

if (( FAILED > 0 )); then
  exit 2
fi
exit 0