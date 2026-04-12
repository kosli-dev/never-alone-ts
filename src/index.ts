import * as path from 'path';
import { loadConfig } from './config';
import { getCommits, resolveSHA } from './git';
import { GitHubClient } from './github';
import { Collector } from './evaluator';
import { generateAttestationData } from './reporter';
import { resolveBaseTag } from './baseTagResolver';
import { CommitData, PRDetails } from './types';

function parsePathArg(args: string[], flag: string): string | undefined {
  const idx = args.indexOf(flag);
  return idx !== -1 && args[idx + 1] ? path.resolve(args[idx + 1]) : undefined;
}

function parseStringArg(args: string[], flag: string): string | undefined {
  const idx = args.indexOf(flag);
  return idx !== -1 && args[idx + 1] ? args[idx + 1] : undefined;
}

async function main() {
  try {
    const args = process.argv.slice(2);
    const repoPath = parsePathArg(args, '--repo') ?? process.cwd();
    const configPath = parsePathArg(args, '--config');
    const envFile = parsePathArg(args, '--env-file');

    const config = loadConfig({ configPath, envFile });

    const flow = parseStringArg(args, '--flow') || config.kosliFlow;
    if (flow && !config.baseTag) {
      console.log(`Auto-resolving base tag using Kosli flow: ${flow}`);
      config.baseTag = await resolveBaseTag(flow, config.kosliAttestationName, config.currentTag, repoPath);
    }

    const github = new GitHubClient(config.githubRepository, config.githubToken);
    const collector = new Collector(github, repoPath);

    console.log(`Analyzing repository: ${repoPath}`);
    console.log(`Range: ${config.baseTag || 'Repository Start'} to ${config.currentTag}`);

    const baseSha = resolveSHA(config.baseTag, repoPath);
    const currentSha = resolveSHA(config.currentTag, repoPath);

    const commits = getCommits(config.baseTag, config.currentTag, repoPath);
    console.log(`Found ${commits.length} commits.`);

    const collectedCommits: CommitData[] = [];
    const pullRequests: Record<string, PRDetails> = {};

    for (const commit of commits) {
      console.log(`Collecting commit ${commit.sha.substring(0, 7)}: ${commit.message.substring(0, 30)}...`);
      const { commitData, prDetails } = await collector.collectCommit(commit);
      collectedCommits.push(commitData);
      for (const pr of prDetails) {
        pullRequests[pr.number.toString()] = pr;
      }
    }

    generateAttestationData(collectedCommits, pullRequests, config, baseSha, currentSha);

    process.exit(0);
  } catch (error) {
    console.error(`\nError during execution: ${error instanceof Error ? error.message : error}`);
    process.exit(1);
  }
}

main();
