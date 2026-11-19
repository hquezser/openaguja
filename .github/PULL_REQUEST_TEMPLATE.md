## What & why

<!-- What does this change, and what problem does it solve? Link the issue. -->

## Checklist

- [ ] Linked issue or explained motivation
- [ ] `cargo fmt --check` clean
- [ ] `cargo clippy --workspace --all-targets -- -D warnings` clean
- [ ] `cargo test --workspace` passes
- [ ] Swift changes: `scripts/swift-check.sh` run locally (hosted macOS
      runners are unavailable)
- [ ] Docs updated where user-facing behavior changed (`docs/`,
      `README.md`)
- [ ] New UI strings have an English source + French translation
- [ ] No personal data — real URLs, device IDs, tokens or private
      routine names; `scripts/public-check.sh` passes
- [ ] Generated files untouched (`ios/OpenAgujaCore/`,
      `ios/OpenAguja.xcodeproj`, `openaguja-ffi/generated/`)
- [ ] Safety rules respected — see
      [docs/SAFETY.md](docs/SAFETY.md); no never-call opcodes exposed,
      dangerous operations stay CLI-only
