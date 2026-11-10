#!/usr/bin/env bats
# Tests for feature-patterns/fp.sh. Nothing here touches the network:
# tests/bin/curl answers from tests/fixtures and logs every URL it is asked for,
# tests/bin/sleep records waits instead of waiting, and tests/bin/fake-chrome
# stands in for the browser.

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  FP=${FP:-$ROOT/feature-patterns/fp.sh}
  SKILL_MD=${SKILL_MD:-$ROOT/feature-patterns/SKILL.md}
  FP_BASH=${FP_BASH:-bash}
  export PATH="$BATS_TEST_DIRNAME/bin:$PATH"
  export FP_FIXTURES="$BATS_TEST_DIRNAME/fixtures"
  export FP_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export FP_CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  export FP_SLEEP_LOG="$BATS_TEST_TMPDIR/sleep.log"
  export FP_CHROME_LOG="$BATS_TEST_TMPDIR/chrome.log"
  export FP_MIN_INTERVAL=0
  : > "$FP_CURL_LOG"; : > "$FP_SLEEP_LOG"; : > "$FP_CHROME_LOG"
  unset FP_CHROME
}

fp() { "$FP_BASH" "$FP" "$@"; }

# ------------------------------------------------------------ robots.txt

@test "robots: a path under a Disallow rule is refused with exit 3" {
  run fp robots https://star.example/private/page
  [ "$status" -eq 3 ]
  [[ "$output" == *"DISALLOW"*"disallow: /private"* ]]
}

@test "robots: the longest matching rule wins, so a deeper Allow reopens a path" {
  run fp robots https://star.example/private/open/doc
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALLOW"*"allow: /private/open"* ]]
}

@test "robots: Allow wins a tie between rules of equal length" {
  run fp robots https://star.example/tie
  [ "$status" -eq 0 ]
  [[ "$output" == ALLOW* ]]
}

@test "robots: * and a final \$ work as wildcards" {
  run fp robots https://star.example/files/report.pdf
  [ "$status" -eq 3 ]
  run fp robots 'https://star.example/files/report.pdf?download=1'
  [ "$status" -eq 0 ]
}

@test "robots: the query string is part of the matched path" {
  run fp robots 'https://apps.apple.com/search?term=x'
  [ "$status" -eq 3 ]
}

@test "robots: Crawl-delay of the matching group is reported" {
  run fp robots https://star.example/article.html
  [ "$status" -eq 0 ]
  [[ "$output" == *$'CRAWL_DELAY\t7'* ]]
}

@test "robots: a group naming our token replaces the * group, case-insensitively" {
  run fp robots https://token.example/anything
  [ "$status" -eq 0 ]
  run fp robots https://token.example/no-fp/x
  [ "$status" -eq 3 ]
}

@test "robots: a missing robots.txt (404) allows everything" {
  run fp robots https://norobots.example/whatever
  [ "$status" -eq 0 ]
  [[ "$output" == ALLOW* ]]
}

@test "robots: an unreachable robots.txt (5xx) is treated as disallow" {
  run fp robots https://down.example/page
  [ "$status" -eq 3 ]
  [[ "$output" == *"unreachable"* ]]
}

@test "robots: robots.txt is fetched once per site and then read from cache" {
  fp robots https://star.example/a >/dev/null
  fp robots https://star.example/b >/dev/null
  [ "$(grep -c '^https://star.example/robots.txt$' "$FP_CURL_LOG")" -eq 1 ]
}

# ------------------------------------------------------------ the request gate

@test "fetch: a disallowed page is refused before any request for it is made" {
  run fp fetch https://star.example/private/secret
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSED"*"robots.txt disallows"* ]]
  ! grep -q 'private/secret' "$FP_CURL_LOG"
}

@test "fetch: a redirect into a disallowed path is refused, not followed" {
  run fp fetch https://hop.example/old
  [ "$status" -eq 3 ]
  ! grep -q '^https://star.example/private/page$' "$FP_CURL_LOG"
}

@test "fetch: an allowed relative redirect is followed after a robots check" {
  run fp fetch https://hop.example/moved
  [ "$status" -eq 0 ]
  [[ "$output" == *$'URL\thttps://hop.example/article.html'* ]]
  [[ "$output" == *$'TITLE\tMoved article'* ]]
}

@test "fetch: non-http URLs, credentials and private hosts are refused without a request" {
  for u in file:///etc/passwd ftp://star.example/x https://user:pw@star.example/ \
           http://localhost:8080/ http://127.0.0.1/ http://192.168.1.10/ http://10.0.0.2/ \
           http://172.20.0.1/ 'http://[::1]/' http://2130706433/ http://0x7f000001/ \
           http://0177.0.0.1/ http://8.8.8.8/ http://intranet/ http://printer.lan/; do
    run fp fetch "$u"
    [ "$status" -eq 3 ] || { echo "not refused: $u"; return 1; }
  done
  [ ! -s "$FP_CURL_LOG" ]
}

