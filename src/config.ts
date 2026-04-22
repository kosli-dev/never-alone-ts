import * as dotenv from 'dotenv';
import { Config } from './types';

export function loadGranularConfig(options: { envFile?: string } = {}): {
  githubRepository: string;
  githubToken: string;
} {
  const { envFile } = options;
  dotenv.config(envFile ? { path: envFile } : {});

  const githubRepository = process.env.GITHUB_REPOSITORY || '';
  const githubToken = process.env.GITHUB_TOKEN || '';

  if (!githubRepository || !githubToken) {
    throw new Error('Missing required environment variables (GITHUB_REPOSITORY, GITHUB_TOKEN).');
  }

  return { githubRepository, githubToken };
}

export function loadConfig(options: { envFile?: string } = {}): Config {
  const { envFile } = options;
  dotenv.config(envFile ? { path: envFile } : {});

  const baseTag = process.env.BASE_TAG || '';
  const currentTag = process.env.CURRENT_TAG || '';
  const githubRepository = process.env.GITHUB_REPOSITORY || '';
  const githubToken = process.env.GITHUB_TOKEN || '';
  const kosliFlow = process.env.KOSLI_FLOW || '';
  const kosliAttestationName = process.env.KOSLI_ATTESTATION_NAME || 'scr-data';

  if (!currentTag || !githubRepository || !githubToken) {
    throw new Error('Missing required environment variables (CURRENT_TAG, GITHUB_REPOSITORY, GITHUB_TOKEN). Please check your .env file or environment.');
  }

  return {
    baseTag,
    currentTag,
    githubRepository,
    githubToken,
    kosliFlow,
    kosliAttestationName,
  };
}
