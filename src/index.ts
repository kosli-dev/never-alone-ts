import * as path from 'path';
import { loadConfig } from './config';
import { getCommits, resolveSHA } from './git';
import { GitHubClient } from './github';
import { Collector } from './evaluator';
import { generateAttestationData } from './reporter';
import { CommitData, PRDetails } from './types';

async function main() {
  try {
    const args = process.argv.slice(2);
    const repoArgIndex = args.indexOf('--repo');
    const repoPath = repoArgIndex !== -1 && args[repoArgIndex + 1]
      ? path.resolve(args[repoArgIndex + 1])
      : process.cwd();

    const config = loadConfig(repoPath);
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
      if (commitData.pr_number && prDetails) {
        pullRequests[commitData.pr_number.toString()] = prDetails;
      }
    }

    generateAttestationData(collectedCommits, pullRequests, config, baseSha, currentSha);

    console.log('\nData collection complete. Attest the output file to a Kosli trail and run:');
    console.log('  kosli evaluate trail <trail> --policy-file four-eyes.rego');
    process.exit(0);
  } catch (error) {
    console.error(`\nError during execution: ${error instanceof Error ? error.message : error}`);
    process.exit(1);
  }
}

main();
