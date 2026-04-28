#!/usr/bin/env bash
# keepalive.sh - Health-check a single Anyrouter token using Claude CLI
# Usage: keepalive.sh <token> [base_url] [model]
set -euo pipefail

TOKEN="${1:?Usage: $0 <token> [base_url] [model]}"
BASE_URL="${2:-https://anyrouter.top/v1}"
MODEL="${3:-haiku}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPTS_FILE="$SCRIPT_DIR/prompts.txt"

# Pick a random non-empty, non-comment prompt line
pick_prompt() {
    if [ -f "$PROMPTS_FILE" ]; then
        local prompts=()
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            prompts+=("$line")
        done < "$PROMPTS_FILE"
        if [ ${#prompts[@]} -gt 0 ]; then
            echo "${prompts[$((RANDOM % ${#prompts[@]}))]}"
            return
        fi
    fi
    echo "Write a one-line Python function to check if a string is a palindrome."
}

PROMPT=$(pick_prompt)

# --- Atomically write settings.json ---
SETTINGS_DIR="$HOME/.claude"
SETTINGS_FILE="$SETTINGS_DIR/settings.json"
TMP_FILE="$SETTINGS_DIR/settings.json.tmp.$$.$(date +%s%N)"

mkdir -p "$SETTINGS_DIR"

cat > "$TMP_FILE" << EOF
{
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "$TOKEN",
    "ANTHROPIC_BASE_URL": "$BASE_URL"
  }
}
EOF
mv "$TMP_FILE" "$SETTINGS_FILE"

# --- Run health check ---
# In CI (GitHub Actions), bypass permissions since there's no interactive user.
# Locally with a terminal, the user can approve interactively.
EXTRA_FLAGS=()
if [ "${CI:-}" = "true" ]; then
    EXTRA_FLAGS+=(--dangerously-skip-permissions)
fi

OUTPUT=$(claude -p "$PROMPT" --print --model "$MODEL" --bare "${EXTRA_FLAGS[@]}" 2>&1) || true

# --- Clean up ---
rm -f "$SETTINGS_FILE"

# --- Evaluate result ---
if [ -n "$OUTPUT" ]; then
    echo "SUCCESS"
    exit 0
else
    echo "FAILED (empty response)"
    exit 1
fi
