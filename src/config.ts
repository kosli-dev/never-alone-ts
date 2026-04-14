import * as dotenv from 'dotenv';
import * as fs from 'fs';
import * as path from 'path';
import { Config } from './types';

export function loadConfig(options: { configPath?: string; envFile?: string } = {}): Config {
  const {
    configPath = path.resolve(process.cwd(), 'scr.config.json'),
    envFile,
  } = options;

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

  if (!fs.existsSync(configPath)) {
    throw new Error(`scr.config.json file not found at: ${configPath}`);
  }

  const configFile = JSON.parse(fs.readFileSync(configPath, 'utf8'));

  return {
    baseTag,
    currentTag,
    githubRepository,
    githubToken,
    kosliFlow,
    kosliAttestationName,
    exemptions: {
      serviceAccounts: configFile.exemptions?.serviceAccounts || [],
    },
  };
}
