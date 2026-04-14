# GitLab API Compatibility Analysis

**Date:** 2026-04-11 (updated after platform-agnostic field rename)
**Tested against:** `gitlab-org/gitlab` (project ID: 278964)
**Reference data structure:** `examples/att_data_v2.11.46.json` (GitHub)

---

## Summary

The existing data structure maps well to GitLab with a few adjustments. The core concepts — commits, merge requests, approvals, changed files — all exist in GitLab. The main friction points are:

1. Commit author identity (no GitLab username in commit payloads)
2. MR number not embedded in commits (requires extra API call)

Field naming differences (`login`, `user_id`, `web_url`, `approved_at`) have already been resolved — the schema is now platform-agnostic.

---

## Field-by-field mapping

### Top-level structure

| GitHub field | GitLab equivalent | Notes |
| --- | --- | --- |
| `repository` | Same format | Use `namespace/project` (e.g. `gitlab-org/gitlab`) |
| `range.base` / `range.current` | Same | Tags or SHAs work |
| `range.base_sha` / `range.current_sha` | Same | Identical concept |
| `generated_at` | Same | No change needed |
| `config.exemptions` | Same structure | See notes on service accounts below |

---

### Commits

GitLab API endpoint: `GET /api/v4/projects/{id}/repository/commits`
Diff/changed files: `GET /api/v4/projects/{id}/repository/commits/{sha}/diff`

| Schema field | GitLab API response | Notes |
| --- | --- | --- |
| `sha` | `id` | Same value (full SHA) |
| `parent_shas` | `parent_ids` | Same value, renamed field |
| `author.git_name` | `author_name` | ✅ Direct |
| `author.git_email` | `author_email` | ✅ Direct |
| `author.login` | ❌ Not in commit payload | Requires secondary user lookup — see below |
| `author.user_id` | ❌ Not in commit payload | Requires secondary user lookup — see below |
| `author.web_url` | ❌ Not in commit payload | Derivable if username known |
| `date` | `authored_date` or `committed_date` | Two separate timestamps in GitLab |
| `message` | `message` (full) or `title` (first line) | Both exist |
| `changed_files` | `/commits/{sha}/diff` → `new_path` / `old_path` | Extra API call, same concept |
| `pr_numbers` (array) | ❌ Not in commit payload | Requires `/commits/{sha}/merge_requests` → collect all `iid` values into an array |

**Author identity gap — important:**
GitLab's commit API returns `author_name` and `author_email` only. There is no `username` or user `id` in the commit payload. To resolve the GitLab identity you would need to call:

```text
GET /api/v4/users?search=<email>
```

In practice this often returns empty results because most users have private emails. An alternative is to get author identity from the MR object itself (the MR `author` field has full user details), which works when the commit is linked to an MR.

**Why GitHub doesn't have this problem:** GitHub's API automatically resolves the git commit email to a platform user object server-side — every commit response includes both a `commit.author` (raw git: name + email) and a top-level `author` (resolved GitHub user: login, id, html_url). GitLab treats these as separate concerns and never does that resolution for you. The email-based fallback (`/users?search=email`) is conceptually the same lookup — it just succeeds far less often on GitLab because most users have private emails, whereas GitHub requires verified email addresses and maps them automatically.

**Implication for the GitLab collector:** Don't attempt identity resolution from bare commit objects. Follow the same pattern as the GitHub `getPRFullDetails` implementation — fetch the MR first, then use its commit list and participant list. The MR participant endpoint is GitLab's equivalent of GitHub's resolved `c.author` field on PR commits. If resolution still fails after the three-step chain, emit `null` for `login`/`user_id` — the Rego policy will flag it as "identity unverifiable".

Example commit payload from GitLab:

