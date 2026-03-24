import * as path from 'path';
import { CommitInfo, Config, EvaluationResult } from './types';
import { getChangedFiles, isMergeCommit } from './git';
import { GitHubClient } from './github';

export class Evaluator {
  constructor(private config: Config, private github: GitHubClient, private repoPath: string = process.cwd()) {}

  async evaluateCommit(commit: CommitInfo): Promise<EvaluationResult> {
    // Enhance commit author with github info
    const githubAuthor = await this.github.getCommitDetails(commit.sha);
    if (githubAuthor) {
      commit.author.github_login = githubAuthor.github_login;
      commit.author.github_id = githubAuthor.github_id;
      commit.author.html_url = githubAuthor.html_url;
    }

    // 1. Service Account Commit
    for (const pattern of this.config.exemptions.serviceAccounts) {
      if (new RegExp(pattern).test(commit.author.git_name || '') || (commit.author.github_login && new RegExp(pattern).test(commit.author.github_login))) {
        return { commit, status: 'PASS', reason: `Service Account match: ${pattern}` };
      }
    }

    // 2. Exempted File Modification
    const changedFiles = getChangedFiles(commit.sha, this.repoPath);
    const allExempted = changedFiles.every(file => {
      const basename = path.basename(file);
      const isPathExempted = this.config.exemptions.filePaths.includes(file);
      const isNameExempted = this.config.exemptions.fileNames.includes(basename);
      return isPathExempted || isNameExempted;
    });

    if (changedFiles.length > 0 && allExempted) {
      return { commit, status: 'PASS', reason: 'All changed files are exempted.' };
    }

    // 3. Merge Commit
    if (isMergeCommit(commit.sha, this.repoPath)) {
      return { commit, status: 'PASS', reason: 'Merge commit.' };
    }

    // 4. Pull Request Review
    const prNumber = await this.github.findPRForCommit(commit.sha);
    if (!prNumber) {
      return { commit, status: 'FAIL', reason: 'No associated Pull Request found.' };
    }

    const pr_details = await this.github.getPRFullDetails(prNumber);
    if (!pr_details) {
      return { commit, status: 'FAIL', reason: `Could not fetch details for PR #${prNumber}.`, associated_pr_number: prNumber };
    }

    const prDates = pr_details.commits.map(c => c.date.getTime());
    const latestPRCommitTime = Math.max(...prDates);

    const independentApproval = pr_details.approvals.find(approval => {
      const isIndependent = approval.user.github_login !== commit.author.github_login;
      const approvalTime = new Date(approval.timestamp).getTime();
      const isApprovedAfterCode = approvalTime > latestPRCommitTime;
      
      return isIndependent && isApprovedAfterCode;
    });

    if (independentApproval) {
      return { 
        commit, 
        status: 'PASS', 
        reason: `PR #${prNumber} approved by ${independentApproval.user.github_login} after latest PR commit.`, 
        associated_pr_number: prNumber,
        pr_details
      };
    }

    return { 
      commit, 
      status: 'FAIL', 
      reason: `PR #${prNumber} does not have an independent approval after the latest commit in the PR.`, 
      associated_pr_number: prNumber,
      pr_details
    };
  }
}
