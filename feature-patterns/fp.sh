#!/usr/bin/env bash
# fp.sh - polite public-source research helper for the feature-patterns skill.
#
# Every network request goes through one gate: the URL must be public http(s),
# the site's robots.txt must allow it for the "feature-patterns" token, and the
# same host is never hit more often than FP_MIN_INTERVAL seconds (or the site's
# Crawl-delay, whichever is longer). Nothing here logs in, sends cookies or
# follows a redirect without checking robots.txt again.
#
# Requirements: bash 3.2+, curl, jq, awk. `shot` also needs a Chrome-family browser.

set -u

FP_VERSION=0.1.0
FP_UA="feature-patterns/$FP_VERSION (+https://github.com/MarceloCajueiro/feature-patterns)"
FP_ROBOTS_TOKEN=feature-patterns
FP_MIN_INTERVAL=${FP_MIN_INTERVAL:-5}
FP_HTTP_TIMEOUT=${FP_HTTP_TIMEOUT:-20}
FP_MAX_BYTES=${FP_MAX_BYTES:-8388608}
FP_MAX_REDIRECTS=${FP_MAX_REDIRECTS:-3}
FP_ROBOTS_TTL=${FP_ROBOTS_TTL:-3600}
FP_HEADINGS=${FP_HEADINGS:-25}
FP_TEXT_MAX=${FP_TEXT_MAX:-20000}
FP_SHOT_TIMEOUT=${FP_SHOT_TIMEOUT:-45}
FP_STATE_DIR=${FP_STATE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/feature-patterns}

FP_DIR=$(cd -- "$(dirname -- "$0")" && pwd -P)

BODY_FILE=
trap 'rm -f "${BODY_FILE:-}"' EXIT

die()    { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
refuse() { printf 'REFUSED: %s\n' "$*" >&2; exit 3; }
usage_die() { printf 'ERROR: %s\n' "$*" >&2; printf 'Run "fp.sh help" for usage.\n' >&2; exit 2; }
warn()   { printf 'WARN: %s\n' "$*" >&2; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but was not found on PATH"; }

# Printable single line: drop control characters, collapse whitespace, cap length.
clean_line() {
  LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' | tr '\t\r\n' '   ' |
    sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//' | cut -c1-"${1:-300}"
}

# ---------------------------------------------------------------- URLs

# Research targets are public products with host names. This is a scope guard,
# not a sandbox: IP literals of any form (dotted, integer, hex, IPv6) and
# local-only names are refused; names are not resolved, see docs/design.md.
require_public_host() {
  case $1 in
    ''|\[*|*[!a-z0-9.-]*) refuse "only public host names are allowed: $1" ;;
    localhost|*.localhost|*.local|*.internal|*.lan|*.home.arpa)
      refuse "only public host names are allowed: $1" ;;
  esac
  case $1 in
    *[!0-9.]*) ;;
    *) refuse "IP addresses are not accepted, use the site's host name: $1" ;;
  esac
  case $1 in
    0x*|*.0x*) refuse "IP addresses are not accepted, use the site's host name: $1" ;;
    *.*) ;;
    *) refuse "only fully qualified public host names are allowed: $1" ;;
  esac
}

# Sets URL_CLEAN ORIGIN HOST PATHQ, or refuses the URL.
parse_url() {
  local url=$1 rest authority
  case $url in
    http://*|https://*) ;;
    *) refuse "only public http(s) URLs are allowed: $url" ;;
  esac
  case $url in *[[:space:]]*|*[[:cntrl:]]*) refuse "URL contains whitespace or control characters" ;; esac
  rest=${url#*://}
  rest=${rest%%#*}
  authority=${rest%%[/?]*}
  PATHQ=${rest#"$authority"}
  case $authority in
    '') refuse "URL has no host: $url" ;;
    *@*) refuse "URLs carrying credentials are refused" ;;
  esac
  authority=$(printf '%s' "$authority" | tr 'A-Z' 'a-z')
  HOST=${authority%:*}
  case $authority in \[*) HOST=${authority%%]*}]; ;; esac
  require_public_host "$HOST"
  case $PATHQ in '') PATHQ=/ ;; \?*) PATHQ=/$PATHQ ;; esac
  ORIGIN=${url%%://*}://$authority
  URL_CLEAN=$ORIGIN$PATHQ
}

