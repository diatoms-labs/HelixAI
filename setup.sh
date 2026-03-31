#!/usr/bin/env bash
# ============================================================
# Helix AI — Streamlined Master Setup
# Usage: ./setup.sh [ABSOLUTE_DOC_PATH] [WORKSPACE_SLUG]
# Example: ./setup.sh /Users/venkateshwarlu/Documents/RD_Docs rd-internal
# ============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
banner() { echo -e "\n${CYAN}══════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}══════════════════════════════════════════════${NC}\n"; }
ok()  { echo -e "${GREEN}  ✔  $1${NC}"; }
info(){ echo -e "${BLUE}  →  $1${NC}"; }
warn(){ echo -e "${YELLOW}  ⚠  $1${NC}"; }
err() { echo -e "${RED}  ✖  $1${NC}"; exit 1; }

DOC_PATH="${1:-}"
WORKSPACE_SLUG="${2:-qa-confidential}"
MODEL_FILE="/tmp/helix-ai-modelfile"

# ── 1. Local Ollama & Custom Model ───────────────────────────────
banner "Ollama & Custom Model Setup"

if ! command -v ollama &>/dev/null; then
  info "Ollama not found. Downloading installer..."
  curl -L https://ollama.com/download/Ollama-darwin.zip -o /tmp/ollama.zip
  unzip -o /tmp/ollama.zip -d /Applications/
  ok "Ollama installed to /Applications"
fi

if ! pgrep -x "ollama" &>/dev/null; then
  info "Starting Ollama..."
  open -a Ollama
  sleep 5
fi

# Register helix-ai model
if [[ -f "core/system_prompt.txt" ]]; then
  info "Pulling base models (qwen2.5:1.5b, nomic-embed-text, phi3:mini)..."
  ollama pull qwen2.5:1.5b &>/dev/null
  ollama pull nomic-embed-text &>/dev/null
  ollama pull phi3:mini &>/dev/null
  
  info "Building custom 'helix-ai' model from file system..."
  cat > "$MODEL_FILE" << EOF
FROM qwen2.5:1.5b

PARAMETER temperature 0.3
PARAMETER top_p 0.8
PARAMETER num_predict 1024
PARAMETER repeat_penalty 1.1
PARAMETER num_ctx 8192

SYSTEM """$(cat core/system_prompt.txt)"""
EOF

  ollama create helix-ai -f "$MODEL_FILE" &>/dev/null
  rm -f "$MODEL_FILE"
  ok "Model 'helix-ai' is ready"

  info "Warming up 'helix-ai'..."
  curl -sf -X POST http://localhost:11434/api/generate \
    -d '{"model":"helix-ai","prompt":"Check for GMP compliance.","stream":false,"options":{"num_predict":16}}' \
    >/dev/null 2>&1 || true
  ok "Warmup complete"
else
  warn "System prompt missing. Skipping registration."
fi

# ── 2. Docker Stack Setup ─────────────────────────────────────────
banner "Starting Helix AI Stack"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"
docker compose up -d --remove-orphans
ok "Containers started"

# Wait for UI
info "Waiting for Helix AI UI (http://localhost:3002)..."
for i in {1..30}; do
  if curl -s http://localhost:3002/api/health &>/dev/null; then
    ok "Helix AI is online"
    break
  fi
  echo -n "."
  sleep 3
done

# ── 3. Workspace Configuration ────────────────────────────────────
banner "Configuring Workspaces"
bash "$PROJECT_DIR/bin/setup_workspaces.sh"

# ── 4. Absolute Document Ingestion ────────────────────────────────
if [[ -n "$DOC_PATH" ]]; then
  banner "Ingesting Documents from $DOC_PATH"
  if [[ -d "$DOC_PATH" ]]; then
    bash "$PROJECT_DIR/bin/ingest_docs.sh" "$WORKSPACE_SLUG" "$DOC_PATH"
  else
    err "Document path $DOC_PATH does not exist or is not a directory."
  fi
else
  info "No document path provided. Skipping ingestion. (Usage: ./setup.sh [PATH] [WORKSPACE])"
fi

banner "Setup Complete — Helix AI Ready"
echo -e "  Main UI     :  http://localhost:3002"
echo -e "  Middleware  :  http://localhost:5055"
echo ""
echo -e "  ${YELLOW}Use the 'helix-ai' model for compliant document generation.${NC}"
echo ""
