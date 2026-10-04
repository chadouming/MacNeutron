# Sub-project 5 research: the arm64-only release (2026-10-04)

Four read-only maps written before the design, each citing `file:line` at commit `95f8883`:

- `map-launch-path.md`: how a game starts today, end to end, and where the Rosetta runtime is hard-wired.
- `map-setup-state.md`: setup, per-game settings, prefixes, preflight, the app and its signing.
- `map-arm64-deliverables.md`: what sub-projects 1-3 hand the launcher (`wine.app`'s layout, `check.sh`'s recipe).
- `map-release.md`: release packaging and licensing (nothing has been released yet; lsteamclient's licence).
- `digest-core.md`, `digest-install-app.md`, `digest-wine-build.md`, `digest-checks.md`, `digest-release-docs.md`:
  interface digests written for the implementation plan (exact signatures, line ranges and test names at `92d8f83`;
  line numbers drift as the plan's tasks land).
- `spec-review.md`: the adversarial review of the spec draft (three lenses, each re-checked by a sceptic).

The design built on them: `docs/superpowers/specs/2026-10-04-macneutron-arm64-release-design.md`.
