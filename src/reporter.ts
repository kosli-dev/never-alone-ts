import * as fs from 'fs';
import { AttestationData, CommitData, Config, PRDetails } from './types';

export function generateAttestationData(
  commits: CommitData[],
  pullRequests: Record<string, PRDetails>,
  config: Config,
  baseSha?: string,
  currentSha?: string,
): void {
  const filename = `att_data_${config.currentTag}.json`;

  const attestation: AttestationData = {
    repository: config.githubRepository,
    range: {
      base: config.baseTag,
      base_sha: baseSha,
      current: config.currentTag,
      current_sha: currentSha,
    },
    generated_at: new Date().toISOString(),
    config: {
      exemptions: config.exemptions,
    },
    commits,
    pull_requests: pullRequests,
  };

  fs.writeFileSync(filename, JSON.stringify(attestation, null, 2));
  console.log(`Attestation data generated: ${filename}`);
}
