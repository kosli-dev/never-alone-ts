import * as dotenv from 'dotenv';
import * as fs from 'fs';
import * as path from 'path';
import { Config } from './types';

dotenv.config();

export function loadConfig(repoPath: string = process.cwd()): Config {
  const baseTag = process.env.BASE_TAG || '';
  const currentTag = process.env.CURRENT_TAG || '';
  const githubRepository = process.env.GITHUB_REPOSITORY || '';
  const githubToken = process.env.GITHUB_TOKEN || '';

  if (!currentTag || !githubRepository || !githubToken) {
    throw new Error('Missing required environment variables (CURRENT_TAG, GITHUB_REPOSITORY, GITHUB_TOKEN). Please check your .env file or environment.');
  }

  const configPath = path.resolve(repoPath, 'scr.config.json');
  if (!fs.existsSync(configPath)) {
    throw new Error(`scr.config.json file not found in: ${repoPath}`);
  }

  const configFile = JSON.parse(fs.readFileSync(configPath, 'utf8'));

  return {
    baseTag,
    currentTag,
    githubRepository,
    githubToken,
    exemptions: {
      serviceAccounts: configFile.exemptions?.serviceAccounts || [],
      filePaths: configFile.exemptions?.filePaths || [],
      fileNames: configFile.exemptions?.fileNames || [],
    },
  };
}
