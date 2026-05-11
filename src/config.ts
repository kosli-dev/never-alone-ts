import { config as dotenvConfig } from 'dotenv';

export interface Config {
  baseTag: string;
  currentTag: string;
  githubRepository: string;
  githubToken: string;
  kosliFlow: string;
  kosliAttestationName: string;
}

export function loadConfig(options: { envFile?: string } = {}): Config {
  dotenvConfig(options.envFile ? { path: options.envFile } : {});

  const required: Record<string, string | undefined> = {
    CURRENT_TAG: process.env.CURRENT_TAG,
    GITHUB_REPOSITORY: process.env.GITHUB_REPOSITORY,
    GITHUB_TOKEN: process.env.GITHUB_TOKEN,
    KOSLI_FLOW: process.env.KOSLI_FLOW,
  };

  const missing = Object.entries(required).filter(([, v]) => !v).map(([k]) => k);
  if (missing.length > 0) {
    throw new Error(`Missing required environment variables: ${missing.join(', ')}`);
  }

  return {
    baseTag: process.env.BASE_TAG || '',
    currentTag: required.CURRENT_TAG!,
    githubRepository: required.GITHUB_REPOSITORY!,
    githubToken: required.GITHUB_TOKEN!,
    kosliFlow: required.KOSLI_FLOW!,
    // Must match the key used in four-eyes.rego: attestations_statuses["pr-review"]
    kosliAttestationName: process.env.KOSLI_ATTESTATION_NAME || 'pr-review',
  };
}