# Resolves a Location header against the current URL.
resolve_location() {
  local loc=$1
  case $loc in
    http://*|https://*) printf '%s' "$loc" ;;
    //*) printf '%s:%s' "${ORIGIN%%://*}" "$loc" ;;
    /*) printf '%s%s' "$ORIGIN" "$loc" ;;
    *) printf '%s/%s' "${URL_CLEAN%/*}" "$loc" ;;
  esac
}

# ---------------------------------------------------------------- politeness

state_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9.-' '_'; }

# Blocks until this host may receive another request, then records the request.
wait_turn() {
  local host=$1 delay=${2:-0} interval=$FP_MIN_INTERVAL file now last wait
  mkdir -p "$FP_STATE_DIR/hosts" || die "cannot create $FP_STATE_DIR/hosts"
  case $delay in ''|*[!0-9.]*) delay=0 ;; esac
  delay=${delay%%.*}; [ -n "$delay" ] || delay=0
  [ "$delay" -gt "$interval" ] && interval=$delay
  file=$FP_STATE_DIR/hosts/$(state_key "$host")
  now=$(date +%s)
  last=$(cat "$file" 2>/dev/null || echo 0)
  case $last in ''|*[!0-9]*) last=0 ;; esac
  wait=$((last + interval - now))
  if [ "$wait" -gt 0 ]; then
    printf 'waiting %ss before the next request to %s\n' "$wait" "$host" >&2
    sleep "$wait"
  fi
  date +%s > "$file"
}

# One HTTP GET, no redirects followed, no cookies, no ~/.curlrc.
# Prints "status<TAB>content_type<TAB>redirect_url"; the body goes to $2.
http_get() {
  local url=$1 out=$2
  curl -q -sS --proto '=http,https' --max-time "$FP_HTTP_TIMEOUT" \
    --max-filesize "$FP_MAX_BYTES" -A "$FP_UA" -H 'Accept-Language: en-US,en;q=0.8' \
    -o "$out" -w '%{http_code}\t%{content_type}\t%{redirect_url}' "$url" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------- robots.txt

# Evaluates robots.txt rules (RFC 9309): the group naming our token wins over "*",
# the longest matching rule wins, Allow wins a tie, "*" and a final "$" are wildcards.
# Prints "allow|disallow<TAB>matching rule<TAB>crawl-delay".
robots_eval() {
  awk -v token="$FP_ROBOTS_TOKEN" -v path="$2" '
    function rx(p,   re, c, i, anchored) {
      anchored = 0
      if (substr(p, length(p)) == "$") { anchored = 1; p = substr(p, 1, length(p) - 1) }
      re = "^"
      for (i = 1; i <= length(p); i++) {
        c = substr(p, i, 1)
        if (c == "*") re = re ".*"
        else if (index(".[]()+?{}|^$\\", c)) re = re "\\" c
        else re = re c
      }
      if (anchored) re = re "$"
      return re
    }
    BEGIN { tok = tolower(token); g = 0; in_ua = 0 }
    {
      line = $0
      sub(/\r$/, "", line); sub(/#.*/, "", line)
      i = index(line, ":"); if (i == 0) next
      key = tolower(substr(line, 1, i - 1)); gsub(/^[ \t]+|[ \t]+$/, "", key)
      val = substr(line, i + 1); gsub(/^[ \t]+|[ \t]+$/, "", val)
      if (key == "user-agent") {
        if (!in_ua) { g++; spec[g] = 0; star[g] = 0; n[g] = 0; cd[g] = "" }
        v = tolower(val)
        if (v == tok) spec[g] = 1
        else if (v == "*") star[g] = 1
        in_ua = 1
        next
      }
      in_ua = 0
      if (g == 0) next
      if (key == "allow" || key == "disallow") { n[g]++; rk[g, n[g]] = key; rv[g, n[g]] = val }
      else if (key == "crawl-delay") cd[g] = val
    }
    END {
      use_spec = 0
      for (k = 1; k <= g; k++) if (spec[k]) use_spec = 1
      best = -1; decision = "allow"; rule = ""; delay = ""
      for (k = 1; k <= g; k++) {
        if (use_spec ? !spec[k] : !star[k]) continue
        if (cd[k] != "") delay = cd[k]
        for (j = 1; j <= n[k]; j++) {
          p = rv[k, j]
          if (p == "") continue
          if (match(path, rx(p))) {
            L = length(p)
            if (L > best || (L == best && rk[k, j] == "allow")) {
              best = L; decision = rk[k, j]; rule = rk[k, j] ": " p
            }
          }
        }
      }
      printf "%s\t%s\t%s\n", decision, rule, delay
    }
  ' "$1"
}