```json
{
  "id": "979b4f013872b9080c550f7c717e5e8ba8448a5f",
  "parent_ids": ["67f2d2bfb2b18ce97fa76627933c16ab38b955a2"],
  "author_name": "Stanislav Lashmanov",
  "author_email": "slashmanov@gitlab.com",
  "authored_date": "2026-04-11T04:47:13.000+04:00",
  "message": "Fix line range drag not passing through discussion rows\n\n...",
  "web_url": "https://gitlab.com/gitlab-org/gitlab/-/commit/979b4f..."
}
```

**MR number gap:**
Commits on the main branch have no `iid`/`mr_number` embedded in the API response. The merge commit message typically contains a reference like `See merge request https://gitlab.com/.../merge_requests/230989` (parseable), or you call:

```text
GET /api/v4/projects/{id}/repository/commits/{sha}/merge_requests
→ returns array of MRs, use .iid
```

---

### Pull Requests → Merge Requests

GitLab API endpoint: `GET /api/v4/projects/{id}/merge_requests/{iid}`

| Schema field | GitLab API response | Notes |
| --- | --- | --- |
| `number` (PR key) | `iid` | Project-local integer, same concept |
| `url` | `web_url` | ✅ Same concept |
| `title` | `title` | ✅ |
| `author.login` | `author.username` | ✅ Available |
| `author.user_id` | `author.id` | ✅ Available |
| `author.web_url` | `author.web_url` | ✅ Same field name |
| `state` | `state` (`merged`, `closed`, `opened`) | ✅ Same values |
| `merged_at` | `merged_at` | ✅ |
| `approvals` | `/merge_requests/{iid}/approvals` → `approved_by` | Extra endpoint, same concept |
| `commits` (within PR) | `/merge_requests/{iid}/commits` | Extra endpoint, same concept |

MR user objects look like:

```json
{
  "id": 10539680,
  "username": "slashmanov",
  "name": "Stanislav Lashmanov",
  "public_email": "",
  "web_url": "https://gitlab.com/slashmanov"
}
```

Note: `public_email` is often empty (user-controlled privacy setting).

---

### Approvals

GitLab API endpoint: `GET /api/v4/projects/{id}/merge_requests/{iid}/approvals`

| Schema field | GitLab API response | Notes |
| --- | --- | --- |
| `approvals[].user.login` | `approved_by[].user.username` | ✅ |
| `approvals[].user.user_id` | `approved_by[].user.id` | ✅ |
| `approvals[].user.web_url` | `approved_by[].user.web_url` | ✅ Same field name |
| `approvals[].approved_at` | `approved_by[].approved_at` | ✅ Same field name |

Example response:

```json
{
  "approved_by": [
    {
      "user": {
        "id": 21747317,
        "username": "ms.mondrian",
        "name": "Chaoyue Zhao",
        "web_url": "https://gitlab.com/ms.mondrian"
      },
      "approved_at": "2026-04-11T15:52:26.792Z"
    }
  ]
}
```

---

### Config Exemptions

#### `serviceAccounts`

Both platforms support regex-pattern-based exclusions. GitLab has its own bots:

- `GitLabDuo` — AI bot, appears as a reviewer
- `ghost` — deleted user placeholder
- GitLab CI service accounts often follow patterns like `project_\d+_bot.*`

Pattern list works the same way, just targeting `username` instead of `login`.

#### `filePaths` and `fileNames`

No changes needed. File path concepts are identical.

---

## What works as-is

- Overall document structure (top-level fields, nested arrays/maps)
- MR/PR metadata (number, title, state, merged_at, url)
- Approvals structure (users with timestamps)
- Changed files per commit
- Service account exemption pattern matching (concept identical)
- File path exemptions

---

## What needs adaptation for GitLab

