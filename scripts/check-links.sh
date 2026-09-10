#!/usr/bin/env bash
# Check every link in the repository's own documentation.
#
#   - relative Markdown links must point at a file that exists (offline, always fatal)
#   - absolute URLs must not 404 (network; transient failures are reported, not fatal)
#
# Vendored third-party sources carry hundreds of upstream links of their own, so
# they are excluded.
set -uo pipefail

cd "$(dirname "$0")/.."
EXCLUDE='clients/cpp/include/priostack/vendor/'   # vendored nlohmann/json: upstream's own links
fail=0

echo "== relative Markdown links =="
missing=$(
  git ls-files '*.md' | grep -v "$EXCLUDE" | while read -r f; do
    dir=$(dirname "$f")
    grep -oE '\]\([^)]+\)' "$f" | sed 's/^](//;s/)$//' | while read -r link; do
      case "$link" in http*|mailto:*|'#'*) continue ;; esac
      target="${link%%#*}"
      [ -z "$target" ] && continue
      if [ ! -e "$dir/$target" ] && [ ! -e "$target" ]; then
        echo "  MISSING  $f -> $link"
      fi
    done
  done
)
if [ -n "$missing" ]; then
  echo "$missing"
  fail=1
else
  echo "  all relative links resolve"
fi

echo
echo "== absolute URLs =="
urls=$(git ls-files | grep -v "$EXCLUDE" \
  | xargs grep -hoE "https?://[A-Za-z0-9._~:/?#@!\$&'()*+,;=%-]+" 2>/dev/null \
  | sed "s/[).,:;\"'>*\`\\\\]*$//" \
  | grep -vE 'maven\.apache\.org/(POM|xsd)/|www\.w3\.org/2001/|//(127\.0\.0\.1|localhost)' \
  | sort -u)   # XML namespace URIs and loopback addresses are identifiers, not links

for u in $urls; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' -L --max-time 25 --retry 2 --retry-delay 3 "$u" 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "  skip     (network: curl $rc)  $u"          # offline runner, DNS block, TLS interception
    continue
  fi
  case "$code" in
    2*|3*)             echo "  ok  $code  $u" ;;
    401|403|405|406|429) echo "  skip $code  $u" ;;    # bot protection, or a JSON-RPC endpoint answering a bare GET
    404|410)           echo "  DEAD $code  $u"; fail=1 ;;
    *)                 echo "  warn $code  $u" ;;      # 5xx and friends: transient, not a broken link
  esac
done

echo
if [ "$fail" -ne 0 ]; then
  echo "FAIL: broken links above."
  exit 1
fi
echo "OK: no broken links."