# Fetches (or reads from cache) robots.txt for ORIGIN. Sets ROBOTS_FILE, or
# ROBOTS_FILE="" with ROBOTS_ERROR when the site cannot be checked.
load_robots() {
  local key cache meta now fetched status line hops url tmp rhost
  key=$(state_key "$ORIGIN")
  mkdir -p "$FP_STATE_DIR/robots" || die "cannot create $FP_STATE_DIR/robots"
  cache=$FP_STATE_DIR/robots/$key
  meta=$cache.meta
  now=$(date +%s)
  if [ -f "$cache" ] && [ -f "$meta" ]; then
    fetched=$(cat "$meta")
    case $fetched in ''|*[!0-9]*) fetched=0 ;; esac
    if [ $((now - fetched)) -lt "$FP_ROBOTS_TTL" ]; then ROBOTS_FILE=$cache; ROBOTS_ERROR=; return 0; fi
  fi
  tmp=$cache.tmp
  url=$ORIGIN/robots.txt
  hops=0
  while :; do
    wait_turn "$HOST"
    line=$(http_get "$url" "$tmp")
    status=${line%%	*}
    case $status in
      301|302|303|307|308)
        hops=$((hops + 1))
        [ "$hops" -le 5 ] || { ROBOTS_FILE=; ROBOTS_ERROR="robots.txt redirects too many times"; return 0; }
        url=${line##*	}
        [ -n "$url" ] || { ROBOTS_FILE=; ROBOTS_ERROR="robots.txt redirect without a location"; return 0; }
        # curl reports an absolute URL; it must stay public http(s) like any other target.
        case $url in http://*|https://*) ;; *) ROBOTS_FILE=; ROBOTS_ERROR="robots.txt redirects outside http(s)"; return 0 ;; esac
        rhost=${url#*://}
        rhost=${rhost%%[/?#]*}
        case $rhost in *@*) ROBOTS_FILE=; ROBOTS_ERROR="robots.txt redirect carries credentials"; return 0 ;; esac
        rhost=$(printf '%s' "${rhost%:*}" | tr 'A-Z' 'a-z')
        ( require_public_host "$rhost" ) 2>/dev/null || { ROBOTS_FILE=; ROBOTS_ERROR="robots.txt redirects to a non-public host"; return 0; }
        ;;
      *) break ;;
    esac
  done
  case $status in
    2??) mv "$tmp" "$cache" ;;
    429) rm -f "$tmp"; ROBOTS_FILE=; ROBOTS_ERROR="robots.txt answered 429 (rate limited)"; return 0 ;;
    4??) rm -f "$tmp"; : > "$cache" ;;   # no robots.txt: everything is allowed
    *) rm -f "$tmp"; ROBOTS_FILE=; ROBOTS_ERROR="robots.txt unreachable (HTTP ${status:-000})"; return 0 ;;
  esac
  printf '%s\n' "$now" > "$meta"
  ROBOTS_FILE=$cache
  ROBOTS_ERROR=
}

# Sets ROBOTS_DECISION ROBOTS_RULE CRAWL_DELAY for URL_CLEAN.
check_robots() {
  local res
  load_robots
  if [ -z "$ROBOTS_FILE" ]; then
    ROBOTS_DECISION=disallow; ROBOTS_RULE="$ROBOTS_ERROR, treated as disallow"; CRAWL_DELAY=
    return 0
  fi
  res=$(robots_eval "$ROBOTS_FILE" "$PATHQ")
  ROBOTS_DECISION=${res%%	*}
  res=${res#*	}
  ROBOTS_RULE=${res%%	*}
  CRAWL_DELAY=${res#*	}
}

# Refuses unless robots.txt allows URL_CLEAN.
require_allowed() {
  check_robots
  [ "$ROBOTS_DECISION" = allow ] || refuse "robots.txt disallows $URL_CLEAN (${ROBOTS_RULE:-no rule})"
}

# GET with the full gate, following redirects only after re-checking robots.txt.
# Sets BODY_FILE FINAL_URL HTTP_STATUS CONTENT_TYPE.
polite_get() {
  local url=$1 line loc hops=0
  BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/fp.XXXXXX") || die "cannot create a temporary file"
  while :; do
    parse_url "$url"
    require_allowed
    wait_turn "$HOST" "$CRAWL_DELAY"
    line=$(http_get "$URL_CLEAN" "$BODY_FILE")
    HTTP_STATUS=${line%%	*}
    line=${line#*	}
    CONTENT_TYPE=${line%%	*}
    loc=${line#*	}
    case $HTTP_STATUS in
      301|302|303|307|308)
        hops=$((hops + 1))
        [ "$hops" -le "$FP_MAX_REDIRECTS" ] || die "too many redirects from $1"
        [ -n "$loc" ] || die "redirect without a location from $URL_CLEAN"
        url=$(resolve_location "$loc")
        ;;
      *) break ;;
    esac
  done
  FINAL_URL=$URL_CLEAN
  case $HTTP_STATUS in
    2??) ;;
    000) rm -f "$BODY_FILE"; die "request failed (network error, timeout or a body over $FP_MAX_BYTES bytes): $FINAL_URL" ;;
    *) rm -f "$BODY_FILE"; die "HTTP $HTTP_STATUS from $FINAL_URL" ;;
  esac
}

