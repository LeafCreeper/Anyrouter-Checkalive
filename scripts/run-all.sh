#!/usr/bin/env bash
# run-all.sh - Batch health-check runner with internal 50-minute loop
# Designed for a single GitHub Actions container: runs rounds until ~5h58m time limit.
# Supports local usage via .env file or ANYROUTER_TOKENS env var.
# Usage: run-all.sh [--once]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Parse args ---
ONCE=false
if [ "${1:-}" = "--once" ]; then
    ONCE=true
fi

# --- Configuration ---
BASE_URL="${BASE_URL:-https://a-ocnfniawgw.cn-shanghai.fcapp.run}"
MODEL="${MODEL:-opus[1m]}"
SLEEP_BETWEEN_TOKENS="${SLEEP_BETWEEN_TOKENS:-30}"         # seconds between tokens
SLEEP_BETWEEN_ROUNDS="${SLEEP_BETWEEN_ROUNDS:-3000}"       # ~50 minutes between rounds
MAX_DURATION_SEC="${MAX_DURATION_SEC:-21500}"               # ~5h58m (just under 6h limit)
QQ_EMAIL="${QQ_EMAIL:-}"
QQ_SMTP_AUTH_CODE="${QQ_SMTP_AUTH_CODE:-}"

# --- Load tokens ---
load_tokens() {
    # 1) Try env var
    if [ -n "${ANYROUTER_TOKENS:-}" ]; then
        echo "$ANYROUTER_TOKENS"
        return
    fi
    # 2) Try .env file
    if [ -f "$SCRIPT_DIR/../.env" ]; then
        local val
        val=$(grep -E '^ANYROUTER_TOKENS=' "$SCRIPT_DIR/../.env" 2>/dev/null | sed 's/^ANYROUTER_TOKENS=//' | sed 's/^"//;s/"$//' || true)
        if [ -n "$val" ]; then
            echo "$val" | tr ',' '\n'
            return
        fi
    fi
    echo "ERROR: No tokens found. Set ANYROUTER_TOKENS env var or create .env file." >&2
    exit 1
}

# --- Email report ---
send_email() {
    local subject="$1" body="$2"
    if [ -z "$QQ_EMAIL" ] || [ -z "$QQ_SMTP_AUTH_CODE" ]; then
        echo "  (Skipping email: QQ_EMAIL or QQ_SMTP_AUTH_CODE not configured)"
        return 0
    fi

    # Verify curl supports SMTP (GitHub Actions curl usually does)
    if ! curl --version 2>/dev/null | grep -qi "smtp"; then
        echo "  Email failed: curl was not compiled with SMTP support"
        return 1
    fi

    # Write email to temp file (more reliable than here-string + stdin)
    local mail_file
    mail_file=$(mktemp)
    cat > "$mail_file" <<EOF
From: $QQ_EMAIL
To: $QQ_EMAIL
Subject: $subject
Content-Type: text/plain; charset=utf-8

$body
EOF

    echo "  Sending email via QQ SMTP to $QQ_EMAIL ..."

    local curl_exit=0
    # -S: show errors (even with -s), --fail-with-body: treat HTTP/SMTP errors as failures
    curl -sS --ssl-reqd --fail-with-body \
        --url "smtps://smtp.qq.com:465" \
        --user "$QQ_EMAIL:$QQ_SMTP_AUTH_CODE" \
        --mail-from "$QQ_EMAIL" \
        --mail-rcpt "$QQ_EMAIL" \
        --upload-file "$mail_file" \
        || curl_exit=$?

    rm -f "$mail_file"

    if [ "$curl_exit" -eq 0 ]; then
        echo "  Email sent to $QQ_EMAIL"
        return 0
    else
        echo "  Email FAILED (curl exit: $curl_exit)"
        echo "  Common causes:"
        echo "    - QQ_SMTP_AUTH_CODE is wrong (it is NOT your QQ password)"
        echo "    - Generate it at: QQ Mail -> Settings -> Account -> POP3/IMAP/SMTP"
        echo "    - Network/firewall blocking smtps://smtp.qq.com:465"
        return 1
    fi
}