@test "robots: a robots.txt redirect to a non-public host is refused, not followed" {
  run fp robots https://evil.example/page
  [ "$status" -eq 3 ]
  [[ "$output" == *"non-public host"* ]]
  ! grep -q '169.254' "$FP_CURL_LOG"
}

@test "fetch: requests to the same host wait for FP_MIN_INTERVAL" {
  export FP_MIN_INTERVAL=5
  run fp fetch https://norobots-free.example/
  # robots.txt (404) then the page (404): the page request had to wait.
  grep -Eq '^[45]$' "$FP_SLEEP_LOG"
}

@test "fetch: a Crawl-delay longer than FP_MIN_INTERVAL is honored" {
  export FP_MIN_INTERVAL=1
  run fp fetch https://star.example/article.html
  [ "$status" -eq 0 ]
  grep -Eq '^[67]$' "$FP_SLEEP_LOG"
}

@test "fetch: different hosts do not wait for each other" {
  export FP_MIN_INTERVAL=5
  mkdir -p "$FP_STATE_DIR/hosts"
  date +%s > "$FP_STATE_DIR/hosts/other.example"
  run fp robots https://norobots.example/
  [ ! -s "$FP_SLEEP_LOG" ]
}

@test "fetch: summarizes title, description, og tags, canonical and headings, skipping scripts" {
  run fp fetch https://star.example/article.html
  [ "$status" -eq 0 ]
  [[ "$output" == *$'STATUS\t200'* ]]
  [[ "$output" == *$'TITLE\tReset your password & sign in'* ]]
  [[ "$output" == *$'DESCRIPTION\tHow to reset a forgotten password, step by step.'* ]]
  [[ "$output" == *$'OG_TITLE\tReset password'* ]]
  [[ "$output" == *$'OG_IMAGE\thttps://cdn.star.example/og.png'* ]]
  [[ "$output" == *$'CANONICAL\thttps://star.example/article.html'* ]]
  [[ "$output" == *$'H1\tReset your password'* ]]
  [[ "$output" == *$'H2\tOn the web'* ]]
  [[ "$output" != *"not a heading"* ]]
}

@test "fetch --text: prints readable text without scripts or styles" {
  run fp fetch --text https://star.example/article.html
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\nTEXT\n'* ]]
  [[ "$output" == *"- Open the login page"* ]]
  [[ "$output" == *"Tap Forgot password? on the login screen."* ]]
  [[ "$output" != *"var fake"* ]]
  [[ "$output" != *"color: red"* ]]
}

@test "fetch -o: saves the body" {
  run fp fetch https://star.example/article.html -o "$BATS_TEST_TMPDIR/page.html"
  [ "$status" -eq 0 ]
  grep -q 'Forgot password' "$BATS_TEST_TMPDIR/page.html"
}

@test "fetch: an HTTP error is reported as an error" {
  run fp fetch https://norobots.example/missing
  [ "$status" -eq 1 ]
  [[ "$output" == *"HTTP 404"* ]]
}

@test "the user agent names the project, never a person" {
  grep -q '^FP_UA="feature-patterns/' "$FP"
  ! grep -Eq '@[a-z0-9-]+\.(com|br|org)' "$FP"
}

# ------------------------------------------------------------ store listings

@test "appstore: reads metadata and screenshot URLs from a listing, following the id redirect" {
  run fp appstore 123456
  [ "$status" -eq 0 ]
  [[ "$output" == *$'URL\thttps://apps.apple.com/us/app/demo/id123456'* ]]
  [[ "$output" == *$'NAME\tDemo App'* ]]
  [[ "$output" == *$'DEVELOPER\tDemo Inc'* ]]
  [[ "$output" == *$'CATEGORY\tProductivity, Business'* ]]
  [[ "$output" == *$'RATING\t4.5 (1200 ratings)'* ]]
  [[ "$output" == *$'SHOT\tiphone\t1\thttps://img.example/a/one.jpg/1242x2688bb.png'* ]]
  [[ "$output" == *$'SHOT\tiphone\t2\thttps://img.example/a/two.jpg/2000x2000bb.png'* ]]
  [[ "$output" == *$'SHOT\tipad\t1\thttps://img.example/a/pad.jpg/2048x2732bb.png'* ]]
}