# ---------------------------------------------------------------- HTML

decode_entities() {
  sed -e 's/&nbsp;/ /g' -e 's/&quot;/"/g' -e "s/&#39;/'/g" -e "s/&#x27;/'/g" -e "s/&apos;/'/g" \
      -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&#8217;/'"'"'/g' -e 's/&#8211;/-/g' -e 's/&#8212;/-/g' -e 's/&amp;/\&/g'
}

# Prints TITLE, DESCRIPTION, OG_TITLE, OG_IMAGE, CANONICAL and H1/H2/H3 lines.
html_summary() {
  awk -v max="$FP_HEADINGS" '
    function attr(t, name,   re, v) {
      re = name "[ \t\r\n]*=[ \t\r\n]*(\"[^\"]*\"|\047[^\047]*\047)"
      if (!match(t, re)) return ""
      v = substr(t, RSTART, RLENGTH); sub(/^[^=]*=[ \t\r\n]*/, "", v)
      return substr(v, 2, length(v) - 2)
    }
    function emit(k, v) { gsub(/[ \t\r\n]+/, " ", v); sub(/^ /, "", v); sub(/ $/, "", v); if (v != "") print k "\t" v }
    BEGIN { RS = "<"; cap = ""; skip = ""; nh = 0 }
    {
      i = index($0, ">"); if (!i) { if (cap != "") buf = buf "<" $0; next }
      t = substr($0, 1, i - 1); txt = substr($0, i + 1); lt = tolower(t)
      name = lt; sub(/[ \t\r\n\/].*/, "", name)
      if (skip != "") { if (lt ~ ("^/" skip)) skip = ""; next }
      if (substr(lt, 1, 1) == "/") {
        c = substr(lt, 2); sub(/[ \t\r\n].*/, "", c)
        if (cap != "" && c == cap) {
          if (cap == "title" && !have_title) { emit("TITLE", buf); have_title = 1 }
          else if (cap != "title" && nh < max) { emit(toupper(cap), buf); nh++ }
          cap = ""; buf = ""
        }
        if (cap != "") buf = buf " " txt
        next
      }
      if (name == "script" || name == "style" || name == "noscript" || name == "svg") { if (lt !~ /\/$/) skip = name; next }
      if (name == "meta") {
        k = tolower(attr(lt, "name")); if (k == "") k = tolower(attr(lt, "property"))
        v = attr(t, "content")
        if (k == "description" && !d) { emit("DESCRIPTION", v); d = 1 }
        if (k == "og:title" && !ot) { emit("OG_TITLE", v); ot = 1 }
        if (k == "og:image" && !oi) { emit("OG_IMAGE", v); oi = 1 }
        next
      }
      if (name == "link" && tolower(attr(lt, "rel")) == "canonical" && !cn) { emit("CANONICAL", attr(t, "href")); cn = 1; next }
      if (name == "title" || name == "h1" || name == "h2" || name == "h3") { cap = name; buf = txt; next }
      if (cap != "") buf = buf " " txt
    }
  ' "$1" | decode_entities | while IFS= read -r l; do
    printf '%s\t%s\n' "${l%%	*}" "$(printf '%s' "${l#*	}" | clean_line 300)"
  done
}

# Readable text of a page: scripts, styles and markup dropped, one block per line,
# capped at FP_TEXT_MAX characters.
html_text() {
  awk '
    BEGIN { RS = "<"; skip = "" }
    {
      i = index($0, ">"); if (!i) next
      t = tolower(substr($0, 1, i - 1)); txt = substr($0, i + 1)
      name = t; sub(/^\//, "", name); sub(/[ \t\r\n\/].*/, "", name)
      if (skip != "") { if (t ~ ("^/" skip)) skip = ""; next }
      if (substr(t, 1, 1) != "/" && (name == "script" || name == "style" || name == "noscript" || name == "svg" || name == "template")) { if (t !~ /\/$/) skip = name; next }
      if (name ~ /^(p|div|li|tr|br|h[1-6]|section|article|header|footer|ul|ol|table|dt|dd|figcaption|blockquote|pre)$/) printf "\n"
      if (name == "li" && substr(t, 1, 1) != "/") printf "- "
      if (name ~ /^h[1-6]$/ && substr(t, 1, 1) != "/") printf "%s ", substr("######", 1, substr(name, 2) + 0)
      gsub(/[ \t\r\n]+/, " ", txt)
      printf "%s", txt
    }
  ' "$1" | decode_entities | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' |
    sed -e 's/^ *//' -e 's/ *$//' | awk 'NF { print; blank = 0; next } !blank { print; blank = 1 }' |
    head -c "$FP_TEXT_MAX"
  printf '\n'
}

# Prints the text content of the <script> whose opening tag contains $2.
script_content() {
  awk -v marker="$2" '
    BEGIN { RS = "<script" }
    NR > 1 {
      i = index($0, ">"); if (!i) next
      if (index(substr($0, 1, i), marker) == 0) next
      body = substr($0, i + 1)
      j = index(body, "</script>"); if (j) body = substr(body, 1, j - 1)
      print body
      exit
    }
  ' "$1"
}

# ---------------------------------------------------------------- commands

cmd_robots() {
  [ $# -eq 1 ] || usage_die "usage: fp.sh robots <url>"
  parse_url "$1"
  check_robots
  if [ "$ROBOTS_DECISION" = allow ]; then
    printf 'ALLOW\t%s\t%s\n' "$URL_CLEAN" "${ROBOTS_RULE:-no matching rule}"
  else
    printf 'DISALLOW\t%s\t%s\n' "$URL_CLEAN" "${ROBOTS_RULE:-no matching rule}"
  fi
  [ -n "$CRAWL_DELAY" ] && printf 'CRAWL_DELAY\t%s\n' "$CRAWL_DELAY"
  [ "$ROBOTS_DECISION" = allow ] || exit 3
}

cmd_fetch() {
  local url= out= text= usage="usage: fp.sh fetch <url> [--text] [-o file]"
  while [ $# -gt 0 ]; do
    case $1 in
      -o) [ $# -ge 2 ] || usage_die "-o needs a file"; out=$2; shift 2 ;;
      --text) text=1; shift ;;
      -*) usage_die "unknown option: $1" ;;
      *) [ -z "$url" ] || usage_die "$usage"; url=$1; shift ;;
    esac
  done
  [ -n "$url" ] || usage_die "$usage"
  polite_get "$url"
  printf 'URL\t%s\n' "$FINAL_URL"
  printf 'STATUS\t%s\n' "$HTTP_STATUS"
  printf 'TYPE\t%s\n' "${CONTENT_TYPE:-unknown}"
  case $CONTENT_TYPE in
    *html*|'')
      html_summary "$BODY_FILE"
      if [ -n "$text" ]; then printf 'TEXT\n'; html_text "$BODY_FILE"; fi
      ;;
    text/*)
      if [ -n "$text" ]; then printf 'TEXT\n'; LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' < "$BODY_FILE" | head -c "$FP_TEXT_MAX"; printf '\n'; fi
      ;;
  esac
  if [ -n "$out" ]; then
    mv "$BODY_FILE" "$out" || die "cannot write $out"
    printf 'SAVED\t%s\n' "$out"
  else
    rm -f "$BODY_FILE"
  fi
}

cmd_appstore() {
  [ $# -eq 1 ] || usage_die "usage: fp.sh appstore <apps.apple.com listing URL | numeric app id>"
  local target=$1 json ld
  case $target in
    *[!0-9]*) ;;
    *) target="https://apps.apple.com/us/app/id$target" ;;
  esac
  case $target in
    https://apps.apple.com/*) ;;
    *) usage_die "appstore takes an https://apps.apple.com/... listing URL or a numeric app id" ;;
  esac
  polite_get "$target"
  ld=$(script_content "$BODY_FILE" 'software-application')
  printf 'URL\t%s\n' "$FINAL_URL"
  if [ -n "$ld" ]; then
    printf '%s' "$ld" | jq -r '
      "NAME\t\(.name // "")",
      "DEVELOPER\t\(.author.name // "")",
      "CATEGORY\t\(if (.genre | type) == "array" then (.genre | join(", ")) else (.genre // .applicationCategory // "") end)",
      "RATING\t\(if .aggregateRating then "\(.aggregateRating.ratingValue) (\(.aggregateRating.reviewCount // .aggregateRating.ratingCount // "?") ratings)" else "" end)",
      "PRICE\t\(.offers.price // "" | tostring) \(.offers.priceCurrency // "")"
    ' 2>/dev/null | while IFS= read -r l; do printf '%s\t%s\n' "${l%%	*}" "$(printf '%s' "${l#*	}" | clean_line 200)"; done
  else
    warn "no app metadata found on the page"
  fi
  json=$(script_content "$BODY_FILE" 'serialized-server-data')
  rm -f "$BODY_FILE"
  if [ -n "$json" ]; then
    printf '%s' "$json" | jq -r '
      [.. | objects | select(."$kind" == "Shelf" and ((.id // "") | tostring | startswith("product_media_")))]
      | .[] | (.id | sub("^product_media_"; "") | sub("_$"; "") | if . == "pad" then "ipad" elif . == "phone" then "iphone" else . end) as $dev
      | [.items[]? | .screenshot? | select(. != null)] | to_entries[]
      | .value as $s
      | "SHOT\t\($dev)\t\(.key + 1)\t\($s.template | gsub("\\{w\\}"; ($s.width // 2000 | tostring)) | gsub("\\{h\\}"; ($s.height // 2000 | tostring)) | gsub("\\{c\\}"; "bb") | gsub("\\{f\\}"; "png"))"
    ' 2>/dev/null || warn "screenshot data on the page has an unexpected shape"
  else
    warn "no screenshot data found on the page; open the listing in a browser instead"
  fi
}

cmd_play() {
  [ $# -eq 1 ] || usage_die "usage: fp.sh play <play.google.com listing URL | package name>"
  local target=$1 ld pkg
  case $target in
    https://play.google.com/store/apps/details\?*) ;;
    http*) usage_die "play takes an https://play.google.com/store/apps/details?id=... URL or a package name" ;;
    *)
      case $target in *[!A-Za-z0-9._]*) usage_die "not a package name: $target" ;; esac
      target="https://play.google.com/store/apps/details?id=$target&hl=en_US&gl=US" ;;
  esac
  pkg=${target#*id=}; pkg=${pkg%%&*}
  polite_get "$target"
  printf 'URL\t%s\n' "$FINAL_URL"
  ld=$(script_content "$BODY_FILE" 'application/ld+json')
  if [ -n "$ld" ]; then
    printf '%s' "$ld" | jq -r '
      "NAME\t\(.name // "")",
      "DEVELOPER\t\(.author.name // "")",
      "CATEGORY\t\(.applicationCategory // "")",
      "RATING\t\(if .aggregateRating then "\(.aggregateRating.ratingValue) (\(.aggregateRating.ratingCount // "?") ratings)" else "" end)"
    ' 2>/dev/null | while IFS= read -r l; do printf '%s\t%s\n' "${l%%	*}" "$(printf '%s' "${l#*	}" | clean_line 200)"; done
  else
    warn "no app metadata found on the page"
  fi
  printf 'PACKAGE\t%s\n' "$pkg"
  grep -o '<img[^>]*data-screenshot-index="[0-9]*"[^>]*>' "$BODY_FILE" |
    sed -n 's/.*src="\([^"]*\)".*data-screenshot-index="\([0-9]*\)".*/\2	\1/p' |
    sort -n -u -k1,1 | awk -F '\t' '{ u = $2; sub(/=w[0-9]+-h[0-9]+.*$/, "=w2048", u); printf "SHOT\tandroid\t%d\t%s\n", $1 + 1, u }'
  rm -f "$BODY_FILE"
}

