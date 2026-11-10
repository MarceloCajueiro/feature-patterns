# REA study of Mobbin

This is the evidence behind the skill's design: how [REA](https://github.com/morluto/rea) was used to study how [Mobbin](https://mobbin.com/) organizes its design-reference library, what each step returned, and what stayed out of reach.
It records structure and behavior only.
No Mobbin screenshots, copy or catalog data are reproduced here, and the raw REA Evidence JSON (which contains page text and script metadata) was kept out of the repository.

## Ground rules for the study

- Only public, logged-out pages and public front-end behavior.
- No login, no signup, no paywall workaround, no bulk download of screenshots or catalog entries.
- Five page loads in a browser and five plain HTTP requests in total, several seconds apart.
- REA ran from the terminal only, from a scratch directory outside the repository.
  `npx rea-agents setup` was never run and no agent configuration was changed.

## Setup

| Item | Value |
|---|---|
| Date | 2026-11-06 |
| REA | `rea-agents` 6.8.0, installed with `npm install` into a scratch directory |
| Node.js | 26.13.0, a portable build from nodejs.org verified against `SHASUMS256.txt` (REA needs 22.23.4+, 24.22.1+ or 26.12.1+) |
| Browser | Google Chrome 156, headless, started with `--remote-debugging-port` and a throwaway `--user-data-dir` |
| Navigation | `chrome-devtools-axi` attached to that browser; REA attached passively to the same page |

REA's website tools attach to a browser you start yourself and observe the page that is already open; they do not navigate.
So each step was: navigate with the browser tool, wait, then run REA against the open target.

```bash
rea list-browser-targets http://127.0.0.1:9333 --allowed-origins https://mobbin.com --json
rea analyze-web-bundle   http://127.0.0.1:9333 <target> --json
rea inspect-web-page     http://127.0.0.1:9333 <target> --observation-ms 1500 \
    --include-accessibility-text --include-json-body-shapes --json
```

## What was requested, in order

| # | Request | Tool | Evidence ID |
|---|---|---|---|
| 1 | `/robots.txt` | curl | - |
| 2 | `/llms.txt` | curl | - |
| 3 | `/sitemap.xml` | curl | - |
| 4 | Home page | browser + `list_browser_targets` | `ev_def0243194444d1679af8d25ab0303cc8b25828c62eac7cbb7937efb87904ae7` |
| 5 | Home page bundle | `analyze_web_bundle` | `ev_9413d36ce6ed00dbfbffb56463f36389a45a325ffe74573bd3fb96168375d8fb` |
| 6 | Screens index for mobile | browser + `inspect_web_page` | `ev_e20101b04febcca757bf21682e71a765e1d6da726a8d506fb4328cfe1a75339e` |
| 7 | Library app bundle, same page | `analyze_web_bundle` | `ev_fbde2bf0016cf0e8c33beb31bc2bc2e633c4c932d40dfe213198c2863ecd62d1` |
| 8 | One flow category page (onboarding, mobile) | browser snapshot | - |
| 9 | One flow detail page | browser + `inspect_web_page` | `ev_bdf52c34388ac17cb445fd7cde502c92e48849ff9fd35e59974268ca3d8d54d2` |
| 10 | Mobile explore index | browser snapshot | - |
| 11 | Public API description (`docs.mobbin.com/openapi.json`) | curl | - |
| 12 | `/mcp.md` (agent-facing description of Mobbin's MCP tools) | curl | - |

## Findings

### robots.txt and agent-facing files

- The wildcard group allows everything; a separate group for one AI crawler allows only a list of Markdown pages, the blog and `llms.txt`.
  The study stayed with the human-facing pages a logged-out visitor sees, plus those Markdown pages.
- `llms.txt` describes the product for agents and points to three kinds of search: individual screens, ordered flows, and website sections.
  It also states two principles the skill adopts directly: a recurring pattern is a convention, not proof of effectiveness, and observations should be kept apart from recommendations.
- Programmatic access (an MCP server and a REST API) exists only on paid plans, behind OAuth or workspace keys.

### The sitemap is the taxonomy

The sitemap lists 3,345 URLs.
Grouping them by path template shows the library's facets directly:

| Path family | URLs | Facet |
|---|---|---|
| `/explore/{mobile,web}/app-categories/*` | 101 | App category |
| `/explore/{mobile,web}/flows/*` | 155 | Flow type |
| `/explore/{mobile,web}/screens/*` | 437 | Screen type |
| `/explore/{mobile,web}/ui-elements/*` | 171 | UI element |
| `/explore/sites/sections/*` | 209 | Website section |
| `/explore/sites/styles/*` | 119 | Visual style |
| `/explore/sites/categories/*` | 438 | Website category |
| `/glossary/*` | 59 | Definitions of UI element terms |
| `/colors/*` | 1,561 | Color pages (brand and meaning) |

Two observations about the slugs:

- Flows are named as verbs in the gerund (creating an account, resetting a password, cancelling a subscription), screens as nouns (paywall, empty state, order confirmation), UI elements as component names (bottom sheet, stepper, toast).
  The skill's vocabulary in `feature-patterns/references/taxonomy.md` follows the same grammar.
- Many category slugs read like search-engine landing pages rather than curated taxonomy terms, so the sitemap mixes the core facets with marketing pages.

### Two front-end applications

`analyze_web_bundle` fingerprinted both pages as Next.js with webpack (high confidence).
The marketing home page loads its scripts from a separate base path (`/mobbin-marketing-pages`), while the library pages load from the root `/_next/` path: two applications behind one domain.

In the library bundle (59 scripts parsed), the route inventory held 19 route patterns, all account and commerce routes (login, signup, pricing, settings for account, billing, team and MCP, team invite).
The browsing routes themselves did not appear as static literals, which is consistent with file-system routing on the server.

Low-confidence endpoint candidates in the same bundle include query-parameter names that reveal the search model: a free-text query, sort, filter, mode, a flow identifier, a video toggle, and a parameter for searching the text that appears inside screenshots.
REA flags these as unverified candidates; they say which dimensions exist, not how they are implemented.

### What a logged-out visitor can see

- **Explore index** per platform: three ways in (screens, UI elements, flows), curated collections and trending UI elements.
- **Screens index**: screen types grouped under a dozen headings (account management, actions, commerce and finance, communication, content, data, new user experience, social, user collections, utility and two catch-alls), each with a count of screens.
- **Flow category page**: a paginated list of flows.
  Each flow card is an ordered carousel of screenshots, the app it comes from, a one-sentence summary of what the flow does, and tag chips from three facets at once: related flow types, screen types and UI elements.
  After about a dozen flows the page asks the visitor to log in to keep browsing.
- **Flow detail page**: the full ordered sequence of screens for one flow on one app and platform.
  Saving, copying and the link to the app's own page all lead to signup.
- **App pages** are not reachable without an account.

### The public API description

The OpenAPI document describes one endpoint, a screen search.
It takes a natural-language description of the screen, a platform (iOS or web), a mode (fast, standard, or an AI-assisted deep mode) and a limit.
A result is a screen with an image, the app name, the platform and a link back to the library.

The agent-facing MCP description adds flow search ("when sequence and context matter") and website-section search, and recommends comparing several products while keeping each product's name and link.

## What REA could not see

- Network traffic during page load: REA attaches to an already-open page, so requests made before it attached are outside its window (`attach_limited`), and it filtered several sections by policy.
- One script exceeded REA's 30-second per-script analysis deadline, so its findings are unknown.
- Everything behind login: app pages, saved collections, full pagination and the search interface itself.
  These were not attempted.

## How this shaped the skill

See [design.md](design.md).
