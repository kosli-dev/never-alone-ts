import { KosliClient } from './kosli';
import { getCommitHistory, getInitialCommit } from './git';

export async function resolveBaseTag(
  flow: string,
  attestationName: string,
  currentTag: string,
  repoPath: string,
): Promise<string> {
  const client = new KosliClient();
  const qualifyingSHAs = await client.listTrailsWithAttestationName(flow, attestationName);

  const history = getCommitHistory(currentTag, repoPath);

  // Skip the first entry — that is currentTag itself.
  // In the per-commit model every trail IS a commit SHA, so we return the
  // SHA directly. git log SHA..CURRENT_TAG works the same as with a tag name.
  for (const sha of history.slice(1)) {
    if (qualifyingSHAs.has(sha)) {
      console.error(`Found previous attestation at ${sha}`);
      return sha;
    }
  }

  const initial = getInitialCommit(repoPath);
  console.error(`No previous attestation found — using initial commit ${initial}`);
  return initial;
}
