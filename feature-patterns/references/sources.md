# Where to find evidence

Public sources only.
For each, the kind to record with `fp.sh source add`, what it shows well, and what it hides.
Check `fp.sh robots <url>` for anything you have not fetched yet; `fetch`, `shot`, `appstore` and `play` do it for you.

## Ranked by how close they are to the real product

| Kind | Where | Good for | Watch out for |
|---|---|---|---|
| `help-center` | The app's own support or help site, e.g. "<app> help <feature>" | Step-by-step flows with real screenshots, every option and edge case the product supports | May lag behind the shipped UI; check the article date |
| `web-app` | Logged-out pages of the product itself: signup, login, pricing, checkout start, public profiles, shared links | The real UI, current today; you can screenshot it | Stop at the login wall; never create accounts or submit forms |
| `app-store` | `https://apps.apple.com/...` listing, read with `fp.sh appstore` | Official screenshots of the key screens, category, rating | Marketing screenshots are staged and annotated, not a full flow |
| `play-store` | `https://play.google.com/store/apps/details?id=...`, read with `fp.sh play` | Same for Android; often different screenshots than iOS | Same staging caveat |
| `changelog` | Release notes, "what's new" pages, product blog posts announcing the feature | Why the feature exists and how it changed | Announcements describe intent, not final UI |
| `design-system` | Public design systems: Material Design, Apple Human Interface Guidelines, GOV.UK Design System, Shopify Polaris, Atlassian Design System, IBM Carbon, Salesforce Lightning | Researched guidance on the pattern itself, accessibility notes, do and don't | Guidance, not evidence of what a given app ships |
| `video` | The company's own walkthroughs and demos on its site or channel | Motion, transitions, full flows | Note the timestamp; do not download videos |
| `article` | Case studies by the company's designers, reputable UX publications | Rationale and results | Secondary source; corroborate before relying on it |
| `screenshot` | An image you captured yourself with `fp.sh shot` or your browser tool | Showing the exact state you describe | Record the page it came from as its own source too |

## How to pick the apps

- Start with the 2 or 3 products everyone in the category copies.
- Add 2 or 3 from adjacent categories that solve the same job differently.
- Add 1 smaller or newer product that does something unusual.
- If the user named their product or market (country, B2B, regulated industry), include at least one app from that context.
- Five or six apps is a good default; fewer than three is not a pattern study.

## Searching

Use the agent's web search tool to find help-center articles, listings and pages; then read them through `fp.sh fetch` or your own fetch tool.
Useful queries: `<app> help <feature>`, `<app> how to <job>`, `site:<app domain> <feature>`, `<app> <feature> redesign`, `<feature> pattern design system`.

## Off limits

- Anything behind a login, a paywall or a signup form, including paid design-reference libraries.
- Bulk downloads of a site's images or catalog, and any request robots.txt disallows.
- Bypassing rate limits, captchas, bot checks or regional blocks.
- Copying a product's copy, illustrations or brand assets into the user's product.
