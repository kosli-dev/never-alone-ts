# Exchanging Repository Changes via Patch Files

Use this approach when you cannot push directly to a customer's copy of the repository.

## Sending changes (your side)

Generate a patch file for each commit you want to send:

```bash
git format-patch main..HEAD
```

This creates numbered `.patch` files (e.g. `0001-feat-my-change.patch`) in the current directory — one per commit. Send these files to the customer.

To generate a single patch covering all commits:

```bash
git format-patch main..HEAD --stdout > my-changes.patch
```

## Applying changes (customer side)

Apply the patch files in order using `git am`:

```bash
git am 0001-feat-my-change.patch
git am 0002-fix-something.patch
```

Or apply all at once:

```bash
git am *.patch
```

### Conflict resolution

If a patch fails to apply, `git am` will stop and report the conflicting file. Options:

- **Abort** and resolve manually: `git am --abort`
- **Skip** the failing patch: `git am --skip`
- **Resolve and continue**: fix the conflict, stage the file, then `git am --continue`

### Trailing whitespace warnings

Warnings like `warning: N lines add whitespace errors` are cosmetic — the patch is still applied successfully and can be ignored.
