# Feature description

I want to avoid that the user provides the `base_tag` themselves.
Instead it should be found in Kosli.

## How to find the right one

- The trail name is equal to commit sha. If true, find the "closest" commit that has a trail, and see if an attestation named `scr-data` is ther.
  - If not, look further back.
- If the trail name is not a commit sha, look back see if an attestation named `scr-data` is present.

If none of them can be found, then the base tag needs to be the initial commit in the given branch.

## Questions

How is the most correct, yet performant way of finding the right base tag?

## Commands

- `kosli list trails -o json`
- `kosli list flows -o json`
- `kosli get flow -o json`
- `kosli get trail -o json`

---

## Analysis and proposed design

### Observation: trail names are not pure commit SHAs (but git_commit_info is)

From `kosli list trails`, the trail names in this environment look like `<SHA><timestamp>`. However, the `git_commit_info` field on a trail contains the commit SHA directly and will be populated in production — that is the reliable field to use, not the trail name.

There can be multiple trails per commit SHA (same SHA, different timestamps/runs).

### Proposed algorithm

```
1. kosli list trails --flow <flow> -o json
   → build a Set of commit SHAs that have a scr-data attestation
     (read SHA from trail.git_commit_info; include trail if
      attestations_statuses contains an entry with attestation_name == "scr-data")

2. git log <CURRENT_TAG> --first-parent --pretty=format:%H
   → walk commits backwards, skipping CURRENT_TAG itself

3. For each commit SHA in the log:
   → if SHA is in the set from step 1:
       - check if a git tag points to it (git tag --points-at <sha>)
       - if yes: use that tag as BASE_TAG
       - if no: use the commit SHA directly (git log accepts SHAs too)
       - stop

4. If no match found: use the initial commit of the branch as BASE_TAG
```

### Why this approach is performant

- One Kosli API call (list trails) vs. one-per-commit lookups
- Set lookup is O(1) per commit in the git walk
- Git log walk stops at the first match — in normal release cadence that is very few commits back

The downside is that `kosli list trails` may paginate at scale. If there are hundreds of trails, fetching all of them upfront is still fine (they're small payloads), but it is worth checking whether the API has a `--limit` or `--page` flag so the tool can handle pagination correctly.

### Configuration needed

The tool currently has no concept of a Kosli flow name. To call `kosli list trails --flow <flow>`, we need to know the flow. This should be a new env var (e.g. `KOSLI_FLOW`) or derived from the existing `SERVICE_NAME`.

### Questions

1. **Flow name** — Should the Kosli flow name come from `SERVICE_NAME`, a new `KOSLI_FLOW` env var, or be read from `scr.config.json`?
- it should come as either a part of the ENV file, or as a paramter to the run. The old functionality with specifying the base tag should still be there, this should be a different entry-point to the code, that first figures out the base tag, and parses that to the rest of the code.

3. **No git tag on the found commit** — If the previous release commit has no git tag, is using the commit SHA directly as `BASE_TAG` acceptable? Or is a tag always guaranteed? No, tag here is only pointers to commit. Both base and current tag should accept either sha or tag.

4. **Multiple trails per commit** — Since the same commit SHA can have several trails (different timestamps), the rule is: the commit qualifies if *any* of its trails has a `scr-data` attestation. Is that correct, or should we require the *most recent* trail to have it? yes, any will do.

5. **Pagination** — Does `kosli list trails` paginate? If yes, does it have a `--page` / `--limit` flag we should handle?
- There is a `pagination` part of the json returned. it can be used with `--page int` The page number of a response. and `--page-limit` The number of elements per page
