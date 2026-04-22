import * as path from 'path';
import pLimit from 'p-limit';
import { loadConfig, loadGranularConfig } from './config';
import { getCommits, getSingleCommit } from './git';
import { GitHubClient } from './github';
import { Collector } from './evaluator';
import { generateGranularAttestation } from './reporter';
import { resolveBaseTag } from './baseTagResolver';

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
    const envFile = parsePathArg(args, '--env-file');
    const commitSha = parseStringArg(args, '--commit');

    // ─── Per-commit (granular) mode ───────────────────────────────────────────
    if (commitSha) {
      const config = loadGranularConfig({ envFile });
      const github = new GitHubClient(config.githubRepository, config.githubToken);
      const collector = new Collector(github, repoPath);

      console.log(`Collecting commit ${commitSha.substring(0, 7)} from ${config.githubRepository}`);
      const commit = getSingleCommit(commitSha, repoPath);
      const { commitSummary, pullRequests, rawData } = await collector.collectCommitGranular(commit);
      generateGranularAttestation(commitSummary, pullRequests, rawData, config);

      process.exit(0);
      return;
    }

    // ─── Range (batch) mode ───────────────────────────────────────────────────
    // Writes one att_data_<sha>.json + raw_<sha>.json per commit in range.
    // If BASE_TAG is not set but KOSLI_FLOW is, the base is auto-resolved from
    // the most recent attested commit in that flow.
    const config = loadConfig({ envFile });

    const flow = parseStringArg(args, '--flow') || config.kosliFlow;
    if (flow && !config.baseTag) {
      console.log(`Auto-resolving base tag using Kosli flow: ${flow}`);
      config.baseTag = await resolveBaseTag(flow, config.kosliAttestationName, config.currentTag, repoPath);
    }

    const github = new GitHubClient(config.githubRepository, config.githubToken);
    const collector = new Collector(github, repoPath);

    console.log(`Analyzing repository: ${repoPath}`);
    console.log(`Range: ${config.baseTag || 'Repository Start'} to ${config.currentTag}`);

    const maxCommits = 5000;
    const commits = getCommits(config.baseTag, config.currentTag, repoPath);
    console.log(`Found ${commits.length} commits.`);

    if (commits.length > maxCommits) {
      throw new Error(
        `Range contains ${commits.length} commits, exceeding the limit of ${maxCommits}. ` +
        `Set BASE_TAG explicitly to narrow the range.`
      );
    }

    const limit = pLimit(4);
    await Promise.all(
      commits.map(commit => limit(async () => {
        console.log(`Collecting commit ${commit.sha.substring(0, 7)}: ${commit.message.substring(0, 30)}...`);
        const { commitSummary, pullRequests, rawData } = await collector.collectCommitGranular(commit);
        generateGranularAttestation(commitSummary, pullRequests, rawData, config);
      }))
    );

    process.exit(0);
  } catch (error) {
    console.error(`\nError during execution: ${error instanceof Error ? error.message : error}`);
    process.exit(1);
  }
}

main();