# --- Load tokens ---
TOKENS_DATA=$(load_tokens)
mapfile -t TOKENS <<< "$TOKENS_DATA"
if [ ${#TOKENS[@]} -eq 0 ]; then
    echo "ERROR: No tokens loaded. Exiting." >&2
    exit 1
fi
echo "Loaded ${#TOKENS[@]} token(s)"
echo "Base URL: $BASE_URL"
echo "Model: $MODEL"
echo ""

START_TIME=$(date +%s)
ROUND=1
ALL_RESULTS=""
HAS_SENT_REPORT=false

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    REMAINING=$((MAX_DURATION_SEC - ELAPSED))

    if [ "$REMAINING" -le 0 ]; then
        echo "=== Time limit reached. Exiting. ==="
        break
    fi

    echo "========================================"
    echo " Round $ROUND  |  $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo " Elapsed: ${ELAPSED}s  |  Remaining: ~${REMAINING}s"
    echo "========================================"

    ROUND_RESULTS=""
    ROUND_SUCCESS=0
    ROUND_FAIL=0

    for i in "${!TOKENS[@]}"; do
        token="${TOKENS[$i]}"
        token_preview="${token:0:12}..."

        # Check remaining time before each token
        NOW=$(date +%s)
        if [ $((NOW - START_TIME)) -ge "$MAX_DURATION_SEC" ]; then
            echo "Time limit reached mid-round. Breaking."
            break
        fi

        echo "[$((i+1))/${#TOKENS[@]}] Testing $token_preview ..."

        if result=$(bash "$SCRIPT_DIR/keepalive.sh" "$token" "$BASE_URL" "$MODEL" 2>&1); then
            echo "$result"
            echo "  ✓ $token_preview is active"
            ROUND_RESULTS+="  ✓ $token_preview is active"$'\n'
            ROUND_SUCCESS=$((ROUND_SUCCESS + 1))
        else
            echo "$result"
            echo "  ✗ $token_preview failed"
            ROUND_RESULTS+="  ✗ $token_preview failed"$'\n'
            ROUND_FAIL=$((ROUND_FAIL + 1))
        fi

        # Add random jitter to interval (20-40s instead of fixed 30s)
        if [ "$i" -lt "$(( ${#TOKENS[@]} - 1 ))" ]; then
            JITTER=$(( SLEEP_BETWEEN_TOKENS + (RANDOM % 21) - 10 ))
            [ "$JITTER" -lt 10 ] && JITTER=10
            echo "  Waiting ${JITTER}s ..."
            sleep "$JITTER"
        fi
    done

    # Accumulate round results
    ALL_RESULTS+="--- Round $ROUND ($(date '+%Y-%m-%d %H:%M')) ---"$'\n'
    ALL_RESULTS+="$ROUND_RESULTS"$'\n'
    ALL_RESULTS+="Round $ROUND summary: $ROUND_SUCCESS success, $ROUND_FAIL failed"$'\n'$'\n'

    echo ""
    echo "--- Round $ROUND summary: $ROUND_SUCCESS success, $ROUND_FAIL failed ---"

    ROUND=$((ROUND + 1))

    # If --once mode, exit after the first round
    if [ "$ONCE" = true ]; then
        echo ""
        echo "=== --once mode: single round complete. Exiting. ==="
        break
    fi

    # Check if we should send final report (last round before time limit)
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    REMAINING=$((MAX_DURATION_SEC - ELAPSED))

    if [ "$REMAINING" -le "$((SLEEP_BETWEEN_ROUNDS + 120))" ] && [ "$HAS_SENT_REPORT" = false ]; then
        HAS_SENT_REPORT=true
        echo ""
        echo "=== Sending final report ==="
        send_email "Anyrouter Keepalive Report ($(date '+%Y-%m-%d'))" "$ALL_RESULTS" || true
        echo ""

        # Do one more round if time allows, but signal it's the last
        if [ "$REMAINING" -le 0 ]; then
            break
        fi
    fi

    # Sleep until next round (if we have time)
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    REMAINING=$((MAX_DURATION_SEC - ELAPSED))

    if [ "$REMAINING" -gt "$SLEEP_BETWEEN_ROUNDS" ]; then
        echo "Sleeping ${SLEEP_BETWEEN_ROUNDS}s until round $ROUND ..."
        sleep "$SLEEP_BETWEEN_ROUNDS"
    elif [ "$REMAINING" -gt 60 ]; then
        echo "Sleeping ${REMAINING}s (remaining time) ..."
        sleep "$REMAINING"
    else
        echo "Time limit reached."
    fi
done

# Final summary
echo ""
echo "========================================"
echo " All rounds complete."
echo "$ALL_RESULTS"
echo "========================================"

# Send one final report if we never sent one (e.g. very short run)
if [ "$HAS_SENT_REPORT" = false ]; then
    send_email "Anyrouter Keepalive Report ($(date '+%Y-%m-%d'))" "$ALL_RESULTS" || true
fi

echo "Done."
