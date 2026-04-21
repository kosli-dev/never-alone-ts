import * as fs from 'fs';
import { AttestationData, CommitAttestation, CommitData, CommitSummary, Config, PRDetails, PRSummary, RawAttachment, RawPRData } from './types';

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

export function generateGranularAttestation(
  commitSummary: CommitSummary,
  pullRequests: PRSummary[],
  rawData: { githubCommit: unknown; prRaws: RawPRData[] },
  config: { githubRepository: string; exemptions: { serviceAccounts: string[] } },
): void {
  const sha = commitSummary.sha;
  const generatedAt = new Date().toISOString();

  const attestation: CommitAttestation = {
    commit_sha: sha,
    repository: config.githubRepository,
    generated_at: generatedAt,
    config: { exemptions: config.exemptions },
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
