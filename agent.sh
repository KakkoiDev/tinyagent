#!/usr/bin/env bash
set -uo pipefail

# ── Config ──────────────────────────────────────────────
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
MODEL="${MODEL:-$SCRIPT_DIR/models/qwen2.5-coder-0.5b-instruct-q4_k_m.gguf}"
LLAMA_SERVER="${LLAMA_SERVER:-$SCRIPT_DIR/llama.cpp/build/bin/llama-server}"
PORT="${PORT:-8085}"
MAX_PREDICT="${MAX_PREDICT:-256}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
GRAMMAR_DIR="${GRAMMAR_DIR:-$SCRIPT_DIR/grammars}"
PROMPT_DIR="${PROMPT_DIR:-$SCRIPT_DIR/prompts}"
BLOCKLIST="${BLOCKLIST:-$SCRIPT_DIR/blocklist.txt}"
CACHE_DIR="${CACHE_DIR:-$SCRIPT_DIR/.cache}"
CACHE_TTL="${CACHE_TTL:-600}"  # 10 minutes

# ── Cache helpers ──────────────────────────────────────
_cache_key() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | md5sum | cut -d' ' -f1
}

cache_get() {
    local key
    key="$(_cache_key "$1")"
    local file="$CACHE_DIR/$key"
    [ -f "$file" ] || return 1
    local age
    age=$(( $(date +%s) - $(stat -c%Y "$file" 2>/dev/null || stat -f%m "$file" 2>/dev/null) ))
    [ "$age" -gt "$CACHE_TTL" ] && { rm -f "$file"; return 1; }
    cat "$file"
}

cache_set() {
    local key
    key="$(_cache_key "$1")"
    mkdir -p "$CACHE_DIR"
    printf '%s' "$2" > "$CACHE_DIR/$key"
}

# ── Platform helpers ────────────────────────────────────
_ncpus() {
    if command -v nproc > /dev/null 2>&1; then
        nproc
    elif sysctl -n hw.ncpu > /dev/null 2>&1; then
        sysctl -n hw.ncpu
    else
        echo 2
    fi
}

_ms_timestamp() {
    # macOS date lacks %N; fall back to seconds
    date +%s%3N 2>/dev/null || echo "$(date +%s)000"
}

# ── Session state ───────────────────────────────────────
SESSION_ID="${SESSION_ID:-$(date +%Y%m%d_%H%M%S)_$$}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/$SESSION_ID.jsonl}"
LAST_RESULT="${LAST_RESULT:-}"
SERVER_PID="${SERVER_PID:-}"

# ── Colors ──────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Logging ─────────────────────────────────────────────
log_event() {
    local event="$1"
    shift
    local data="$*"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","event":"%s","data":%s}\n' "$ts" "$event" "$data" >> "$LOG_FILE"
}

# ── Server lifecycle ────────────────────────────────────
start_server() {
    if [ ! -f "$LLAMA_SERVER" ]; then
        echo -e "${RED}Error: llama-server not found at $LLAMA_SERVER${RESET}"
        echo "Run setup.sh first."
        exit 1
    fi
    if [ ! -f "$MODEL" ]; then
        echo -e "${RED}Error: Model not found at $MODEL${RESET}"
        echo "Run setup.sh first."
        exit 1
    fi

    echo -e "${DIM}Starting server...${RESET}"
    "$LLAMA_SERVER" \
        -m "$MODEL" \
        --port "$PORT" \
        --ctx-size 2048 \
        --threads "$(_ncpus)" \
        --log-disable \
        > /dev/null 2>&1 &
    SERVER_PID=$!

    # Wait for health
    local tries=0
    while [ $tries -lt 30 ]; do
        if curl -sf "http://localhost:$PORT/health" > /dev/null 2>&1; then
            echo -e "${GREEN}Server ready (pid $SERVER_PID)${RESET}"
            log_event "server_start" "{\"pid\":$SERVER_PID,\"port\":$PORT}"
            return 0
        fi
        sleep 1
        tries=$((tries + 1))
    done

    echo -e "${RED}Server failed to start after 30s${RESET}"
    kill "$SERVER_PID" 2>/dev/null
    exit 1
}

stop_server() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null
        wait "$SERVER_PID" 2>/dev/null
        log_event "session_end" "{\"session\":\"$SESSION_ID\"}"
    fi
}

trap stop_server EXIT

