# How a design-reference library is organized

A summary, in our own words, of the library model observed in the [REA study](rea-study.md).
It is the model the skill reproduces for a single feature, from public sources.

## Entities

- **App**: a shipped product on one platform (iOS, Android, web app) or a marketing website.
  It belongs to one or more app categories.
- **Screen**: one captured state of an app's interface.
  It has one screen type and carries several UI-element tags.
- **Flow**: an ordered sequence of screens from one app that accomplishes one user job.
  It has a flow type, a short written summary, and inherits the screen-type and UI-element tags of its screens.
- **Website section**: one block of a marketing page (hero, pricing table, footer), tagged with a section type and visual styles.
- **Pattern**: not stored as an entity.
  It emerges when the same combination of flow, screen types and elements recurs across apps.

## Facets

The library is browsed through five independent facets, each a flat list of terms with its own grammar:

| Facet | Grammar | Examples |
|---|---|---|
| Platform | proper noun | iOS, web |
| App category | noun | finance, travel, productivity |
| Flow type | gerund verb phrase | creating an account, checking out |
| Screen type | noun | paywall, empty state, settings |
| UI element | component name | bottom sheet, toast, segmented control |

Terms are grouped for display (screen types sit under headings like account management or commerce) but tagging is many-to-many: one flow card shows chips from three facets at once.

## Search

- Free-text search over screens, with a mode for searching the text visible inside screenshots.
- Filters by facet, sorting, and a separate flow search for questions where order matters.
- A natural-language screen search for agents, returning the image, the app, the platform and a link back.

## Principles worth keeping

- Show real, shipped products rather than concepts.
- Keep every example tied to the product it came from and a link to see it.
- Prefer flows over isolated screens when the order of steps is the point.
- A pattern that many products share is a convention, not evidence that it works better.
- Keep visible observations separate from recommendations.

## What the skill does differently

A library like this owns a large, curated catalog of screenshots and keeps it behind an account.
The skill owns no catalog.
For each request it assembles a small, fresh, cited study of one feature from what the products themselves publish, and it never draws on a paid library.
