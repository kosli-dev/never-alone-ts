import { KosliClient } from './kosli';
import { getCommitHistory, getTagForCommit, getInitialCommit } from './git';

export async function resolveBaseTag(
  flow: string,
  attestationName: string,
  currentTag: string,
  repoPath: string,
): Promise<string> {
  const client = new KosliClient();
  const qualifyingSHAs = await client.listTrailsWithAttestationName(flow, attestationName);

  const history = getCommitHistory(currentTag, repoPath);

  // Skip the first entry — that is currentTag itself
  for (const sha of history.slice(1)) {
    if (qualifyingSHAs.has(sha)) {
      const tag = getTagForCommit(sha, repoPath);
      console.log(`Found previous attestation at ${sha}${tag ? ` (${tag})` : ''}`);
      return tag ?? sha;
    }
  }

  const initial = getInitialCommit(repoPath);
  console.log(`No previous attestation found — using initial commit ${initial}`);
  return initial;
}