find_chrome() {
  local p
  if [ -n "${FP_CHROME:-}" ]; then
    [ -x "$FP_CHROME" ] || die "FP_CHROME is not executable: $FP_CHROME"
    printf '%s' "$FP_CHROME"; return 0
  fi
  for p in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
           "/Applications/Chromium.app/Contents/MacOS/Chromium" \
           "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
           "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"; do
    [ -x "$p" ] && { printf '%s' "$p"; return 0; }
  done
  for p in google-chrome google-chrome-stable chromium chromium-browser microsoft-edge brave-browser; do
    command -v "$p" >/dev/null 2>&1 && { command -v "$p"; return 0; }
  done
  return 1
}

cmd_shot() {
  local url= out= size=1440,900 chrome profile pid waited=0
  while [ $# -gt 0 ]; do
    case $1 in
      --mobile) size=390,844; shift ;;
      --size) [ $# -ge 2 ] || usage_die "--size needs WIDTHxHEIGHT"
              case $2 in [0-9]*x[0-9]*) size=${2%x*},${2#*x} ;; *) usage_die "--size takes WIDTHxHEIGHT, e.g. 1280x800" ;; esac
              shift 2 ;;
      -*) usage_die "unknown option: $1" ;;
      *) if [ -z "$url" ]; then url=$1; elif [ -z "$out" ]; then out=$1; else usage_die "usage: fp.sh shot <url> <out.png> [--mobile|--size WxH]"; fi; shift ;;
    esac
  done
  [ -n "$url" ] && [ -n "$out" ] || usage_die "usage: fp.sh shot <url> <out.png> [--mobile|--size WxH]"
  case $out in *.png) ;; *) usage_die "the screenshot file must end in .png" ;; esac
  [ -d "$(dirname -- "$out")" ] || die "directory does not exist: $(dirname -- "$out")"
  chrome=$(find_chrome) || die "no Chrome-family browser found; set FP_CHROME to its executable, or use your agent's own browser tool"
  parse_url "$url"
  require_allowed
  wait_turn "$HOST" "$CRAWL_DELAY"
  profile=$(mktemp -d "${TMPDIR:-/tmp}/fp-chrome.XXXXXX") || die "cannot create a temporary profile"
  rm -f "$out"
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --no-first-run --no-default-browser-check \
    --disable-extensions --mute-audio --user-data-dir="$profile" --window-size="$size" \
    --virtual-time-budget=8000 --screenshot="$out" "$URL_CLEAN" >/dev/null 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$FP_SHOT_TIMEOUT" ]; then kill "$pid" 2>/dev/null; break; fi
    sleep 1; waited=$((waited + 1))
  done
  wait "$pid" 2>/dev/null
  rm -rf "$profile"
  [ -s "$out" ] || die "the browser produced no screenshot for $URL_CLEAN"
  printf 'SHOT\t%s\t%s\t%s\n' "$out" "${size%,*}x${size#*,}" "$URL_CLEAN"
}

