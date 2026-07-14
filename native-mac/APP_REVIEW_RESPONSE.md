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

We would like to clarify that Notation does not include, bundle, proxy, or
resell access to ChatGPT or any other hosted AI service. It has no developer-
supplied AI account, API key, credits, or server-side AI backend. All editing
features work locally without AI.

The setting labelled "OpenAI / Compatible" identifies an interoperable HTTP
request and response format, not a required connection to OpenAI. The client is
implemented directly with URLSession. The user supplies all three connection
parameters: the API base URL, model identifier, and API key. Requests then go
directly from the user's Mac to the endpoint selected by that user.

This format is also implemented by independent providers and self-hosted
servers. For example, App Review can test the submitted binary against
DeepSeek's API by entering DeepSeek's own base URL, model, and review key. No
request in that test is sent to OpenAI or ChatGPT.

DeepSeek's official compatibility documentation:
https://api-docs.deepseek.com/

Accordingly, China mainland remains included in App Availability. The China
mainland storefront does not receive bundled access to OpenAI or ChatGPT; as in
every storefront, optional AI functionality remains inactive until a user
independently configures an endpoint and supplies credentials for that service.

We also revised the App Store description and promotional text so they explain
this optional bring-your-own-endpoint capability without associating Notation
with a particular AI brand.

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

For AI testing, please use the dedicated review-only DeepSeek API key supplied
in the App Review Notes field. Test steps:

1. Launch Notation and choose "Open Folder" or "Open File".
2. Open Notation > Settings > AI.
3. Choose "OpenAI / Compatible".
4. Set Base URL to `https://api.deepseek.com`.
5. Set Model to `deepseek-v4-flash`.
6. Paste the DeepSeek review key and click "Save Key".
7. Return to the document and press Command-Shift-J to open AI Assistant.
8. Enter "Summarize this document" and press Command-Enter.

The request is sent directly from the Mac to DeepSeek. Notation does not proxy
the request, operate an AI server, or receive the API key. The same submitted
binary can connect to other compatible endpoints when a user supplies that
provider's own base URL, model identifier, and credentials.

Thank you for reviewing the updated submission.

## App Review Notes template

Notation is a paid-upfront macOS app with no account, subscription, or in-app
purchase. Core editing works offline with local Markdown files.

Notation does not bundle or resell ChatGPT/OpenAI access. "OpenAI / Compatible"
describes an interoperable request format. The user supplies the API base URL,
model identifier, and API key, and requests go directly from the Mac to the
user-selected endpoint. No AI service is active by default.

AI review steps: open a local file, then go to Notation > Settings > AI, select
OpenAI / Compatible, set Base URL to https://api.deepseek.com and Model to
deepseek-v4-flash, paste the review-only DeepSeek key below, and click Save Key.
Return to the document, press Command-Shift-J, ask "Summarize this document",
and press Command-Enter. This test communicates directly with DeepSeek and does
not contact OpenAI or ChatGPT.

DeepSeek compatibility documentation: https://api-docs.deepseek.com/

Review-only DeepSeek API key: [ADD IN APP STORE CONNECT — NEVER COMMIT]

Notation uses BlockNote only as its open-source editing engine. Its native
workspace, real-file storage, security-scoped bookmarks, Markdown source mode,
math round-trip, external-change handling, Finder opening, and macOS window/menu
lifecycle are original product-specific implementations.