@test "appstore: refuses anything that is not an App Store listing" {
  run fp appstore https://star.example/app
  [ "$status" -eq 2 ]
  [ ! -s "$FP_CURL_LOG" ]
}

@test "play: reads metadata and ordered, de-duplicated screenshot URLs" {
  run fp play com.demo.app
  [ "$status" -eq 0 ]
  [[ "$output" == *$'NAME\tDemo App'* ]]
  [[ "$output" == *$'CATEGORY\tPRODUCTIVITY'* ]]
  [[ "$output" == *$'PACKAGE\tcom.demo.app'* ]]
  [[ "$output" == *$'SHOT\tandroid\t1\thttps://play-lh.example/first=w2048\nSHOT\tandroid\t2\thttps://play-lh.example/second=w2048'* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^SHOT')" -eq 2 ]
}

@test "play: refuses a package name with shell or URL characters" {
  run fp play 'com.demo;rm'
  [ "$status" -eq 2 ]
  [ ! -s "$FP_CURL_LOG" ]
}

# ------------------------------------------------------------ screenshots

@test "shot: a disallowed page is refused and the browser never starts" {
  export FP_CHROME="$BATS_TEST_DIRNAME/bin/fake-chrome"
  run fp shot https://star.example/private/x "$BATS_TEST_TMPDIR/x.png"
  [ "$status" -eq 3 ]
  [ ! -s "$FP_CHROME_LOG" ]
}

@test "shot: runs a headless browser with a throwaway profile and the mobile viewport" {
  export FP_CHROME="$BATS_TEST_DIRNAME/bin/fake-chrome"
  run fp shot https://star.example/article.html "$BATS_TEST_TMPDIR/a.png" --mobile
  [ "$status" -eq 0 ]
  [ -s "$BATS_TEST_TMPDIR/a.png" ]
  grep -q -- '--headless=new' "$FP_CHROME_LOG"
  grep -q -- '--window-size=390,844' "$FP_CHROME_LOG"
  grep -q -- "--screenshot=$BATS_TEST_TMPDIR/a.png" "$FP_CHROME_LOG"
  grep -q -- '--user-data-dir=' "$FP_CHROME_LOG"
  [[ "$output" == *$'SHOT\t'*$'\t390x844\thttps://star.example/article.html'* ]]
}

@test "shot: refuses a file name that is not .png and a missing browser" {
  run fp shot https://star.example/article.html "$BATS_TEST_TMPDIR/a.jpg"
  [ "$status" -eq 2 ]
  export FP_CHROME=/nonexistent/chrome
  run fp shot https://star.example/article.html "$BATS_TEST_TMPDIR/a.png"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FP_CHROME is not executable"* ]]
}

# ------------------------------------------------------------ report and sources

@test "report init: scaffolds report, sources and shots from the template" {
  cd "$BATS_TEST_TMPDIR"
  run fp report init "Checkout & Payment!"
  [ "$status" -eq 0 ]
  [ -f feature-patterns/checkout-payment/report.md ]
  [ -d feature-patterns/checkout-payment/shots ]
  [ "$(head -1 feature-patterns/checkout-payment/sources.tsv)" = $'id\turl\tkind\tretrieved\tnote' ]
  [ "$(head -1 feature-patterns/checkout-payment/report.md)" = "# Checkout & Payment!: how real apps do it" ]
  ! grep -q '{{' feature-patterns/checkout-payment/report.md
  grep -q "^Researched $(date +%Y-%m-%d) " feature-patterns/checkout-payment/report.md
}

@test "report init: every section of the template is present, and an existing report is not overwritten" {
  cd "$BATS_TEST_TMPDIR"
  fp report init "Search" research >/dev/null
  for s in "TL;DR" "Apps studied" "Patterns" "Variations and trade-offs" "Screen-by-screen flows" \
           "UI elements inventory" "States and edge cases" "Recommendations" "Gaps and confidence" "Sources"; do
    grep -q "^## $s\$" research/search/report.md || { echo "missing section: $s"; return 1; }
  done
  run fp report init "Search" research
  [ "$status" -eq 1 ]
}

@test "source add: numbers sources, de-duplicates URLs and validates the kind" {
  cd "$BATS_TEST_TMPDIR"
  fp report init "Login" >/dev/null
  d=feature-patterns/login
  run fp source add "$d" https://star.example/article.html help-center "Reset password article"
  [ "$output" = $'S1\thttps://star.example/article.html' ]
  run fp source add "$d" https://apps.apple.com/us/app/demo/id123456 app-store
  [[ "$output" == S2* ]]
  run fp source add "$d" https://star.example/article.html help-center
  [[ "$output" == S1*"already recorded"* ]]
  run fp source add "$d" https://star.example/x blog
  [ "$status" -eq 2 ]
  run fp source add "$d" file:///etc/passwd other
  [ "$status" -eq 3 ]
  [ "$(wc -l < "$d/sources.tsv" | tr -d ' ')" -eq 3 ]
  [ ! -s "$FP_CURL_LOG" ]
}

@test "report check: passes when every citation and screenshot resolves" {
  cd "$BATS_TEST_TMPDIR"
  fp report init "Login" >/dev/null
  d=feature-patterns/login
  fp source add "$d" https://star.example/a marketing >/dev/null
  fp source add "$d" https://star.example/b help-center >/dev/null
  printf 'shot' > "$d/shots/S2-login.png"
  printf '# Login\nUses a sheet [S1]. Steps [S2].\n![x](shots/S2-login.png)\n' > "$d/report.md"
  run fp report check "$d"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'CITED\t2'* ]]
  [[ "$output" == *OK ]]
}

