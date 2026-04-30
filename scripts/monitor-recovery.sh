#!/usr/bin/env bash
# monitor-recovery.sh - Poll all tokens every 30min, send round summary, early-exit when fast
# Designed for manual-trigger GitHub Actions workflow (6h container).
# Reuses keepalive.sh for health checks.
# Usage: monitor-recovery.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Configuration ---
BASE_URL="${BASE_URL:-https://a-ocnfniawgw.cn-shanghai.fcapp.run}"
MODEL="${MODEL:-opus[1m]}"
POLL_INTERVAL="${POLL_INTERVAL:-1800}"          # 30 minutes between rounds
MAX_DURATION_SEC="${MAX_DURATION_SEC:-21500}"   # ~5h58m (just under 6h)
QQ_EMAIL="${QQ_EMAIL:-}"
QQ_SMTP_AUTH_CODE="${QQ_SMTP_AUTH_CODE:-}"

# Beijing time helper
beijing_ts() {
    TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S CST'
}

# --- Load tokens (reused from run-all.sh) ---
load_tokens() {
    if [ -n "${ANYROUTER_TOKENS:-}" ]; then
        echo "$ANYROUTER_TOKENS"
        return
    fi
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

# --- Send email alert (reused from run-all.sh) ---
send_email() {
    local subject="$1" body="$2"
    if [ -z "$QQ_EMAIL" ] || [ -z "$QQ_SMTP_AUTH_CODE" ]; then
        echo "  (Skipping email: QQ_EMAIL or QQ_SMTP_AUTH_CODE not configured)"
        return 0
    fi
    if ! curl --version 2>/dev/null | grep -qi "smtp"; then
        echo "  Email failed: curl was not compiled with SMTP support"
        return 1
    fi
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
    curl -sS --ssl-reqd --fail-with-body \
        --url "smtps://smtp.qq.com:465" \
        --user "$QQ_EMAIL:$QQ_SMTP_AUTH_CODE" \
        --login-options "AUTH=LOGIN" \
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
        return 1
    fi
}

# --- Main ---
TOKENS_DATA=$(load_tokens)
mapfile -t TOKENS <<< "$TOKENS_DATA"
if [ ${#TOKENS[@]} -eq 0 ]; then
    echo "ERROR: No tokens loaded. Exiting." >&2
    exit 1
fi
echo "Loaded ${#TOKENS[@]} token(s)"
echo "Base URL: $BASE_URL"
echo "Model: $MODEL"
echo "Poll interval: ${POLL_INTERVAL}s"
echo ""

declare -A PREV_STATES   # "success" or "failed"

START_TIME=$(date +%s)
ROUND=1

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    REMAINING=$((MAX_DURATION_SEC - ELAPSED))

    if [ "$REMAINING" -le 0 ]; then
        echo "=== Time limit reached. Exiting. ==="
        break
    fi

    echo "============================================="
    echo " Round $ROUND  |  $(beijing_ts)"
    echo " Elapsed: ${ELAPSED}s  |  Remaining: ~${REMAINING}s"
    echo "============================================="

    # Per-round tracking
    TOKEN_RESULTS=()
    TOKEN_TIMES=()       # response time (seconds), 0 for failed
    ALL_SUCCESS=true
    MAX_TIME=0

    for i in "${!TOKENS[@]}"; do
        token="${TOKENS[$i]}"
        token_preview="${token:0:5}..."

        # Check remaining time before each token
        NOW=$(date +%s)
        if [ $((NOW - START_TIME)) -ge "$MAX_DURATION_SEC" ]; then
            echo "Time limit reached mid-round. Breaking."
            break
        fi

        echo "[$((i+1))/${#TOKENS[@]}] Testing $token_preview ..."

        CHECK_START=$(date +%s)
        if result=$(bash "$SCRIPT_DIR/keepalive.sh" "$token" "$BASE_URL" "$MODEL" 2>&1); then
            CHECK_END=$(date +%s)
            response_time=$((CHECK_END - CHECK_START))
            echo "$result"
            echo "  ✓ $token_preview active (${response_time}s)"

            TOKEN_RESULTS+=("✓ $token_preview (${response_time}s)")
            TOKEN_TIMES+=("$response_time")
            PREV_STATES[$token]="success"
            [ "$response_time" -gt "$MAX_TIME" ] && MAX_TIME=$response_time
        else
            echo "$result"
            echo "  ✗ $token_preview failed"
            TOKEN_RESULTS+=("✗ $token_preview failed")
            TOKEN_TIMES+=("0")
            PREV_STATES[$token]="failed"
            ALL_SUCCESS=false
        fi

        # Brief pause between tokens
        if [ "$i" -lt "$(( ${#TOKENS[@]} - 1 ))" ]; then
            JITTER=$(( 30 + (RANDOM % 21) - 10 ))
            [ "$JITTER" -lt 10 ] && JITTER=10
            echo "  Waiting ${JITTER}s ..."
            sleep "$JITTER"
        fi
    done

    # --- End of round: build summary ---
    ROUND_SUMMARY=""
    SUCCESS_COUNT=0
    FAIL_COUNT=0

    for i in "${!TOKENS[@]}"; do
        ROUND_SUMMARY+="  ${TOKEN_RESULTS[$i]}"$'\n'
        if [ "${PREV_STATES[${TOKENS[$i]}]}" = "success" ]; then
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    done

    ROUND_SUMMARY+=$'\n'"Summary: $SUCCESS_COUNT success, $FAIL_COUNT failed"

    echo ""
    echo "--- Round $ROUND summary: $SUCCESS_COUNT success, $FAIL_COUNT failed ---"
    echo ""

    # --- Decide action ---
    if [ "$ALL_SUCCESS" = true ] && [ "$MAX_TIME" -lt 30 ]; then
        # All healthy and fast — early exit
        echo ">>> All tokens healthy (max response ${MAX_TIME}s < 30s). Sending '快用' email and exiting."
        send_email \
            "快用！现在状态超好，不接着测了" \
            "Anyrouter 已全面恢复，响应极快，建议立即使用！

$(beijing_ts)

各 token 状态：
$ROUND_SUMMARY

最大响应时间: ${MAX_TIME}s
所有 token 均正常工作且响应时间 < 30 秒，状态超好！检测到此结束。"
        echo ""
        echo "=== Early exit: all healthy and fast. ==="
        break
    fi

    # Send normal round summary
    if [ "$ALL_SUCCESS" = true ]; then
        send_email \
            "Anyrouter 监控报告 - 第${ROUND}轮（全部可用）" \
            "轮次: 第 ${ROUND} 轮
检测时间: $(beijing_ts)

各 token 状态：
$ROUND_SUMMARY

最大响应时间: ${MAX_TIME}s
全部可用，但响应时间未达到 30 秒以内的超优标准，继续监控。"
    else
        send_email \
            "Anyrouter 监控报告 - 第${ROUND}轮（${FAIL_COUNT}个不可用）" \
            "轮次: 第 ${ROUND} 轮
检测时间: $(beijing_ts)

各 token 状态：
$ROUND_SUMMARY

仍有 ${FAIL_COUNT} 个 token 不可用，继续监控。"
    fi

    ROUND=$((ROUND + 1))

    # --- Sleep until next poll ---
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    REMAINING=$((MAX_DURATION_SEC - ELAPSED))

    if [ "$REMAINING" -gt "$POLL_INTERVAL" ]; then
        echo ""
        echo "--- Next round in ${POLL_INTERVAL}s ($((POLL_INTERVAL / 60)) min) ---"
        sleep "$POLL_INTERVAL"
    elif [ "$REMAINING" -gt 60 ]; then
        echo ""
        echo "--- Time nearly up, sleeping final ${REMAINING}s ---"
        sleep "$REMAINING"
    else
        echo "Time limit reached."
    fi
done

echo ""
echo "========================================"
echo " Monitor completed."
echo " Total rounds: $ROUND"
echo "========================================"