slugify() {
  printf '%s' "$1" | tr 'A-Z' 'a-z' | LC_ALL=C sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-60
}

cmd_report() {
  local sub=${1:-}
  [ $# -gt 0 ] && shift
  case $sub in
    init) report_init "$@" ;;
    check) report_check "$@" ;;
    *) usage_die "usage: fp.sh report init <feature> [parent-dir] | fp.sh report check <report-dir>" ;;
  esac
}

report_init() {
  [ $# -ge 1 ] && [ $# -le 2 ] || usage_die "usage: fp.sh report init <feature> [parent-dir]"
  local feature=$1 parent=${2:-feature-patterns} slug dir tpl today
  feature=$(printf '%s' "$feature" | clean_line 120)
  slug=$(slugify "$feature")
  [ -n "$slug" ] || usage_die "the feature name needs at least one letter or digit"
  dir=$parent/$slug
  [ -e "$dir/report.md" ] && die "$dir/report.md already exists; pick another name or remove it"
  tpl=$FP_DIR/references/report-template.md
  [ -f "$tpl" ] || die "template not found: $tpl"
  mkdir -p "$dir/shots" || die "cannot create $dir"
  today=$(date +%Y-%m-%d)
  # Literal replacement: gsub() would treat "&" in the feature name as the match.
  FEATURE=$feature TODAY=$today awk '
    function rep(s, from, to,   i, out) {
      out = ""
      while ((i = index(s, from)) > 0) { out = out substr(s, 1, i - 1) to; s = substr(s, i + length(from)) }
      return out s
    }
    { print rep(rep($0, "{{FEATURE}}", ENVIRON["FEATURE"]), "{{DATE}}", ENVIRON["TODAY"]) }
  ' "$tpl" > "$dir/report.md"
  [ -f "$dir/sources.tsv" ] || printf 'id\turl\tkind\tretrieved\tnote\n' > "$dir/sources.tsv"
  printf 'REPORT\t%s\n' "$dir/report.md"
  printf 'SOURCES\t%s\n' "$dir/sources.tsv"
  printf 'SHOTS\t%s\n' "$dir/shots"
}

SOURCE_KINDS="help-center marketing web-app app-store play-store design-system changelog article video screenshot other"

cmd_source() {
  [ "${1:-}" = add ] || usage_die "usage: fp.sh source add <report-dir> <url> <kind> [note]"
  shift
  [ $# -ge 3 ] && [ $# -le 4 ] || usage_die "usage: fp.sh source add <report-dir> <url> <kind> [note]"
  local dir=$1 url=$2 kind=$3 note=${4:-} file existing next k ok=
  file=$dir/sources.tsv
  [ -f "$file" ] || die "no sources.tsv in $dir; run 'fp.sh report init' first"
  for k in $SOURCE_KINDS; do [ "$k" = "$kind" ] && ok=1; done
  [ -n "$ok" ] || usage_die "kind must be one of: $SOURCE_KINDS"
  parse_url "$url"
  existing=$(awk -F '\t' -v u="$URL_CLEAN" 'NR > 1 && $2 == u { print $1; exit }' "$file")
  if [ -n "$existing" ]; then printf '%s\t%s\t(already recorded)\n' "$existing" "$URL_CLEAN"; return 0; fi
  next=$(awk -F '\t' 'NR > 1 { n = substr($1, 2) + 0; if (n > m) m = n } END { print "S" (m + 1) }' "$file")
  note=$(printf '%s' "$note" | clean_line 200)
  printf '%s\t%s\t%s\t%s\t%s\n' "$next" "$URL_CLEAN" "$kind" "$(date +%Y-%m-%d)" "$note" >> "$file"
  printf '%s\t%s\n' "$next" "$URL_CLEAN"
}

report_check() {
  [ $# -eq 1 ] || usage_die "usage: fp.sh report check <report-dir>"
  local dir=$1 report sources body cited known missing unused shots_missing placeholders status=0 id s
  report=$dir/report.md; sources=$dir/sources.tsv
  [ -f "$report" ] || die "no report.md in $dir"
  [ -f "$sources" ] || die "no sources.tsv in $dir"
  # HTML comments are template guidance, not content: drop them before checking.
  body=$(awk '{
      line = $0; out = ""
      while (line != "") {
        if (inc) { i = index(line, "-->"); if (!i) { line = ""; break } line = substr(line, i + 3); inc = 0 }
        else { i = index(line, "<!--"); if (!i) { out = out line; line = "" } else { out = out substr(line, 1, i - 1); line = substr(line, i + 4); inc = 1 } }
      }
      print out
    }' "$report")
  cited=$(printf '%s\n' "$body" | grep -o '\[S[0-9][0-9]*\]' | tr -d '[]' | sort -u)
  known=$(awk -F '\t' 'NR > 1 && $1 != "" { print $1 }' "$sources" | sort -u)
  missing=$(printf '%s\n' "$cited" | grep -v '^$' | while read -r id; do printf '%s\n' "$known" | grep -qx "$id" || printf '%s ' "$id"; done)
  unused=$(printf '%s\n' "$known" | grep -v '^$' | while read -r id; do printf '%s\n' "$cited" | grep -qx "$id" || printf '%s ' "$id"; done)
  shots_missing=$(printf '%s\n' "$body" | grep -o '(shots/[^)]*)' | tr -d '()' | sort -u | while read -r s; do [ -f "$dir/$s" ] || printf '%s ' "$s"; done)
  placeholders=$(grep -c -E '\{\{|<!-- TODO' "$report" || true)
  printf 'CITED\t%s\n' "$(printf '%s\n' "$cited" | grep -c .)"
  printf 'SOURCES\t%s\n' "$(printf '%s\n' "$known" | grep -c .)"
  if [ -n "$missing" ]; then printf 'MISSING\t%s\n' "${missing% }"; status=1; fi
  if [ -n "$shots_missing" ]; then printf 'MISSING_SHOT\t%s\n' "${shots_missing% }"; status=1; fi
  if [ -z "$cited" ]; then printf 'NO_CITATIONS\n'; status=1; fi
  if [ "$placeholders" -gt 0 ]; then printf 'PLACEHOLDERS\t%s\n' "$placeholders"; status=1; fi
  [ -n "$unused" ] && printf 'UNUSED\t%s\n' "${unused% }"
  if [ "$status" -eq 0 ]; then printf 'OK\n'; else printf 'FAIL\n'; fi
  return "$status"
}

cmd_help() {
  cat <<EOF
fp.sh $FP_VERSION - public-source research helper for the feature-patterns skill

  fp.sh robots <url>                      ALLOW or DISALLOW for this URL under robots.txt
  fp.sh fetch <url> [--text] [-o file]    polite GET; prints title, description, og:image, headings,
                                          and with --text the readable text of the page
  fp.sh appstore <listing-url | app-id>   App Store listing: name, developer, category, screenshot URLs
  fp.sh play <listing-url | package>      Google Play listing: name, developer, category, screenshot URLs
  fp.sh shot <url> <out.png> [--mobile | --size WxH]
                                          screenshot of a public page with a local headless Chrome
  fp.sh report init <feature> [parent]    scaffold <parent>/<slug>/report.md, sources.tsv, shots/
  fp.sh source add <dir> <url> <kind> [note]
                                          record a source, prints its id (S1, S2, ...)
  fp.sh report check <dir>                every [S#] cited exists, every shots/ link exists
  fp.sh version

Source kinds: $SOURCE_KINDS
Every request checks robots.txt for the "$FP_ROBOTS_TOKEN" token and waits at least
FP_MIN_INTERVAL=${FP_MIN_INTERVAL}s between requests to the same host.
Exit codes: 0 ok, 1 error, 2 usage, 3 refused by robots.txt or by policy.
EOF
}

main() {
  local cmd=${1:-help}
  [ $# -gt 0 ] && shift
  case $cmd in
    robots|fetch|appstore|play|shot) need curl ;;
  esac
  case $cmd in appstore|play) need jq ;; esac
  case $cmd in
    robots) cmd_robots "$@" ;;
    fetch) cmd_fetch "$@" ;;
    appstore) cmd_appstore "$@" ;;
    play) cmd_play "$@" ;;
    shot) cmd_shot "$@" ;;
    report) cmd_report "$@" ;;
    source) cmd_source "$@" ;;
    version|--version|-v) printf 'fp.sh %s\n' "$FP_VERSION" ;;
    help|--help|-h) cmd_help ;;
    *) usage_die "unknown command: $cmd" ;;
  esac
}

main "$@"