@test "report check: fails on an unknown citation or a missing screenshot, flags leftovers" {
  cd "$BATS_TEST_TMPDIR"
  fp report init "Login" >/dev/null
  d=feature-patterns/login
  fp source add "$d" https://star.example/a marketing >/dev/null
  fp source add "$d" https://star.example/b marketing >/dev/null
  printf '# Login\nClaim [S1] and [S9].\n![x](shots/S1-gone.png)\n<!-- TODO: x -->\n' > "$d/report.md"
  run fp report check "$d"
  [ "$status" -eq 1 ]
  [[ "$output" == *$'MISSING\tS9'* ]]
  [[ "$output" == *$'MISSING_SHOT\tshots/S1-gone.png'* ]]
  [[ "$output" == *$'UNUSED\tS2'* ]]
  [[ "$output" == *$'PLACEHOLDERS\t1'* ]]
  [[ "$output" == *FAIL ]]
}

@test "report check: a report still holding template placeholders or no citations fails" {
  cd "$BATS_TEST_TMPDIR"
  fp report init "Login" >/dev/null
  run fp report check feature-patterns/login
  [ "$status" -eq 1 ]
  [[ "$output" == *NO_CITATIONS* ]]
  [[ "$output" == *PLACEHOLDERS* ]]
}

# ------------------------------------------------------------ the skill itself

@test "SKILL.md: frontmatter names the skill and carries the trigger phrases" {
  head -1 "$SKILL_MD" | grep -qx -- '---'
  grep -qx 'name: feature-patterns' "$SKILL_MD"
  desc=$(grep '^description:' "$SKILL_MD")
  for phrase in "how do other apps do <feature>" "UI references for <feature>" "Mobbin for <feature>"; do
    [[ "$desc" == *"$phrase"* ]] || { echo "missing trigger: $phrase"; return 1; }
  done
}

@test "SKILL.md: the documented install-path lookup finds an installed fp.sh" {
  block=$(awk '/^```bash$/ { b = ""; inb = 1; next } inb && /^```$/ { if (b ~ /FP=/ && b ~ /for p in/) { print b; exit } inb = 0; next } inb { b = b $0 "\n" }' "$SKILL_MD")
  [ -n "$block" ]
  home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$home/.agents/skills/feature-patterns"
  cp "$FP" "$home/.agents/skills/feature-patterns/fp.sh"
  cd "$BATS_TEST_TMPDIR"
  run env HOME="$home" bash -c "$block"$'\necho "$FP"'
  [ "$status" -eq 0 ]
  [ "$output" = "$home/.agents/skills/feature-patterns/fp.sh" ]
  rm -rf "$home/.agents"
  mkdir -p "$home"
  run env HOME="$home" bash -c "$block"
  [ "$status" -eq 1 ]
  [[ "$output" == *"npx skills add MarceloCajueiro/feature-patterns"* ]]
}

@test "SKILL.md: every fp.sh command it documents exists in the script" {
  for c in $(grep -oE '(^|`)fp\.sh [a-z]+' "$SKILL_MD" | awk '{ print $2 }' | sort -u); do
    grep -q "^    $c)" "$FP" || { echo "undocumented command in script: $c"; return 1; }
  done
}

@test "every file SKILL.md points to exists" {
  for f in $(grep -o 'references/[a-z-]*\.md' "$SKILL_MD" | sort -u); do
    [ -f "$ROOT/feature-patterns/$f" ] || { echo "missing: $f"; return 1; }
  done
}

@test "no em dash anywhere in the shipped files" {
  ! grep -rn $'\xe2\x80\x94' "$ROOT/feature-patterns" "$ROOT/README.md" "$ROOT/docs"
}
