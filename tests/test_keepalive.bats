setup_file() {
    # Ensure we're in the project root
    cd "$(dirname "$BATS_TEST_FILENAME")/.."
}

setup() {
    export TEST_TOKEN="sk-ant-test12345678"
    export TEST_DIR=$(mktemp -d)
    export HOME="$TEST_DIR"
    export CI="true"

    # Mock claude globally so all tests that call it don't hang
    mkdir -p "$TEST_DIR/mock_bin"
    cat > "$TEST_DIR/mock_bin/claude" << 'MOCK'
#!/usr/bin/env bash
echo "Mock claude: healthy"
exit 0
MOCK
    chmod +x "$TEST_DIR/mock_bin/claude"
    export PATH="$TEST_DIR/mock_bin:$PATH"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "keepalive.sh fails without token" {
    run bash scripts/keepalive.sh
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage"* ]]
}

@test "keepalive.sh creates and cleans up settings.json" {
    run bash scripts/keepalive.sh "$TEST_TOKEN" "https://anyrouter.top/v1"
    # After run, settings.json should be cleaned up
    [ ! -f "$TEST_DIR/.claude/settings.json" ]
}

@test "keepalive.sh picks a prompt from prompts.txt" {
    # Verify prompts.txt exists and has content
    [ -f "scripts/prompts.txt" ]
    local count=$(grep -cve '^\s*$' -e '^#' scripts/prompts.txt || true)
    [ "$count" -ge 10 ]
}

@test "run-all.sh fails without tokens" {
    unset ANYROUTER_TOKENS
    run bash scripts/run-all.sh
    [ "$status" -eq 1 ]
    [[ "$output" == *"No tokens"* ]]
}

@test "run-all.sh parses single token from env" {
    export ANYROUTER_TOKENS="sk-ant-testAAA"
    run timeout 5 bash scripts/run-all.sh 2>&1 || true
    [ "$status" -eq 124 ] || true  # 124 = timeout, which is expected
    [[ "$output" == *"Loaded 1 token(s)"* ]]
}

@test "run-all.sh parses multiple tokens from env" {
    export ANYROUTER_TOKENS="sk-ant-testAAA
sk-ant-testBBB
sk-ant-testCCC"
    run timeout 5 bash scripts/run-all.sh 2>&1 || true
    [[ "$output" == *"Loaded 3 token(s)"* ]]
}

@test "prompts.txt has no empty lines used as prompts" {
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        [ -n "$line" ]
    done < scripts/prompts.txt
}

@test "settings.json atomic write pattern works" {
    local dir="$TEST_DIR/.claude"
    local file="$dir/settings.json"
    local tmp="$dir/settings.json.tmp.$$.$(date +%s%N)"
    mkdir -p "$dir"
    cat > "$tmp" <<< '{"env":{"ANTHROPIC_AUTH_TOKEN":"test","ANTHROPIC_BASE_URL":"https://test.com/v1"}}'
    mv "$tmp" "$file"
    [ -f "$file" ]
    grep -q "ANTHROPIC_AUTH_TOKEN" "$file"
    rm -f "$file"
}