# ── Model call ──────────────────────────────────────────
call_model() {
    local prompt="$1"
    local grammar_file="$2"
    local grammar
    grammar="$(cat "$grammar_file")"

    local start_ms
    start_ms="$(_ms_timestamp)"

    local payload
    payload="$(jq -n \
        --arg prompt "$prompt" \
        --arg grammar "$grammar" \
        --argjson n_predict "$MAX_PREDICT" \
        '{
            prompt: $prompt,
            grammar: $grammar,
            n_predict: $n_predict,
            temperature: 0,
            stop: ["</s>", "<|endoftext|>", "<|im_end|>"],
            cache_prompt: true
        }'
    )"

    local response
    response="$(curl -sf "http://localhost:$PORT/completion" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)"

    local end_ms
    end_ms="$(_ms_timestamp)"
    local latency=$(( (end_ms - start_ms) ))

    local content
    content="$(echo "$response" | jq -r '.content // empty')"

    log_event "model_raw" "$(jq -n \
        --arg prompt "$prompt" \
        --arg output "$content" \
        --argjson latency_ms "$latency" \
        '{prompt: $prompt, output: $output, latency_ms: $latency_ms}'
    )"

    echo "$content"
}

# ── Prompt builders ─────────────────────────────────────
build_extract_prompt() {
    local request="$1"
    local last="$2"
    local template
    template="$(cat "$PROMPT_DIR/extract.txt")"
    template="${template//\$REQUEST/$request}"
    template="${template//\$LAST/$last}"
    echo "$template"
}

build_order_prompt() {
    local steps="$1"
    local template
    template="$(cat "$PROMPT_DIR/order.txt")"
    template="${template//\$STEPS/$steps}"
    echo "$template"
}

build_plan_prompt() {
    local request="$1"
    local last="$2"
    local template
    template="$(cat "$PROMPT_DIR/plan.txt")"
    template="${template//\$REQUEST/$request}"
    template="${template//\$LAST/$last}"
    echo "$template"
}


# ── Validation ──────────────────────────────────────────
validate_command() {
    local cmd="$1"
    if [ ! -f "$BLOCKLIST" ]; then
        return 0
    fi
    while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue
        if echo "$cmd" | grep -qE "$pattern"; then
            echo "$pattern"
            return 1
        fi
    done < "$BLOCKLIST"
    return 0
}

# ── Result summarizer ───────────────────────────────────
summarize_result() {
    local tool="$1"
    local raw="$2"
    local line_count
    line_count="$(echo "$raw" | wc -l)"

    case "$tool" in
        shell)
            if [ "$line_count" -gt 10 ]; then
                local first5
                first5="$(echo "$raw" | head -5)"
                echo "${line_count} lines, first 5: $first5"
            else
                echo "$raw"
            fi
            ;;
        read)
            local lang="text"
            # Simple language detection from extension
            case "$raw" in
                *".sh"*) lang="bash" ;;
                *".py"*) lang="python" ;;
                *".js"*) lang="javascript" ;;
                *".json"*) lang="json" ;;
            esac
            echo "${line_count}ln $lang"
            ;;
        write)
            echo "ok ${line_count}ln"
            ;;
        search)
            # Extract the answer sentence from {answer, url} JSON
            local answer
            answer="$(printf '%s' "$raw" | jq -r '.answer // empty' 2>/dev/null)" || answer=""
            if [ -n "$answer" ]; then
                echo "$answer"
            else
                echo "$raw" | head -5
            fi
            ;;
        *)
            echo "$raw" | head -5
            ;;
    esac
}

# ── Output formatter ────────────────────────────────────
format_output() {
    local raw="$1"
    # Detect search answer JSON {answer, url}
    if printf '%s' "$raw" | jq -e '.answer' > /dev/null 2>&1; then
        local answer url
        answer="$(printf '%s' "$raw" | jq -r '.answer')"
        url="$(printf '%s' "$raw" | jq -r '.url')"
        echo ""
        echo -e "  ${BOLD}$answer${RESET}"
        if [ -n "$url" ]; then
            printf "  \e]8;;%s\e\\%s\e]8;;\e\\\\\n" "$url" "$url"
        fi
        echo ""
        return
    fi
    # Default: dim text
    echo -e "${DIM}$raw${RESET}"
}

