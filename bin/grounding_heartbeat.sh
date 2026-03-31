#!/usr/bin/env bash
# ============================================================
# Helix AI — Grounding Heartbeat
# Usage: ./bin/grounding_heartbeat.sh /Path/To/DMS_Exports workspace-slug
# Monitors a folder for new documents and automatically ingests them for RAG.
# ============================================================

set -euo pipefail

BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info(){ echo -e "${BLUE}[$(date +'%H:%M:%S')]  →  $1${NC}"; }
ok()  { echo -e "${GREEN}[$(date +'%H:%M:%S')]  ✔  $1${NC}"; }

WATCH_DIR="${1:-}"
WORKSPACE="${2:-qa-confidential}"

if [[ -z "$WATCH_DIR" || ! -d "$WATCH_DIR" ]]; then
  echo "Error: Please provide a valid directory to watch."
  echo "Usage: $0 /path/to/watch [workspace-slug]"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELIX_INGEST="$SCRIPT_DIR/ingest_docs.sh"

info "Helix Grounding Heartbeat Started"
info "Watching directory: $WATCH_DIR"
info "Targeting workspace: $WORKSPACE"

# State file to keep track of processed files
STATE_FILE="/tmp/helix_grounding_state_$(echo "$WATCH_DIR" | md5 | head -c 8).txt"
touch "$STATE_FILE"

while true; do
  # Find all files in watch dir
  find "$WATCH_DIR" -type f \( -name "*.pdf" -o -name "*.docx" -o -name "*.txt" -o -name "*.csv" \) > /tmp/current_files.txt

  # Compare with already processed files
  NEW_FILES=$(grep -Fxv -f "$STATE_FILE" /tmp/current_files.txt || true)

  if [[ -n "$NEW_FILES" ]]; then
    info "Detected new documents from DMS/TMS workflow..."
    
    # Process each new file
    while IFS= read -r file; do
      info "Automating ingestion for: $(basename "$file")"
      
      # Use the base ingestion script
      if bash "$HELIX_INGEST" "$WORKSPACE" "$file"; then
        ok "Successfully grounded: $(basename "$file")"
        echo "$file" >> "$STATE_FILE"
      else
        echo "Failed to ingest $file"
      fi
    done <<< "$NEW_FILES"
    
    info "All new documents successfully added to Helix AI context."
  fi

  # Sleep for a bit before checking again
  sleep 10
done
