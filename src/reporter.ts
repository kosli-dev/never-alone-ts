import * as fs from 'fs';
import { EvaluationResult, PRDetails, StructuredReport, Config } from './types';

export function generateJsonReport(results: EvaluationResult[], config: Config, baseSha?: string, currentSha?: string) {
  const filename = `att_report_${config.currentTag}.json`;
  
  const pull_requests: Record<string, PRDetails> = {};
  results.forEach(result => {
    if (result.associated_pr_number && result.pr_details) {
      pull_requests[result.associated_pr_number.toString()] = result.pr_details;
    }
  });

  const anyFailed = results.some(r => r.status === 'FAIL');

  const report: StructuredReport = {
    report_info: {
      repository: config.githubRepository,
      range: {
        base: config.baseTag,
        base_sha: baseSha,
        current: config.currentTag,
        current_sha: currentSha,
      },
      generated_at: new Date().toISOString(),
      overall_status: anyFailed ? 'FAILED' : 'PASSED',
    },
    main_branch_commits: results.map(result => ({
      sha: result.commit.sha,
      parent_shas: result.commit.parent_shas,
      author: result.commit.author,
      date: result.commit.date.toISOString(),
      message: result.commit.message,
      evaluation: {
        status: result.status,
        reason: result.reason,
      },
      associated_pr_number: result.associated_pr_number,
    })),
    pull_requests,
  };

  fs.writeFileSync(filename, JSON.stringify(report, null, 2));
  console.log(`Structured JSON report generated: ${filename}`);
}

