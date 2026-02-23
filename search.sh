#!/usr/bin/env bash
# Usage: search.sh "query" [max_results]
# Returns JSON array of {title, url, snippet} from DuckDuckGo Lite
set -uo pipefail

QUERY="${1:?Usage: search.sh QUERY [max_results]}"
MAX="${2:-3}"
DDG_URL="https://lite.duckduckgo.com/lite/"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"

raw="$(curl -s --max-time 10 -A "$UA" -d "q=$QUERY" "$DDG_URL" 2>/dev/null)"

if [ -z "$raw" ]; then
    echo '{"error":"no response from DuckDuckGo"}'
    exit 1
fi

# Parse: extract non-sponsored result-link titles/urls and result-snippet text
# Use awk to pair them up
echo "$raw" | awk -v max="$MAX" '
BEGIN { n=0; in_sponsored=0; title=""; url=""; ORS="" }

/<tr class="result-sponsored">/ { in_sponsored=1; next }

# Detect organic result rows (not sponsored)
/class=.result-link./ && !in_sponsored {
    # Extract URL
    match($0, /href="([^"]+)"/, arr)
    url = arr[1]
    # Extract title (text between > and </a>)
    match($0, /class='\''result-link'\''>[^<]*/, arr2)
    if (arr2[0] != "") {
        title = substr(arr2[0], index(arr2[0], ">") + 1)
    }
    # Skip DDG internal links
    if (url ~ /duckduckgo\.com/ || url ~ /^$/) { url=""; title=""; next }
}

/class=.result-snippet./ && url != "" {
    # Next line has the snippet text
    getline snippet_line
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", snippet_line)
    gsub(/<[^>]+>/, "", snippet_line)  # strip HTML tags
    # Decode HTML entities first
    gsub(/&#x27;/, "'\''", snippet_line); gsub(/&#x27;/, "'\''", title)
    gsub(/&#92;/, "", snippet_line); gsub(/&#92;/, "", title)
    gsub(/&amp;/, "\\&", snippet_line); gsub(/&amp;/, "\\&", title)
    gsub(/&lt;/, "<", snippet_line); gsub(/&lt;/, "<", title)
    gsub(/&gt;/, ">", snippet_line); gsub(/&gt;/, ">", title)
    # JSON-escape: quotes and backslashes
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

# Reset sponsored flag on new result row
/<\/tr>/ { in_sponsored=0 }

END {
    if (n == 0) print "[]"
    else print "]"
}
' 2>/dev/null

exit 0