# ── Tool execution ──────────────────────────────────────
exec_tool() {
    local tool="$1"
    local args_json="$2"
    local output=""
    local exit_code=0

    case "$tool" in
        read)
            local path
            path="$(echo "$args_json" | jq -r '.path // empty')"
            if [ -z "$path" ]; then
                echo "err: no path specified"
                return 1
            fi
            if [ ! -f "$path" ]; then
                echo "err: file not found: $path"
                return 1
            fi
            output="$(cat "$path")"
            ;;
        write)
            local path content
            path="$(echo "$args_json" | jq -r '.path // empty')"
            content="$(echo "$args_json" | jq -r '.content // empty')"
            if [ -z "$path" ]; then
                echo "err: no path specified"
                return 1
            fi
            mkdir -p "$(dirname "$path")"
            printf '%s' "$content" > "$path"
            output="$(wc -l < "$path") lines written to $path"
            ;;
        shell)
            local cmd
            cmd="$(echo "$args_json" | jq -r '.cmd // empty')"
            if [ -z "$cmd" ]; then
                echo "err: no command specified"
                return 1
            fi
            output="$(eval "$cmd" 2>&1)" || exit_code=$?
            if [ $exit_code -ne 0 ]; then
                local first_line
                first_line="$(echo "$output" | head -1)"
                output="err($exit_code): $first_line"
            fi
            ;;
        search)
            local query
            query="$(printf '%s' "$args_json" | jq -r '.query // empty')"
            if [ -z "$query" ]; then
                echo "err: no query specified"
                return 1
            fi
            # Check cache first
            local cached
            if cached="$(cache_get "$query")"; then
                echo "$cached"
                return $exit_code
            fi
            # DDG search → keyword-score snippets → return best snippet + URL
            local results
            results="$(bash "$SCRIPT_DIR/search.sh" "$query" 3)" || true
            local result_count
            result_count="$(printf '%s' "$results" | jq 'length' 2>/dev/null)" || result_count=0
            if [ "$result_count" -eq 0 ]; then
                output='{"answer":"No results found.","url":""}'
                echo "$output"
                return $exit_code
            fi
            # Pick best snippet by query-word overlap (deterministic)
            local best_idx=0 best_score=0
            local i=0
            while [ $i -lt "$result_count" ]; do
                local snippet score=0
                snippet="$(printf '%s' "$results" | jq -r ".[$i].snippet // empty" | tr '[:upper:]' '[:lower:]')"
                local qw
                for qw in $query; do
                    qw="$(echo "$qw" | tr '[:upper:]' '[:lower:]')"
                    [ "${#qw}" -lt 3 ] && continue
                    if echo "$snippet" | grep -qiF "$qw"; then
                        score=$((score + 1))
                    fi
                done
                if [ "$score" -gt "$best_score" ]; then
                    best_score="$score"
                    best_idx=$i
                fi
                i=$((i + 1))
            done
            local snippet url
            snippet="$(printf '%s' "$results" | jq -r ".[$best_idx].snippet // empty")"
            url="$(printf '%s' "$results" | jq -r ".[$best_idx].url // empty")"
            output="$(jq -n --arg s "$snippet" --arg u "$url" '{answer:$s,url:$u}')"
            cache_set "$query" "$output"
            ;;
        *)
            echo "err: unknown tool: $tool"
            return 1
            ;;
    esac

    echo "$output"
    return $exit_code
}

# ── UI helpers ──────────────────────────────────────────
show_step_card() {
    local step_num="$1"
    local total="$2"
    local tool="$3"
    local display="$4"

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e " ${CYAN}Step $step_num/$total: ${tool}${RESET}"
    echo -e " ${DIM}>${RESET} $display"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

show_blocked_card() {
    local cmd="$1"
    local pattern="$2"

    echo ""
    echo -e "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e " ${RED}BLOCKED${RESET}"
    echo -e " ${DIM}>${RESET} $cmd"
    echo -e " ${DIM}pattern:${RESET} $pattern"
    echo -e "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

get_display_text() {
    local tool="$1"
    local args_json="$2"

    case "$tool" in
        read)
            echo "$(echo "$args_json" | jq -r '.path // "?"')"
            ;;
        write)
            local path
            path="$(echo "$args_json" | jq -r '.path // "?"')"
            local lines
            lines="$(echo "$args_json" | jq -r '.content // ""' | wc -l)"
            echo "$path (${lines}ln)"
            ;;
        shell)
            echo "$(echo "$args_json" | jq -r '.cmd // "?"')"
            ;;
        search)
            echo "$(printf '%s' "$args_json" | jq -r '.query // "?"')"
            ;;
    esac
}

