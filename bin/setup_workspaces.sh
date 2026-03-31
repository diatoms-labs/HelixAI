#!/usr/bin/env bash
# ============================================================
# Helix AI — Workspace Setup & Document Ingestion
# Final version: Direct API calls with Bearer token
# ============================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

ok()  { echo -e "${GREEN}  ✔  $1${NC}"; }
info(){ echo -e "${BLUE}  →  $1${NC}"; }
warn(){ echo -e "${YELLOW}  ⚠  $1${NC}"; }

ANYTHINGLLM="http://localhost:3002"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source the generated API key
ENV_FILE="$PROJECT_DIR/settings/.env"
if [[ -f "$ENV_FILE" ]]; then
  # Sourcing it handles quotes automatically
  source "$ENV_FILE"
else
  echo -e "${RED}  ✖  settings/.env missing! Generate API key first.${NC}"
  exit 1
fi

# Bearer token for all requests
AUTH_HEADER="Authorization: Bearer $AUTH_TOKEN"

# ── Wait for API ────────────────────────────────────────────────
info "Waiting for Helix AI API..."
for i in {1..20}; do
  STATUS=$(curl -s -X GET "$ANYTHINGLLM/api/v1/auth" -H "$AUTH_HEADER" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print('ok' if d.get('authenticated') or d.get('valid') else 'fail')" 2>/dev/null || echo "")
  [[ "$STATUS" == "ok" ]] && { ok "API is online and authenticated"; break; }
  sleep 3
done

# ── Setup helper ───────────────────────────────────────────────
create_workspace() {
  local name=$1
  local slug=$2
  local prompt=$3

  info "Setting up workspace: $name..."

  # Try to create workspace
  RESP=$(curl -s -X POST "$ANYTHINGLLM/api/v1/workspace/new" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"$name\"}" 2>/dev/null || echo "{}")

  if echo "$RESP" | grep -v 'Already exists' | grep -q "workspace"; then
    ok "$name created"
  else
    warn "$name already exists (or creation skipped)"
  fi

  # Update workspace settings
  curl -s -X POST "$ANYTHINGLLM/api/v1/workspace/$slug/update" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d "{
      \"openAiPrompt\": \"$prompt\",
      \"chatModel\": \"helix-ai:latest\",
      \"similarityThreshold\": 0.6,
      \"topN\": 5
    }" > /dev/null

  ok "$name configured for helix-ai:latest"
}

# ── Define Workspaces ──────────────────────────────────────────
create_workspace "QA Confidential" "qa-confidential" "You are a pharma QA assistant. Answer only from the provided SOPs. Cite your sources."
create_workspace "RD Internal" "rd-internal" "You are a pharma R&D assistant. Assist with research based on local documents."
create_workspace "Regulatory Confidential" "regulatory-confidential" "You are a regulatory assistant. Focus on compliance documents."
create_workspace "General Research" "general-research" "You are a pharma industry research assistant. Cite sources clearly."

# ── Auto-Ingest ────────────────────────────────────────────────
DOCS_SOURCE="/Users/venkateshwarlu/Documents/knowledge-base"
if [[ -d "$DOCS_SOURCE" ]]; then
  info "Ingesting documents into QA Confidential..."
  bash "$SCRIPT_DIR/ingest_docs.sh" "qa-confidential" "$DOCS_SOURCE"
fi

echo -e "\n${GREEN}Setup Complete! Helix AI is ready with all workspaces.${NC}"
