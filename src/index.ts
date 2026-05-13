import * as path from 'path';
import pLimit from 'p-limit';
import { loadConfig } from './config.js';
import { getCommits } from './git.js';
import { resolveBaseTag } from './baseTagResolver.js';
import { KosliClient } from './kosli.js';

function parsePathArg(args: string[], flag: string): string | undefined {
  const idx = args.indexOf(flag);
  return idx !== -1 && args[idx + 1] ? path.resolve(args[idx + 1]) : undefined;
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

    const kosli = new KosliClient();
    const limit = pLimit(4);
    await Promise.all(
      commits.map(commit => limit(async () => {
        console.error(`  ${commit.sha.substring(0, 7)}: ${commit.message.substring(0, 60)}`);
        await kosli.attestCommit(commit.sha, config, repoPath);
      }))
    );

    process.exit(0);
  } catch (error) {
    console.error(`Error: ${error instanceof Error ? error.message : error}`);
    process.exit(1);
  }
}

main();