# ── Step confirmation and execution ─────────────────────
confirm_and_exec_step() {
    local step_num="$1"
    local total="$2"
    local tool="$3"
    local args_json="$4"
    local display
    display="$(get_display_text "$tool" "$args_json")"

    # Validation for shell commands
    if [ "$tool" = "shell" ]; then
        local cmd
        cmd="$(echo "$args_json" | jq -r '.cmd // empty')"
        local blocked_pattern
        if ! blocked_pattern="$(validate_command "$cmd")"; then
            show_blocked_card "$cmd" "$blocked_pattern"
            log_event "blocked" "$(jq -n --arg cmd "$cmd" --arg pattern "$blocked_pattern" \
                '{cmd: $cmd, pattern: $pattern}')"
            return 1
        fi
    fi

    show_step_card "$step_num" "$total" "$tool" "$display"

    while true; do
        echo -e " ${YELLOW}[r]un  [s]kip  [e]dit  [c]ancel${RESET}"
        printf " > "
        read -n 1 action
        echo ""

        log_event "user_action" "$(jq -n --arg action "$action" --argjson step "$step_num" \
            '{step: $step, action: $action}')"

        case "$action" in
            r|R)
                log_event "exec_start" "$(jq -n --arg tool "$tool" --arg args "$args_json" \
                    '{tool: $tool, args: $args}')"
                local result
                result="$(exec_tool "$tool" "$args_json")"
                local rc=$?
                log_event "exec_done" "$(jq -n --arg tool "$tool" --argjson rc "$rc" --arg out "$result" \
                    '{tool: $tool, exit_code: $rc, output: $out}')"
                format_output "$result"
                LAST_RESULT="$(summarize_result "$tool" "$result")"
                return 0
                ;;
            s|S)
                echo -e "${DIM}Skipped.${RESET}"
                return 0
                ;;
            e|E)
                if [ "$tool" = "shell" ]; then
                    local cmd
                    cmd="$(echo "$args_json" | jq -r '.cmd // empty')"
                    echo -e " ${DIM}Edit command:${RESET}"
                    read -e -i "$cmd" new_cmd
                    local blocked_pattern
                    if ! blocked_pattern="$(validate_command "$new_cmd")"; then
                        show_blocked_card "$new_cmd" "$blocked_pattern"
                        log_event "blocked" "$(jq -n --arg cmd "$new_cmd" --arg pattern "$blocked_pattern" \
                            '{cmd: $cmd, pattern: $pattern}')"
                        return 1
                    fi
                    args_json="$(jq -n --arg cmd "$new_cmd" '{cmd: $cmd}')"
                    log_event "exec_start" "$(jq -n --arg tool "$tool" --arg args "$args_json" \
                        '{tool: $tool, args: $args}')"
                    local result
                    result="$(exec_tool "$tool" "$args_json")"
                    local rc=$?
                    log_event "exec_done" "$(jq -n --arg tool "$tool" --argjson rc "$rc" --arg out "$result" \
                        '{tool: $tool, exit_code: $rc, output: $out}')"
                    format_output "$result"
                    LAST_RESULT="$(summarize_result "$tool" "$result")"
                else
                    echo -e "${DIM}Edit only supported for shell commands. Running as-is.${RESET}"
                    local result
                    result="$(exec_tool "$tool" "$args_json")"
                    format_output "$result"
                    LAST_RESULT="$(summarize_result "$tool" "$result")"
                fi
                return 0
                ;;
            c|C)
                echo -e "${RED}Cancelled.${RESET}"
                return 2
                ;;
            *)
                echo -e " ${DIM}Press r, s, e, or c${RESET}"
                ;;
        esac
    done
}

# ── Spellcheck ─────────────────────────────────────────
spellcheck() {
    local input="$1"
    # Requires aspell
    if ! command -v aspell > /dev/null 2>&1; then
        echo "$input"
        return
    fi
    local corrected="$input"
    # Get misspelled words and their first suggestion
    while IFS= read -r line; do
        case "$line" in
            \&*)
                local misspelled suggestion
                misspelled="$(echo "$line" | cut -d' ' -f2)"
                suggestion="$(echo "$line" | cut -d' ' -f5 | tr -d ',')"
                # Only accept if first letter matches (filters false positives like kubernetes→Cabernet's)
                local orig_first sugg_first
                orig_first="$(echo "${misspelled:0:1}" | tr '[:upper:]' '[:lower:]')"
                sugg_first="$(echo "${suggestion:0:1}" | tr '[:upper:]' '[:lower:]')"
                [ "$orig_first" != "$sugg_first" ] && continue
                # Replace first occurrence (word-boundary safe via sed word match)
                corrected="$(echo "$corrected" | sed "s/\b${misspelled}\b/${suggestion}/i")"
                ;;
        esac
    done <<< "$(echo "$input" | aspell -a 2>/dev/null)"
    echo "$corrected"
}

