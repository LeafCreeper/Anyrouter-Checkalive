#!/usr/bin/env bash
# keepalive.sh - Health-check a single Anyrouter token using Claude CLI
# Usage: keepalive.sh <token> [base_url] [model]
# Prints ALL output (including errors, retries, stack traces) for diagnostics.
set -euo pipefail

TOKEN="${1:?Usage: $0 <token> [base_url] [model]}"
BASE_URL="${2:-https://a-ocnfniawgw.cn-shanghai.fcapp.run}"
MODEL="${3:-opus[1m]}"

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
EXTRA_FLAGS=()
if [ "${CI:-}" = "true" ]; then
    EXTRA_FLAGS+=(--dangerously-skip-permissions)
fi

# Run claude with timeout to prevent infinite retry hangs.
# Capture both stdout and stderr into a temp file, plus record exit code.
OUTPUT_FILE=$(mktemp)
EXIT_CODE=0

# 120s timeout: if claude enters infinite retry, kill it
timeout 120 claude -p "$PROMPT" --print --model "$MODEL" --bare "${EXTRA_FLAGS[@]}" > "$OUTPUT_FILE" 2>&1 || EXIT_CODE=$?

# --- Print ALL output for diagnostics ---
echo "  Prompt: ${PROMPT:0:60}..."
echo "  --- Claude output (exit_code=$EXIT_CODE) ---"
cat "$OUTPUT_FILE" | sed 's/^/    /'
echo "  --- End output ---"

# --- Evaluate result ---
OUTPUT_CONTENT=$(cat "$OUTPUT_FILE" 2>/dev/null || true)

# Clean up
rm -f "$OUTPUT_FILE" "$SETTINGS_FILE"

# 1. Non-zero exit code is a clear failure (includes timeout exit 124)
if [ "$EXIT_CODE" -ne 0 ]; then
    echo "  FAILED (non-zero exit: $EXIT_CODE)"
    exit 1
fi

# 2. Empty response is a failure
if [ -z "$OUTPUT_CONTENT" ]; then
    echo "  FAILED (empty response)"
    exit 1
fi

# 3. Check for common API error indicators that might appear even with exit 0
ERROR_PATTERNS="rate limit|authentication failed|unauthorized|invalid api key|connection refused|timeout|429|401|403|500|service unavailable|retry after|too many requests"
if echo "$OUTPUT_CONTENT" | grep -qiE "$ERROR_PATTERNS"; then
    echo "  FAILED (API error detected in output)"
    exit 1
fi

echo "  SUCCESS"
exit 0
