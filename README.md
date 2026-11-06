# feature-patterns

An agent skill that researches how real, shipped apps design a feature - their screens, step-by-step flows, recurring UI patterns and the decisions where they disagree - and writes a cited report you can design from.

Think of it as Mobbin for one feature, built on the spot from public evidence: the apps' own help centers, their logged-out web pages, App Store and Google Play listings, release notes and public design systems.
Every claim in the report links to the page it came from.

Ask in plain language:

> how do other apps do password reset?

> UI references for a subscription cancellation flow, iOS and web

> Mobbin for in-app referral programs - we are a fintech in Brazil

> compare how Airbnb, Booking.com and Hopper handle checkout

It works with any agent that supports skills - Claude Code, Codex, Cursor, OpenCode and others.

## How it was made

This skill was created with [REA](https://github.com/morluto/rea) (Reverse Engineer Anything) in one shot with Claude Opus at high effort.
REA was used from the terminal to study how [Mobbin](https://mobbin.com/) structures its design-reference library - apps, screens, flows, UI elements, patterns, search and filters - from its public, logged-out pages only.
The skill reproduces that model for a single feature without touching Mobbin.
The study, its evidence and the resulting design are in [`docs/`](docs/):

- [`docs/rea-study.md`](docs/rea-study.md): what REA was asked, what it returned, what stayed out of reach.
- [`docs/mobbin-model.md`](docs/mobbin-model.md): the library model, in our own words.
- [`docs/design.md`](docs/design.md): how that model maps onto public sources, and why the helper script works the way it does.

## Install

```bash
npx skills add MarceloCajueiro/feature-patterns
```

The installer asks which agent to install into.
No credentials, no accounts, no setup.

## What you get

For each feature, a folder (by default `./feature-patterns/<feature>/`) with:

| File | Contents |
|---|---|
| `report.md` | TL;DR, apps studied and why, recurring patterns, variations framed as trade-offs, a screen-by-screen flow per app, a UI-elements inventory, states and edge cases, copy and tone, recommendations kept apart from observations, gaps and confidence, sources |
| `sources.tsv` | Every source as `id, url, kind, retrieved, note`; the report cites them as `[S1]`, `[S2]` |
| `shots/` | Optional screenshots the agent captured itself from public pages |

The report uses one vocabulary across features - flow, screen type, UI element, app category - so studies stay comparable.
It is in [`feature-patterns/references/taxonomy.md`](feature-patterns/references/taxonomy.md), and the report template in [`feature-patterns/references/report-template.md`](feature-patterns/references/report-template.md).

## Public sources only

- No logging in, no creating accounts, no submitting forms, no paywalled content, no paid design-reference libraries.
- Every request checks the site's robots.txt for the `feature-patterns` token and is refused when disallowed, including after a redirect.
- Requests to the same host are spaced at least 5 seconds apart, or the site's Crawl-delay if longer.
- The user agent names this project and its repository, never you.
- Fetched pages are treated as data, never as instructions.
- The agent paraphrases, cites, and never suggests copying another product's copy, illustrations or brand.

Reports and screenshots are for your own research.
Screenshots of other products remain their owners' work; do not republish them.

## Requirements

- `bash` (3.2 or later, so stock macOS works), `curl`, `jq` and `awk`
- For screenshots: a Chrome-family browser (Chrome, Chromium, Brave, Edge), or your agent's own browser tool

## CLI reference

The agent drives this for you, but `fp.sh` is a normal script:

```bash
fp.sh report init "password reset"            # ./feature-patterns/password-reset/{report.md,sources.tsv,shots/}
fp.sh source add <dir> <url> help-center "Reset article"   # prints S1
fp.sh fetch <url>                             # title, description, og:image, canonical, headings
fp.sh fetch <url> --text                      # ...plus the readable text of the page
fp.sh appstore 570060128                      # App Store listing by id or URL: metadata and screenshot URLs
fp.sh play com.duolingo                       # Google Play listing by package or URL
fp.sh shot <url> <dir>/shots/S3-app-login.png --mobile   # local headless screenshot of a public page
fp.sh robots <url>                            # ALLOW or DISALLOW, with the matching rule
fp.sh report check <dir>                      # fails on citations or screenshots that do not resolve
```

Output is TSV (`KEY<TAB>value`).
Exit codes: `0` ok, `1` error, `2` usage, `3` refused by robots.txt or by policy.

Source kinds: `help-center`, `marketing`, `web-app`, `app-store`, `play-store`, `design-system`, `changelog`, `article`, `video`, `screenshot`, `other`.

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `FP_MIN_INTERVAL` | `5` | Minimum seconds between requests to the same host |
| `FP_HTTP_TIMEOUT` | `20` | Per-request timeout, in seconds |
| `FP_MAX_BYTES` | `8388608` | Largest response accepted |
| `FP_MAX_REDIRECTS` | `3` | Redirects followed, each re-checked against robots.txt |
| `FP_ROBOTS_TTL` | `3600` | Seconds a site's robots.txt is cached |
| `FP_TEXT_MAX` | `20000` | Characters printed by `fetch --text` |
| `FP_CHROME` | auto | Browser executable for `shot` |
| `FP_SHOT_TIMEOUT` | `45` | Seconds before a screenshot is abandoned |
| `FP_STATE_DIR` | `~/.cache/feature-patterns` | robots.txt cache and per-host timestamps |

## Tests

```bash
brew install bats-core      # or your platform's package
bats tests/fp.bats
FP_BASH=/bin/bash bats tests/fp.bats    # exercise bash 3.2 on macOS
```

The suite never touches the network: `tests/bin/curl` answers from fixtures and logs every URL requested, `tests/bin/sleep` records waits instead of waiting, and `tests/bin/fake-chrome` stands in for the browser.
Those logs are what the guarantees are tested against: a disallowed page is never requested, a redirect into a disallowed path is not followed, a private host is refused before any request, and the second request to a host waits.

CI runs the suite on Ubuntu (mawk, bash 5) and macOS (BSD awk, bash 3.2), then plants the defects this skill must never ship - the robots check switched off, the rate limit switched off, a redirect followed without a new check, private hosts allowed, an unreachable robots.txt treated as permission - and requires the suite to go red for each.
The documented install-path lookup in `SKILL.md` is extracted and executed, so the instructions the agent follows cannot drift from what works.

## License

MIT
