import * as path from 'path';
import { spawn } from 'child_process';
import pLimit from 'p-limit';
import { loadConfig } from './config';
import { getCommits } from './git';
import { resolveBaseTag } from './baseTagResolver';

function parsePathArg(args: string[], flag: string): string | undefined {
  const idx = args.indexOf(flag);
  return idx !== -1 && args[idx + 1] ? path.resolve(args[idx + 1]) : undefined;
}

function parseStringArg(args: string[], flag: string): string | undefined {
  const idx = args.indexOf(flag);
  return idx !== -1 && args[idx + 1] ? args[idx + 1] : undefined;
}

function kosli(args: string[]): Promise<void> {
  return new Promise((resolve, reject) => {
    const proc = spawn('kosli', args, { stdio: 'inherit' });
    proc.on('close', code => {
      if (code === 0) resolve();
      else reject(new Error(`kosli ${args.slice(0, 2).join(' ')} exited with code ${code}`));
    });
    proc.on('error', reject);
  });
}

async function attestCommit(sha: string, config: ReturnType<typeof loadConfig>, repoPath: string): Promise<void> {
  const githubOrg = config.githubRepository.split('/')[0];

  await kosli([
    'begin', 'trail', sha,
    '--flow', config.kosliFlow,
    '--commit', sha,
    '--repo-root', repoPath,
  ]);

  await kosli([
    'attest', 'pullrequest', 'github',
    '--name', config.kosliAttestationName,
    '--github-token', config.githubToken,
    '--github-org', githubOrg,
    '--commit', sha,
    '--repo-root', repoPath,
    '--repository', config.githubRepository,
    '--flow', config.kosliFlow,
    '--trail', sha,
  ]);
}

async function main() {
  try {
    const args = process.argv.slice(2);
    const repoPath = parsePathArg(args, '--repo') ?? process.cwd();
    const envFile = parsePathArg(args, '--env-file');

    const config = loadConfig({ envFile });

    if (!config.baseTag) {
      console.error(`Auto-resolving base using Kosli flow: ${config.kosliFlow}`);
      config.baseTag = await resolveBaseTag(config.kosliFlow, config.kosliAttestationName, config.currentTag, repoPath);
    }

    console.error(`Range: ${config.baseTag || 'repository start'} → ${config.currentTag}`);

    const commits = getCommits(config.baseTag, config.currentTag, repoPath);
    console.error(`Found ${commits.length} commits.`);

    if (commits.length > 5000) {
      throw new Error(`Range contains ${commits.length} commits (limit 5000). Set BASE_TAG to narrow range.`);
    }

    const limit = pLimit(4);
    await Promise.all(
      commits.map(commit => limit(async () => {
        console.error(`  ${commit.sha.substring(0, 7)}: ${commit.message.substring(0, 60)}`);
        await attestCommit(commit.sha, config, repoPath);
      }))
    );

    process.exit(0);
  } catch (error) {
    console.error(`Error: ${error instanceof Error ? error.message : error}`);
    process.exit(1);
  }
}

main();
