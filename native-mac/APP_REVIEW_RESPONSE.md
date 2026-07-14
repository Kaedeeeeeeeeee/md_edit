# App Review response — Notation 1.0 (2)

Prepared for the July 13, 2026 review of submission
`cafb369c-0e8e-4377-b8b9-0f831691be3a`.

Do not commit an API key to this file. Add the dedicated review-only key only
inside App Store Connect immediately before resubmission, then revoke it after
review.

## Reply to App Review

Hello App Review,

Thank you for the detailed review. We have addressed all three items.

### Guideline 5 — China mainland availability

We removed China mainland from the app's availability. Notation 1.0 will not
be offered on the China mainland App Store. The app remains available only in
storefronts where its optional third-party generative-AI integrations may be
distributed.

We also revised the App Store description and promotional text so they explain
the optional bring-your-own-key capability without naming an AI provider.

### Guideline 4.3(a) — distinct product and implementation

Notation is not a repackaged app template and we have not submitted multiple
variants of it. It is a macOS-first Markdown workspace that directly reads and
writes the user's real `.md` files.

We use BlockNote as an open-source editing engine. The rest of the product is a
project-specific native implementation, including:

- a SwiftUI/AppKit workspace shell and recursive disk-backed file tree;
- App Sandbox security-scoped bookmarks for persistent folder access;
- direct Markdown file round-tripping, a source-editing mode, and external file
  change monitoring;
- custom math-block Markdown round-tripping for `$$ ... $$`;
- Finder single-file opening as a fallback to the workspace workflow;
- native macOS menus, window restoration, dirty-document handling, and
  macOS 15–26 visual fallbacks;
- a fully bundled editor loaded through a custom WebKit URL scheme, with no
  remote editor code or private document database.

We removed competitor-comparison language from the App Store metadata and the
product website so the listing now describes Notation on its own merits.

### Guideline 2.1 — review access

No Notation account or sign-in is required. All editing features work with
local files without an API key.

For AI testing, please use the dedicated review-only Anthropic API key supplied
in the App Review Notes field. Test steps:

1. Launch Notation and choose "Open Folder" or "Open File".
2. Open Notation > Settings > AI.
3. Choose "Anthropic Claude", paste the review key, and click "Save Key".
4. Return to the document and press Command-Shift-J to open AI Assistant.
5. Enter "Summarize this document" and press Command-Enter.

The request is sent directly from the Mac to Anthropic. Notation does not proxy
the request, operate an AI server, or receive the API key.

Thank you for reviewing the updated submission.

## App Review Notes template

Notation is a paid-upfront macOS app with no account, subscription, or in-app
purchase. Core editing works offline with local Markdown files.

China mainland has been removed from App Availability for this version.

AI review steps: open a local file, then go to Notation > Settings > AI, select
Anthropic Claude, paste the review-only key below, and click Save Key. Return to
the document, press Command-Shift-J, ask "Summarize this document", and press
Command-Enter.

Review-only Anthropic API key: [ADD IN APP STORE CONNECT — NEVER COMMIT]

Notation uses BlockNote only as its open-source editing engine. Its native
workspace, real-file storage, security-scoped bookmarks, Markdown source mode,
math round-trip, external-change handling, Finder opening, and macOS window/menu
lifecycle are original product-specific implementations.
