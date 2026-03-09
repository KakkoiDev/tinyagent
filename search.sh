#!/usr/bin/env bash
# Usage: search.sh "query" [max_results]
# Returns JSON array of {title, url, snippet} from DuckDuckGo Lite
# Uses lightpanda (headless browser) with curl fallback
set -uo pipefail

QUERY="${1:?Usage: search.sh QUERY [max_results]}"
MAX="${2:-3}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIGHTPANDA="$SCRIPT_DIR/lightpanda"
DDG_URL="https://lite.duckduckgo.com/lite/"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"

# ── Fetch DDG results ─────────────────────────────────
encoded_query="$(printf '%s' "$QUERY" | sed 's/ /+/g')"

if [ -x "$LIGHTPANDA" ]; then
    raw="$("$LIGHTPANDA" fetch --dump markdown "${DDG_URL}?q=${encoded_query}" 2>/dev/null)" || raw=""
    use_markdown=true
else
    raw="$(curl -s --max-time 10 -A "$UA" -d "q=$QUERY" "$DDG_URL" 2>/dev/null)"
    use_markdown=false
fi

if [ -z "$raw" ]; then
    echo '[]'
    exit 0
fi

# ── Parse markdown output (lightpanda) ────────────────
if [ "$use_markdown" = true ]; then
    # Replace non-breaking spaces (U+00A0) with regular spaces
    NBSP="$(printf '\xc2\xa0')"
    echo "$raw" | sed "s/$NBSP/ /g" | awk -v max="$MAX" '
BEGIN { n=0; ORS=""; waiting_snippet=0 }

# Match numbered result lines: |  1.   |   [Title](url)  |
/^\|  [0-9]+\./ {
    s = $0
    if (match(s, /\[([^\]]+)\]\(([^)]+)\)/)) {
        m = substr(s, RSTART, RLENGTH)
        split_pos = index(m, "](")
        title = substr(m, 2, split_pos - 2)
        url = substr(m, split_pos + 2, length(m) - split_pos - 2)
    }
    # Extract real URL from DDG redirect
    if (match(url, /uddg=[^&]+/)) {
        encoded = substr(url, RSTART+5, RLENGTH-5)
        gsub(/%2F/, "/", encoded)
        gsub(/%3A/, ":", encoded)
        gsub(/%23/, "#", encoded)
        gsub(/%3F/, "?", encoded)
        gsub(/%3D/, "=", encoded)
        gsub(/%26/, "\\&", encoded)
        url = encoded
    }
    # Strip markdown escapes from title
    gsub(/\\-/, "-", title)
    gsub(/\\\|/, "|", title)
    # Skip DDG ads
    if (url ~ /duckduckgo\.com\/y\.js/) { url=""; title=""; next }
    waiting_snippet = 1
    next
}

# Snippet: first content line after title (skip separator and domain lines)
waiting_snippet && /^\|/ {
    # Skip separator lines |---|---|
    if ($0 ~ /^[|[:space:]-]+$/) next
    s = $0
    # Remove table markup
    gsub(/^\|[^|]*\|/, "", s)
    gsub(/\|[[:space:]]*$/, "", s)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
    # Skip empty lines
    if (s == "") next
    # Skip domain-only lines (no spaces = just a URL)
    if (s !~ / / && s ~ /\./) next
    # Strip markdown bold and escapes
    gsub(/\*\*/, "", s)
    gsub(/\\-/, "-", s)
    gsub(/\\\|/, "|", s)

    snippet = s
    waiting_snippet = 0

    # JSON-escape
    gsub(/\\/, "\\\\", title); gsub(/"/, "\\\"", title)
    gsub(/\\/, "\\\\", snippet); gsub(/"/, "\\\"", snippet)
    gsub(/\\/, "\\\\", url); gsub(/"/, "\\\"", url)

    if (n == 0) print "["
    else print ","
    printf "{\"title\":\"%s\",\"url\":\"%s\",\"snippet\":\"%s\"}", title, url, snippet
    n++
    title=""; url=""; snippet=""
    if (n >= max) exit
}

END {
    if (n == 0) print "[]"
    else print "]"
}
' 2>/dev/null
    exit 0
fi

# ── Parse HTML output (curl fallback) ─────────────────
echo "$raw" | awk -v max="$MAX" '
BEGIN { n=0; in_sponsored=0; title=""; url=""; ORS="" }

/<tr class="result-sponsored">/ { in_sponsored=1; next }

/class=.result-link./ && !in_sponsored {
    s = $0
    if (match(s, /href="[^"]+"/)) {
        url = substr(s, RSTART+6, RLENGTH-7)
    }
    if (match(s, /result-link.>[^<]*/)) {
        t = substr(s, RSTART, RLENGTH)
        idx = index(t, ">")
        if (idx > 0) title = substr(t, idx+1)
    }
    if (url ~ /duckduckgo\.com/ || url ~ /^$/) { url=""; title=""; next }
}

/class=.result-snippet./ && url != "" {
    getline snippet_line
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", snippet_line)
    gsub(/<[^>]+>/, "", snippet_line)
    gsub(/&#x27;/, "'\''", snippet_line); gsub(/&#x27;/, "'\''", title)
    gsub(/&#92;/, "", snippet_line); gsub(/&#92;/, "", title)
    gsub(/&amp;/, "\\&", snippet_line); gsub(/&amp;/, "\\&", title)
    gsub(/&lt;/, "<", snippet_line); gsub(/&lt;/, "<", title)
    gsub(/&gt;/, ">", snippet_line); gsub(/&gt;/, ">", title)
    gsub(/\\/, "\\\\", snippet_line); gsub(/\\/, "\\\\", title)
    gsub(/"/, "\\\"", snippet_line); gsub(/"/, "\\\"", title); gsub(/"/, "\\\"", url)

    if (n == 0) print "["
    else print ","
    printf "{\"title\":\"%s\",\"url\":\"%s\",\"snippet\":\"%s\"}", title, url, snippet_line
    n++
    url=""; title=""
    in_sponsored=0
    if (n >= max) exit
}

/<\/tr>/ { in_sponsored=0 }

END {
    if (n == 0) print "[]"
    else print "]"
}
' 2>/dev/null

exit 0
