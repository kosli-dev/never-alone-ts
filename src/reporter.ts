import * as fs from 'fs';
import { CommitAttestation, CommitSummary, PRSummary, RawAttachment, RawPRData } from './types';

export function generateGranularAttestation(
  commitSummary: CommitSummary,
  pullRequests: PRSummary[],
  rawData: { githubCommit: unknown; prRaws: RawPRData[] },
  config: { githubRepository: string },
): void {
  const sha = commitSummary.sha;
  const generatedAt = new Date().toISOString();

  const attestation: CommitAttestation = {
    commit_sha: sha,
    repository: config.githubRepository,
    generated_at: generatedAt,
    commit: commitSummary,
    pull_requests: pullRequests,
  };

  const raw: RawAttachment = {
    commit_sha: sha,
    provider: 'github',
    generated_at: generatedAt,
    github_commit: rawData.githubCommit,
    pull_requests: rawData.prRaws,
  };

  const attFile = `att_data_${sha}.json`;
  const rawFile = `raw_${sha}.json`;

  fs.writeFileSync(attFile, JSON.stringify(attestation, null, 2));
  console.log(`Attestation data generated: ${attFile}`);

  fs.writeFileSync(rawFile, JSON.stringify(raw, null, 2));
  console.log(`Raw attachment generated: ${rawFile}`);
}
