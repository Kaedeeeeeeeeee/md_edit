# Privacy Policy

**Effective date:** 2026-05-14

## Who we are

Notation is an indie macOS app distributed via the Mac App Store. It's
maintained by the project author ([Kaedeeeeeeeeee](https://github.com/Kaedeeeeeeeeee)
on GitHub). The fastest way to reach us is to file an issue at
[our GitHub repo](https://github.com/Kaedeeeeeeeeee/md_edit/issues).

## What we collect

Nothing. The app has no user accounts, doesn't phone home, and we don't run
any servers that receive your data.

## Your files

The app reads and writes only the files and folders you explicitly authorize
via macOS's open-file or open-folder dialog. macOS App Sandbox enforces this
at the OS level — the app physically cannot reach anything you haven't
granted access to. We persist these authorizations on your device using
security-scoped bookmarks so you don't have to re-open the same folder every
launch; those bookmarks are stored locally and never transmitted anywhere.

## AI features and third-party processing

This is the most important section, so we'll be specific.

When you opt to use **Ask AI**, **Research**, or **Image Generation**, the
text you've selected plus the instruction you typed — and only those, not
your full document, not any other files — are sent over HTTPS, directly
from your device, to the AI provider you configured in *Settings → AI*.
Supported providers:

- **Anthropic Claude** — governed by
  [Anthropic's privacy policy](https://www.anthropic.com/legal/privacy).
- **OpenAI** and OpenAI-compatible endpoints (DeepSeek, Groq, Together,
  Fireworks, OpenRouter, local Ollama, and others) — each governed by its
  own provider's privacy policy. See
  [OpenAI's policy](https://openai.com/policies/privacy-policy) as the
  canonical reference for the OpenAI-compatible shape.

The API key you provide is stored in macOS Keychain on your device only.
It is never transmitted to us. We have no way to see it.

If you don't use AI features, no network calls related to AI happen at all.

## Purchases & subscriptions

Notation is free to download from the Mac App Store. Some AI features
(Ask AI, Research, Image Generation) require upgrading to Notation Pro
via one of three in-app purchases: monthly subscription, yearly
subscription, or one-time lifetime purchase.

All transactions go through Apple's StoreKit. We never receive your payment
information — not your card number, not your billing address, not your name.
Apple handles the entire transaction. We only receive a verified signal that
an entitlement is active or inactive for the current device's Apple ID.

Locally, we store a single derived flag ("is Pro?") plus the tier name
(monthly / yearly / lifetime). This is kept in UserDefaults on your device
and never transmitted anywhere.

To manage or cancel a subscription, visit Apple's standard subscription
page at <https://apps.apple.com/account/subscriptions>. Subscription
renewals and refunds are handled by Apple, not us.

## Analytics, telemetry, ads, tracking

None. Zero. The app makes no analytics calls. We don't embed third-party
SDKs that profile or track users.

## Network access

The app uses network access only for: (a) user-initiated AI calls described
above, and (b) standard macOS system services. There is no background data
collection.

## Crash reports

The app doesn't send crash reports to us. macOS may surface system-level
crash reports to Apple under your system settings; that is governed by
Apple's privacy practices, not ours.

## Children's privacy

The app isn't directed at children under 13. We don't knowingly collect data
from anyone, so there's nothing specific to add about children.

## Changes to this policy

If anything material changes, we'll update the *Effective date* at the top
and note the change in the GitHub repo's commit history. There's no in-app
notification because there's no user account to notify.

## Contact

File an issue at
<https://github.com/Kaedeeeeeeeeee/md_edit/issues>.
