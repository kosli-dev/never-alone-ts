import * as dotenv from 'dotenv';
import * as fs from 'fs';
import * as path from 'path';
import { Config } from './types';

dotenv.config();

export function loadConfig(repoPath: string = process.cwd()): Config {
  const serviceName = process.env.SERVICE_NAME || '';
  const releaseBranch = process.env.RELEASE_BRANCH || 'main';
  const baseTag = process.env.BASE_TAG || '';
  const currentTag = process.env.CURRENT_TAG || '';
  const releaseCommitSha = process.env.RELEASE_COMMIT_SHA || '';
  const githubRepository = process.env.GITHUB_REPOSITORY || '';
  const githubToken = process.env.GITHUB_TOKEN || '';

  if (!serviceName || !currentTag || !releaseCommitSha || !githubRepository || !githubToken) {
    throw new Error('Missing required environment variables. Please check your .env file or environment.');
  }

  const configPath = path.resolve(repoPath, 'scr.config.json');
  if (!fs.existsSync(configPath)) {
    throw new Error(`scr.config.json file not found in: ${repoPath}`);
  }

  const configFile = JSON.parse(fs.readFileSync(configPath, 'utf8'));

  return {
    serviceName,
    releaseBranch,
    baseTag,
    currentTag,
    releaseCommitSha,
    githubRepository,
    githubToken,
    exemptions: {
      serviceAccounts: configFile.exemptions?.serviceAccounts || [],
      filePaths: configFile.exemptions?.filePaths || [],
      fileNames: configFile.exemptions?.fileNames || [],
    },
  };
}
