# Accessibility statement

OpenAguja is unofficial software for ZeTime watches, developed by a solo
maintainer. This statement covers the iOS app (the primary interface),
the CLI and the documentation site. Last reviewed: 2026-11-19.

## Conformance status

**Target: WCAG 2.1 Level AA.** The project is *not yet fully
conformant* — accessibility is an ongoing effort, not a completed
audit. Current state, honestly assessed:

- The app is built on SwiftUI semantic views and Dynamic Type; custom
  elements such as the battery ring expose `accessibilityLabel` /
  `accessibilityValue` where added.
- Tab bars, toggles and icon-only buttons carry labels in the main
  flows; coverage is incomplete in secondary screens.
- French UI translations exist; VoiceOver wording in French has not
  been reviewed by a native speaker.

## Known limitations

- Dense data screens (activity charts, memory dumps, raw logs) are
  visual-first and may be difficult with VoiceOver.
- Some fixed-size text and small touch targets remain in older views.
- CLI and `openaguja-macd` output is plain text/JSON — readable by
  screen readers, but not specifically optimized for them.

## Feedback

Accessibility bugs and suggestions are welcome — open an issue
(describe the screen, the assistive technology used such as VoiceOver
or Switch Control, and what happened versus what you expected), or
email dev@hougo.nohost.me.
