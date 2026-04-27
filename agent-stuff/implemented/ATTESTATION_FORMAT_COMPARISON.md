# Attestation Format Comparison

**Date:** 2026-04-23
**Formats compared:**
1. **never-alone** — `att_data_<tag>.json` produced by this collector
2. **GitHub Kosli PR attestation** — `attestation_type: pull_request`, `git_provider: github`
3. **GitLab Kosli PR attestation** — `attestation_type: pull_request`, `git_provider: gitlab`

---

## 1. Fields present in both Kosli PR attestations but missing from never-alone

| Field | GitHub Kosli | GitLab Kosli | never-alone |
| --- | --- | --- | --- |
| `pr.created_at` | ✅ unix float | ✅ unix float | ❌ missing |
| `pr.head_ref` | ✅ branch name | ✅ branch name | ❌ missing |
| `pr.merge_commit` | ✅ merge commit SHA | ✅ merge commit SHA | ❌ missing |
| `commit.url` | ✅ per-commit link | ✅ per-commit link | ❌ missing |
| `commit.branch` | ✅ per commit | ✅ per commit | ❌ missing |

These fields are available from both the GitHub and GitLab APIs and should be added to the never-alone attestation schema.

---

## 2. Critical finding: GitLab Kosli PR attestation has no approvers

The GitLab PR attestation has **no `approvers` field** on the PR object. The GitHub PR attestation does.

This means never-alone cannot use the Kosli-generated PR attestation as a data source for four-eyes evaluation. The collector must call the GitLab approvals API independently:

```
GET /api/v4/projects/{id}/merge_requests/{iid}/approvals → approved_by[]
```

This validates the approach in `implementing-gitlab.md` Phase 3.

---

## 3. Author identity — three different representations

| Source | PR `author` | Commit `author` | Commit platform username |
| --- | --- | --- | --- |
| GitHub Kosli | `"mbevc1"` (flat string) | `"Name <email>"` string | `author_username: "mbevc1"` (separate field) |
| GitLab Kosli | `"Jon Jagger (@JonJagger)"` (formatted string) | `"JonJagger <email>"` string | ❌ absent |
| never-alone | `{ login, user_id, web_url }` (structured object) | nested `author` object with `login` | `author.login` |

Never-alone's structured object is the most machine-readable. The GitLab Kosli format `"Jon Jagger (@JonJagger)"` would require string parsing to extract the username — fragile and not suitable as a data source for the independence check.

---

## 4. What never-alone has that both Kosli attestations lack

These fields are intentional additions by the never-alone collector and are essential for four-eyes evaluation:

| Field | Why it is needed |
| --- | --- |
| `commit.parent_shas` | Merge commit detection and merge-from-base detection — `is_merge_commit` and `is_merge_from_base` in the Rego policy depend entirely on this |
| `commit.changed_files` | Reserved for future file-path exemption rules |
| `config.exemptions` | Service account patterns embedded in the attestation at collection time; the policy reads them back from the attestation so there is no runtime config injection |
| `range` (base + current tags + SHAs) | Audit evidence of exactly which commit window was evaluated |

---

## 5. Schema and naming differences (same data, different shape)

| Concept | GitHub Kosli | GitLab Kosli | never-alone |
| --- | --- | --- | --- |
| Commit SHA key | `sha1` | `sha1` | `sha` |
| Timestamp format | Unix float | Unix float | ISO-8601 string |
| Approver login | `approvers[].username` | ❌ absent | `approvals[].user.login` |
| Approval time | `approvers[].timestamp` (unix) | ❌ absent | `approvals[].approved_at` (ISO-8601) |
| PR state values | `"MERGED"` (uppercase) | `"merged"` (lowercase) | `"closed"` (GitHub API state) |

---

## 6. Stale item in implementing-gitlab.md Phase 5.2

The plan proposes adding a GitLab-specific `is_merge_commit` Rego rule based on commit message:

```rego
is_merge_commit(commit) if {
  startswith(commit.message, "Merge branch '")
}
```

This is based on an old version of the policy. The current `four-eyes.rego` already uses **parent count only**:

```rego
is_merge_commit(commit) if {
  count(commit.parent_shas) > 1
}
```

There is no message-based check in the current policy. Phase 5.2 is a no-op — the policy already handles GitLab merge commits correctly. The item should be removed from the plan.

---

## 7. Recommended additions to never-alone's attestation schema

Fields validated as available from both GitHub and GitLab APIs:

```diff
  pull_requests: {
    "42": {
      "number": 42,
+     "created_at": "2026-04-17T10:00:00Z",  // ISO-8601, both platforms
+     "head_ref": "feature-x",                // source branch name
+     "merge_commit": "abc1234...",            // SHA of merge commit on main
      "commits": [
        {
+         "url": "https://github.com/.../commit/abc1234",  // direct link
+         "branch": "feature-x",                           // branch this commit was on
        }
      ]
    }
  }
```

---

## 8. Open item to verify before shipping GitLab support

**Q: Does GitLab's `approved_at` reflect the most recent approval or only the first?**

If a reviewer approved early, new code was pushed, and they re-approved, the timestamp must reflect the re-approval for the cutoff check to work correctly. If GitLab records only the first approval, a stale approval could pass the `approved_at > latest_commit_date` check — a false pass. This must be verified against the GitLab API before the GitLab collector is shipped.

Reference: `implementing-gitlab.md` open question Q5.
