#!/usr/bin/env bash
# ============================================================
# PharmaCX POC — Ingest documents into workspaces
# Usage: ./04_ingest_docs.sh [workspace_slug] [file_or_folder]
# Example: ./04_ingest_docs.sh qa-confidential ./documents/qa/
# ============================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

ok()  { echo -e "${GREEN}  ✔  $1${NC}"; }
info(){ echo -e "${BLUE}  →  $1${NC}"; }
warn(){ echo -e "${YELLOW}  ⚠  $1${NC}"; }
err() { echo -e "${RED}  ✖  $1${NC}"; exit 1; }

ANYTHINGLLM="http://localhost:3002"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

[[ -f "$PROJECT_DIR/settings/.env" ]] && { set -a; source "$PROJECT_DIR/settings/.env"; set +a; }
AUTH_TOKEN="${AUTH_TOKEN:-helix-ai-secret-change-me}"

WORKSPACE=${1:-"qa-confidential"}
TARGET=${2:-"$PROJECT_DIR/documents/qa"}

echo ""
echo -e "${CYAN}PharmaCX Document Ingestion${NC}"
echo -e "  Workspace : $WORKSPACE"
echo -e "  Source    : $TARGET"
echo ""

# Check AnythingLLM is up
curl -s "$ANYTHINGLLM/api/health" &>/dev/null || err "AnythingLLM not running. Run ./setup.sh first."

# List supported types
SUPPORTED_TYPES=("pdf" "txt" "docx" "md" "csv" "xlsx" "json" "htm" "html")

ingest_file() {
  local file=$1
  ext=$(echo "${file##*.}" | tr '[:upper:]' '[:lower:]')

  # Check supported
  local supported=false
  for t in "${SUPPORTED_TYPES[@]}"; do [[ "$ext" == "$t" ]] && supported=true && break; done
  if [[ "$supported" == "false" ]]; then
    warn "Skipping unsupported file type: $file"
    return
  fi

  local filename=$(basename "$file")
  info "Uploading: $filename → workspace: $WORKSPACE"

  # Upload to AnythingLLM document collector
  UPLOAD_RESP=$(curl -s -X POST \
    "$ANYTHINGLLM/api/v1/document/upload" \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -F "file=@$file" 2>/dev/null || echo "{}")

  if echo "$UPLOAD_RESP" | grep -q "success\|document"; then
    # Get the document location from response
    DOC_LOCATION=$(echo "$UPLOAD_RESP" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); docs=d.get('documents',[]); print(docs[0].get('location','') if docs else '')" \
      2>/dev/null || echo "")

    if [[ -n "$DOC_LOCATION" ]]; then
      # Embed into workspace
      EMBED_RESP=$(curl -s -X POST \
        "$ANYTHINGLLM/api/v1/workspace/$WORKSPACE/update-embeddings" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"adds\": [\"$DOC_LOCATION\"], \"deletes\": []}" 2>/dev/null || echo "{}")

      if echo "$EMBED_RESP" | grep -q "workspace\|success"; then
        ok "$filename — uploaded and embedded"
      else
        warn "$filename — uploaded but embedding may have failed"
      fi
    else
      ok "$filename — uploaded (embedding will occur in background)"
    fi
  else
    warn "Upload may have failed for: $filename"
    warn "Response: $(echo $UPLOAD_RESP | head -c 200)"
  fi
}

# Ingest directory or single file
if [[ -d "$TARGET" ]]; then
  FILE_COUNT=$(find "$TARGET" -type f | wc -l | tr -d ' ')
  info "Found $FILE_COUNT files in $TARGET"
  echo ""

  find "$TARGET" -type f | sort | while read -r file; do
    ingest_file "$file"
  done

  echo ""
  ok "Ingestion complete for workspace: $WORKSPACE"

elif [[ -f "$TARGET" ]]; then
  ingest_file "$TARGET"
  ok "File ingested into workspace: $WORKSPACE"

else
  err "Path not found: $TARGET"
fi

echo ""
echo -e "${CYAN}Tip:${NC} Ingested documents are now searchable in the $WORKSPACE workspace."
echo -e "Open ${BLUE}http://localhost:3002${NC} → select workspace → start querying."
echo ""
