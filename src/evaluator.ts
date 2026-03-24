import * as path from 'path';
import { CommitInfo, Config, EvaluationResult } from './types';
import { getChangedFiles, isMergeCommit } from './git';
import { GitHubClient } from './github';

export class Evaluator {
  constructor(private config: Config, private github: GitHubClient, private repoPath: string = process.cwd()) {}

  async evaluateCommit(commit: CommitInfo): Promise<EvaluationResult> {
    // 1. Service Account Commit
    for (const pattern of this.config.exemptions.serviceAccounts) {
      if (new RegExp(pattern).test(commit.author)) {
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

    const reviews = await this.github.getPRReviews(prNumber);
    const independentApproval = reviews.find((review: any) => {
      if (review.state !== 'APPROVED' || !review.user) return false;
      
      const isIndependent = review.user.login !== commit.author;
      const approvalDate = review.submitted_at ? new Date(review.submitted_at) : null;
      const isApprovedBefore = approvalDate ? approvalDate.getTime() > commit.date.getTime() : false;
      
      return isIndependent && isApprovedBefore;
    });

    if (independentApproval) {
      return { commit, status: 'PASS', reason: `PR #${prNumber} approved by ${independentApproval.user?.login}.`, prNumber };
    }

    return { commit, status: 'FAIL', reason: `PR #${prNumber} does not have an independent approval before the commit.`, prNumber };
  }
}