# ── Pipeline ────────────────────────────────────────────
process_input() {
    local request="$1"

    log_event "user_input" "$(jq -n --arg req "$request" '{request: $req}')"

    # Spellcheck: if corrected version differs, propose it
    local corrected
    corrected="$(spellcheck "$request")"
    if [ "$corrected" != "$request" ]; then
        echo ""
        echo -e "  ${YELLOW}Did you mean:${RESET} ${BOLD}$corrected${RESET}"
        printf "  ${YELLOW}[y]es  [n]o${RESET} "
        read -n 1 spell_action
        echo ""
        log_event "spellcheck" "$(jq -n --arg orig "$request" --arg fix "$corrected" --arg action "$spell_action" \
            '{original: $orig, corrected: $fix, action: $action}')"
        if [ "$spell_action" = "y" ] || [ "$spell_action" = "Y" ]; then
            process_input "$corrected"
            return
        fi
    fi

    # Single model call: extract + order in one pass
    echo -e "${DIM}Thinking...${RESET}"
    local prompt
    prompt="$(build_plan_prompt "$request" "$LAST_RESULT")"

    log_event "context_built" "$(jq -n --arg prompt "$prompt" '{prompt: $prompt}')"

    local plan_output
    plan_output="$(call_model "$prompt" "$GRAMMAR_DIR/plan.gbnf")"

    if [ -z "$plan_output" ]; then
        echo -e "${RED}Model returned empty response.${RESET}"
        return
    fi

    local step_count
    step_count="$(echo "$plan_output" | jq '.plan | length' 2>/dev/null)" || step_count=0
    if [ "$step_count" -eq 0 ]; then
        echo -e "${RED}Failed to parse model output.${RESET}"
        log_event "parse_result" '{"success":false}'
        return
    fi

    log_event "parse_result" "$(jq -n --argjson count "$step_count" --arg raw "$plan_output" \
        '{success: true, step_count: $count, raw: $raw}')"

    if [ "$step_count" -eq 1 ]; then
        local tool args
        tool="$(echo "$plan_output" | jq -r '.plan[0].tool')"
        args="$(echo "$plan_output" | jq -c '.plan[0].args')"
        confirm_and_exec_step 1 1 "$tool" "$args"
        return
    fi

    # Multi-step — show plan and confirm
    echo ""
    echo -e "${BOLD}Plan ($step_count steps):${RESET}"
    local i=0
    while [ $i -lt "$step_count" ]; do
        local tool display args_json
        tool="$(echo "$plan_output" | jq -r ".plan[$i].tool")"
        args_json="$(echo "$plan_output" | jq -c ".plan[$i].args")"
        display="$(get_display_text "$tool" "$args_json")"
        echo -e "  ${CYAN}$((i+1)).${RESET} ${tool}: $display"
        i=$((i + 1))
    done

    log_event "plan_shown" "$(jq -n --argjson count "$step_count" '{step_count: $count}')"

    echo ""
    echo -e "${YELLOW}[a]pprove all  [s]tep-by-step  [e]dit  [c]ancel${RESET}"
    printf "> "
    read -n 1 plan_action
    echo ""

    log_event "user_action" "$(jq -n --arg action "$plan_action" '{plan_action: $action}')"

    case "$plan_action" in
        a|A)
            local i=0
            while [ $i -lt "$step_count" ]; do
                local tool args_json
                tool="$(echo "$plan_output" | jq -r ".plan[$i].tool")"
                args_json="$(echo "$plan_output" | jq -c ".plan[$i].args")"

                local display
                display="$(get_display_text "$tool" "$args_json")"
                echo -e "${CYAN}[$((i+1))/$step_count]${RESET} $tool: $display"

                if [ "$tool" = "shell" ]; then
                    local cmd
                    cmd="$(echo "$args_json" | jq -r '.cmd // empty')"
                    local blocked_pattern
                    if ! blocked_pattern="$(validate_command "$cmd")"; then
                        show_blocked_card "$cmd" "$blocked_pattern"
                        log_event "blocked" "$(jq -n --arg cmd "$cmd" --arg pattern "$blocked_pattern" \
                            '{cmd: $cmd, pattern: $pattern}')"
                        i=$((i + 1))
                        continue
                    fi
                fi

                log_event "exec_start" "$(jq -n --arg tool "$tool" --arg args "$args_json" \
                    '{tool: $tool, args: $args}')"
                local result
                result="$(exec_tool "$tool" "$args_json")"
                local rc=$?
                log_event "exec_done" "$(jq -n --arg tool "$tool" --argjson rc "$rc" --arg out "$result" \
                    '{tool: $tool, exit_code: $rc, output: $out}')"
                format_output "$result"
                LAST_RESULT="$(summarize_result "$tool" "$result")"
                i=$((i + 1))
            done
            ;;
        s|S)
            local i=0
            while [ $i -lt "$step_count" ]; do
                local tool args_json
                tool="$(echo "$plan_output" | jq -r ".plan[$i].tool")"
                args_json="$(echo "$plan_output" | jq -c ".plan[$i].args")"
                confirm_and_exec_step "$((i+1))" "$step_count" "$tool" "$args_json"
                local rc=$?
                if [ $rc -eq 2 ]; then
                    break
                fi
                i=$((i + 1))
            done
            ;;
        e|E)
            echo -e "${DIM}Edit not yet supported for plans. Use step-by-step mode.${RESET}"
            ;;
        c|C)
            echo -e "${RED}Cancelled.${RESET}"
            ;;
    esac
}