| Issue | Severity | Status | Notes |
| --- | --- | --- | --- |
| Commit author has no `login`/`user_id` | **High** | Open | Need secondary `/users?search=email` or derive from MR author; null login now fires explicit "identity unverifiable" violation — see below |
| `pr_numbers` (array) not in commit payload | **High** | Open | Need `/commits/{sha}/merge_requests` call; collect all returned `iid` values into the array |
| `authored_date` vs `committed_date` | Low | Open | GitHub uses one `date`; GitLab splits these — pick `authored_date` |
| Field naming (`login`, `user_id`, `web_url`, `approved_at`) | Low | ✅ Done | Schema is now platform-agnostic |
| Null login handling in Rego | — | ✅ Done | Rego fires "identity unverifiable" violation when `c.author.login == null`; also guards against vacuous pass when all PR commit authors are unresolved |

---

## Open questions

1. **Squash merges**: ✅ Resolved. `GET /merge_requests/{iid}/commits` returns all pre-squash branch commits with full `author_name` and `author_email` — the squash does not hide authorship. The four-eyes check runs on MR commits, so squash has no impact on the independence check. GitLab also preserves the original developer as the author of the squash commit on main (the committer may differ, but `author_name`/`author_email` remain the developer's). Verified against MR 230416 (`gitlab-org/gitlab`): 3 pre-squash commits all attributed to the original author.

2. **Author identity fallback**: ✅ Resolved. All three approaches tested across 5 MRs (7 unique commit authors) on `gitlab-org/gitlab`.

   | Author | Email | Email search | Participant by display name | Participant by username |
   | --- | --- | --- | --- | --- |
   | Prabin | `bajgaiprabin@gmail.com` (private) | FAIL | `prabinb19` ✅ | — |
   | Stanislav Lashmanov | `slashmanov@gitlab.com` (private) | FAIL | `slashmanov` ✅ | — |
   | Brian Williams | `bwilliams@gitlab.com` (public) | `bwill` ✅ | `bwill` ✅ | — |
   | imand3r | `ianderson@gitlab.com` (private) | FAIL | FAIL (git name "imand3r" ≠ display name "Ian Anderson") | `imand3r` ✅ |
   | Zachary Painter | `zpainter@gitlab.com` (private) | FAIL | `z_painter` ✅ | — |
   | Tim Rizzi | `trizzi@gitlab.com` (public) | `trizzi` ✅ | `trizzi` ✅ | — |
   | Hayley Swimelar | `hswimelar@gitlab.com` (private) | FAIL | `hswimelar` ✅ | — |

   Email search resolved 2/7 (28%). Participant by display name resolved 6/7 (86%). The one failure (`imand3r`) is a developer who configured git with their username handle rather than their full name — covered by matching on username instead.

   **Resolution strategy (in order):**
   1. `GET /api/v4/users?search=<email>` — use if exactly one result and name matches
   2. MR participants: find participant where `participant.name == author_name`
   3. MR participants: find participant where `participant.username == author_name`
   4. Leave `login`/`user_id` as `null` — the Rego policy handles this explicitly

   This chain resolved all 7 observed cases.

   **What happens at step 4 (null login) in the Rego:**
   The policy now has two separate failure modes for unresolvable identities:

   - A dedicated `"identity unverifiable"` violation fires for every PR commit whose `author.login` is `null` and isn't a service account. This is distinct from the "no independent approval" path and fires unconditionally — the PR's approval state is irrelevant.
   - `has_independent_approval` also guards `count(all_authors) > 0`: if every PR commit author is unresolved (all logins null), the approval check does not vacuously pass. The commit still fails via the identity violation above.

   The violation message currently reads `"has no linked GitHub account"` — a GitLab implementation should substitute `"GitLab account"` or use a platform-agnostic phrasing.

3. **Multiple approval rules**: ✅ Resolved. The control does not care about GitLab's named approval rules and checks the four-eyes principle purely from the flat `approved_by` list. Collecting all approvers regardless of which rule they satisfied is correct and sufficient.

4. **`iid` vs `id`**: ✅ Resolved. GitLab MRs have both a global `id` and a project-local `iid`. The `iid` (what users see in URLs like `!230989`) is the right one to use as the key — same as GitHub's PR number. Confirmed correct.
