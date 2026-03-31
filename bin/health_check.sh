#!/usr/bin/env bash
# ============================================================
# PharmaCX POC — Source Attribution Test
# Verifies the source tracker middleware appends attribution
# ============================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

ok()  { echo -e "${GREEN}  ✔  $1${NC}"; }
info(){ echo -e "${BLUE}  →  $1${NC}"; }
warn(){ echo -e "${YELLOW}  ⚠  $1${NC}"; }
err() { echo -e "${RED}  ✖  $1${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
[[ -f "$PROJECT_DIR/config/.env" ]] && { set -a; source "$PROJECT_DIR/config/.env"; set +a; }
AUTH_TOKEN="${AUTH_TOKEN:-pharmacx-poc-secret-change-me}"

SOURCE_TRACKER="http://localhost:5055"
ANYTHINGLLM="http://localhost:3002"
OLLAMA="http://localhost:11434"

echo ""
echo -e "${CYAN}════════════════════════════════════════${NC}"
echo -e "${CYAN}  PharmaCX POC — System Health Check${NC}"
echo -e "${CYAN}════════════════════════════════════════${NC}"
echo ""

PASS=0; FAIL=0

check() {
  local name=$1; local url=$2; local expect=${3:-}
  RESP=$(curl -s --max-time 5 "$url" 2>/dev/null || echo "")
  if [[ -n "$RESP" ]] && { [[ -z "$expect" ]] || echo "$RESP" | grep -q "$expect"; }; then
    ok "$name"
    ((PASS++)) || true
  else
    err "$name — not responding or unexpected response"
    ((FAIL++)) || true
  fi
}

# Service health
check "Ollama (native)"    "$OLLAMA/api/tags"        "models"
check "Helix AI"            "$ANYTHINGLLM/api/health"  "online"
check "Source Tracker"     "$SOURCE_TRACKER/health"   "ok"
check "LiteLLM"            "http://localhost:8000/health" "healthy"

echo ""
echo -e "${CYAN}── Model Availability ──────────────────${NC}"

check_model() {
  local model=$1
  RESP=$(curl -s "http://localhost:11434/api/tags" 2>/dev/null || echo "")
  if echo "$RESP" | grep -q "${model%%:*}"; then
    ok "Ollama model: $model"
    ((PASS++)) || true
  else
    warn "Ollama model $model not found — pull with: ollama pull $model"
    ((FAIL++)) || true
  fi
}

check_model "llama3.2:3b"
check_model "phi3:mini"
check_model "nomic-embed-text"

echo ""
echo -e "${CYAN}── Source Attribution Test ─────────────${NC}"

info "Sending test query via Source Tracker..."

TEST_RESP=$(curl -s --max-time 60 -X POST \
  "$SOURCE_TRACKER/api/v1/workspace/general-research/chat" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "message": "What is a drug master file in pharma regulatory submissions?",
    "mode": "chat"
  }' 2>/dev/null || echo "{}")

if echo "$TEST_RESP" | grep -q "Source Attribution"; then
  ok "Source attribution block present in response ✓"
  ((PASS++)) || true

  if echo "$TEST_RESP" | grep -q "Local LLM"; then
    ok "Model source identified: Local LLM (Ollama)"
    ((PASS++)) || true
  fi

  if echo "$TEST_RESP" | grep -q "Data class"; then
    ok "Data classification label present"
    ((PASS++)) || true
  fi

  echo ""
  echo -e "${BLUE}Sample attribution from response:${NC}"
  echo "$TEST_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
text = d.get('textResponse', '')
idx = text.find('---')
if idx >= 0:
    print(text[idx:idx+600])
else:
    print('Attribution block not found in expected location')
" 2>/dev/null || warn "Could not parse response JSON"

else
  warn "Source attribution not found in response"
  warn "This may be expected if Helix AI is still initializing"
  ((FAIL++)) || true
fi

echo ""
echo -e "${CYAN}── Summary ─────────────────────────────${NC}"
echo -e "  ${GREEN}Passed: $PASS${NC}"
if [[ $FAIL -gt 0 ]]; then
  echo -e "  ${RED}Failed: $FAIL${NC}"
else
  echo -e "  ${GREEN}Failed: 0${NC}"
fi
echo ""

if [[ $FAIL -eq 0 ]]; then
  echo -e "${GREEN}All checks passed. PharmaCX POC is operational.${NC}"
  echo -e "Open ${CYAN}http://localhost:3002${NC} to start using Helix AI."
else
  echo -e "${YELLOW}Some checks failed. Check docker logs:${NC}"
  echo -e "  ${BLUE}cd docker && docker compose logs -f${NC}"
fi
echo ""
