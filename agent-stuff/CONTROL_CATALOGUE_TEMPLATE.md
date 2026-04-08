# Control Catalogue

This document defines the standard format for control entries and contains the first control. Each entry is self-contained: someone reading it should understand what the control does, how it works, what it needs, and how to act on its output — without reading the source code.

---

## Format reference

Each control entry uses the sections below. Sections marked *(optional)* may be omitted if not applicable to a given control.

| Section | Purpose |
|---|---|
| **Header block** | Machine-readable identity (ID, name, category, version, status) |
| **Intent** | Prose — what risk or obligation this control addresses |
| **Data collection** | How the tool gathers evidence: what it reads, where from, what shape it produces |
| **Evaluation logic** | How the collected data is turned into a pass/fail decision |
| **Policy** | The Rego (or other) policy, embedded verbatim |
| **Configuration** | Every tunable knob, its type, default, and effect |
| **Exemptions** | What can be excluded, why each exemption is safe to grant |
| **Pass / fail criteria** | One-sentence plain-language statement for each outcome |
| **Scenarios** | Link or inline table — named test cases with expected outcomes |
| **Limitations** | What the control explicitly does NOT catch |
| **Failure remediation** | *(optional)* What a team should do when the control fails |
| **False positive guidance** | *(optional)* Legitimate patterns that look like violations and how to resolve them |
| **Dependencies** | External systems, credentials, and version requirements |
| **Related controls** | *(optional)* Controls that this one complements or depends on |
| **Attestation schema** | *(optional)* Shape of the produced evidence object, for downstream consumers |

---

## Suggested additions (open questions for the catalogue)

The sections above are a starting point. Consider adding these as the catalogue matures:

- **Control owner** — team or role responsible for maintaining this control and acting on failures
- **Review cadence** — how often the control definition itself should be reviewed (policy drift, new edge cases)
- **Severity / risk rating** — how critical a violation is (blocker vs. advisory), so pipelines can decide whether to halt or just alert
- **Regulatory mapping** — which frameworks or clauses this control satisfies (SOC 2 CC8.1, ISO 27001 A.12.1.2, etc.), useful when presenting to auditors
- **Evidence retention** — how long attestation output should be kept and where
- **Test coverage table** — explicit mapping of each scenario to a test name, so gaps are immediately visible (this already exists for SCR-01 via `four-eyes_test.rego`)
- **Performance / cost profile** — number of API calls per commit, rate-limit exposure, expected runtime for a typical release range — important for large repos
- **Operational runbook** — step-by-step for the on-call engineer: what to do when the collector crashes, GitHub is unavailable, Kosli is unreachable, etc.
- **Changelog** — per-control version history so consumers know when behaviour changed under them

---
