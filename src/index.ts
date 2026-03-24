import * as path from 'path';
import { loadConfig } from './config';
import { getCommits, resolveSHA } from './git';
import { GitHubClient } from './github';
import { Evaluator } from './evaluator';
import { generateJsonReport } from './reporter';
import { EvaluationResult } from './types';

async function main() {
  try {
    const args = process.argv.slice(2);
    const repoArgIndex = args.indexOf('--repo');
    const repoPath = repoArgIndex !== -1 && args[repoArgIndex + 1] 
      ? path.resolve(args[repoArgIndex + 1]) 
      : process.cwd();

    const config = loadConfig(repoPath);
    const github = new GitHubClient(config.githubRepository, config.githubToken);
    const evaluator = new Evaluator(config, github, repoPath);

    console.log(`Analyzing repository: ${repoPath}`);
    console.log(`Range: ${config.baseTag || 'Repository Start'} to ${config.currentTag}`);

    const baseSha = resolveSHA(config.baseTag, repoPath);
    const currentSha = resolveSHA(config.currentTag, repoPath);

    const commits = getCommits(config.baseTag, config.currentTag, repoPath);
    console.log(`Found ${commits.length} commits.`);

    const results: EvaluationResult[] = [];
    for (const commit of commits) {
      console.log(`Evaluating commit ${commit.sha.substring(0, 7)}: ${commit.message.substring(0, 30)}...`);
      const result = await evaluator.evaluateCommit(commit);
      results.push(result);
    }

    const anyFailed = results.some(r => r.status === 'FAIL');
    const overallStatus = anyFailed ? 'FAILED' : 'PASSED';

    console.log(`\nOverall Status: ${overallStatus}`);

    generateJsonReport(results, config, baseSha, currentSha);

    if (anyFailed) {
      console.error('\nControl check failed! Some commits do not adhere to the four-eyes principle.');
      process.exit(1);
    } else {
      console.log('\nControl check passed! All commits adhere to the four-eyes principle.');
      process.exit(0);
    }
  } catch (error) {
    console.error(`\nError during execution: ${error instanceof Error ? error.message : error}`);
    process.exit(1);
  }
}

main();
