# Plan: Fix Rego policy after switch to `attest custom`

## What broke and why

Switching from `kosli attest generic` to `kosli attest custom` changed where Kosli
stores the payload in the trail's JSON:

| Attestation command | Payload location in input |
| --- | --- |
| `attest generic` | `attestations_statuses["scr-data"].user_data` |
| `attest custom` | `attestations_statuses["scr-data"].attestation_data` |

The Rego policy still reads from `.user_data`, which is now `{}`.
Because `{}.commits` and `{}.pull_requests` are undefined in OPA, every violation
rule silently produces no results — so `count(violations) == 0` is always true and
**every trail passes regardless of actual review state**.

Confirmed by inspecting `eval_result_v2.11.42.json`:

```
user_data:          {}                               ← what rego reads now
attestation_data keys: [commits, config, generated_at, pull_requests, range, repository]
```

---

## Fix 1 — Correct the data path in `four-eyes.rego`

**File:** `four-eyes.rego` line 18

```rego
# Before
attestation := input.trail.compliance_status.attestations_statuses["scr-data"].user_data

# After
attestation := input.trail.compliance_status.attestations_statuses["scr-data"].attestation_data
```

Also update the comment above it (lines 12–17) to reflect the new field name.

---

## Fix 2 — Add a violation when the attestation is missing

Currently, if the `scr-data` attestation is absent from the trail entirely,
`attestation` is undefined. OPA silently skips every rule that references it,
so `violations` stays empty and the trail is marked compliant — a false pass.

Add an explicit guard violation at the top of the violations block:

```rego
violations contains msg if {
    not input.trail.compliance_status.attestations_statuses["scr-data"]
    msg := "scr-data attestation is missing from the trail"
}
```

This fires whenever the attestation key is absent, making the trail non-compliant
instead of silently passing.

---

## Files affected

| File | Change |
| --- | --- |
| `four-eyes.rego` | Line 18: `.user_data` → `.attestation_data`; update comment; add missing-attestation violation |
| `four-eyes_test.rego` | Add a test case that passes a trail with no `scr-data` attestation and asserts the violation fires |

---

## Test plan

1. `npm run test:rego` — existing tests should still pass; new missing-attestation test must pass
2. `npm run build && bash simulate.sh` — all 9 trails should complete with correct compliance results (some non-compliant expected for commits without independent approval)
