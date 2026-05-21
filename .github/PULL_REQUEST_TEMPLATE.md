## Summary

<!-- 1–3 bullets describing the change. -->

-

## Preset PRs only

If this PR adds or modifies a file under `presets/`:

- [ ] `config.env` uses only allowlisted `PA_*` keys (see `lib/pa/paths.py:_ALLOWED_KEYS`).
- [ ] `tests/ci/validate-preset.sh presets/<name>` exits 0 locally.
- [ ] `README.md` declares target audience + required dependencies.
- [ ] I agree the preset ships under CC BY-SA 4.0 (see `presets/LICENSE`).

## Test plan

<!-- Optional. The diff itself is the canonical test record (CI runs pytest + bats + smoke). -->

-