# ── Built-in commands ───────────────────────────────────
handle_builtin() {
    local input="$1"
    case "$input" in
        /help)
            echo -e "${BOLD}Commands:${RESET}"
            echo "  /help  — show this"
            echo "  /log   — show log file path"
            echo "  /quit  — stop server, exit"
            echo ""
            echo -e "${BOLD}Tools:${RESET}"
            echo "  read(path)          — read file"
            echo "  write(path,content) — write file"
            echo "  shell(cmd)          — run command"
            echo "  search(query)       — web search"
            return 0
            ;;
        /log)
            echo "$LOG_FILE"
            return 0
            ;;
        /quit)
            echo "Bye."
            exit 0
            ;;
    esac
    return 1
}

# ── Non-interactive query mode ─────────────────────────
run_query() {
    local input="$1"
    mkdir -p "$LOG_DIR"
    start_server
    local prompt
    prompt="$(build_plan_prompt "$input" "$LAST_RESULT")"
    local plan_output
    plan_output="$(call_model "$prompt" "$GRAMMAR_DIR/plan.gbnf")"
    if [ -z "$plan_output" ]; then
        echo "Model returned empty response." >&2
        return 1
    fi

    local step_count
    step_count="$(echo "$plan_output" | jq '.plan | length' 2>/dev/null)" || step_count=0
    if [ "$step_count" -eq 0 ]; then
        echo "Failed to parse model output." >&2
        return 1
    fi

    # Execute only search steps (skip write/shell for safety in non-interactive mode)
    local i=0
    while [ $i -lt "$step_count" ]; do
        local tool args_json
        tool="$(echo "$plan_output" | jq -r ".plan[$i].tool")"
        args_json="$(echo "$plan_output" | jq -c ".plan[$i].args")"
        if [ "$tool" = "search" ]; then
            local result
            result="$(exec_tool "$tool" "$args_json")"
            format_output "$result"
            LAST_RESULT="$(summarize_result "$tool" "$result")"
        fi
        i=$((i + 1))
    done
}

# ── Direct search test mode ───────────────────────────
run_search() {
    local query="$1"
    mkdir -p "$LOG_DIR"
    start_server
    local result
    result="$(exec_tool "search" "$(jq -n --arg q "$query" '{query:$q}')")"
    format_output "$result"
}

# ── Main REPL ───────────────────────────────────────────
main() {
    mkdir -p "$LOG_DIR"

    echo -e "${BOLD}miniagents${RESET} ${DIM}v0.1${RESET}"
    echo -e "${DIM}Session: $SESSION_ID${RESET}"
    echo ""

    start_server

    echo ""
    while true; do
        printf "${GREEN}> ${RESET}"
        read -r input

        # Handle EOF
        if [ $? -ne 0 ]; then
            echo ""
            exit 0
        fi

        # Skip empty
        [ -z "$input" ] && continue

        # Built-in commands
        if handle_builtin "$input"; then
            continue
        fi

        process_input "$input"
        echo ""
    done
}

# Only run main when executed directly, not when sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        --query)
            shift
            run_query "$*"
            ;;
        --search)
            shift
            run_search "$*"
            ;;
        *)
            main "$@"
            ;;
    esac
fi
