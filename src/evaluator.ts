import { CommitData, CommitInfo, PRDetails } from './types';
import { getChangedFiles } from './git';
import { GitHubClient } from './github';

export class Collector {
  constructor(private github: GitHubClient, private repoPath: string = process.cwd()) {}

  async collectCommit(commit: CommitInfo): Promise<{ commitData: CommitData; prDetails?: PRDetails }> {
    const githubAuthor = await this.github.getCommitDetails(commit.sha);
    if (githubAuthor) {
      commit.author.login = githubAuthor.login;
      commit.author.user_id = githubAuthor.user_id;
      commit.author.web_url = githubAuthor.web_url;
    }

    const changedFiles = getChangedFiles(commit.sha, this.repoPath);
    const prNumber = await this.github.findPRForCommit(commit.sha);

    let prDetails: PRDetails | undefined;
    if (prNumber) {
      prDetails = await this.github.getPRFullDetails(prNumber) ?? undefined;
    }

    return {
      commitData: {
        sha: commit.sha,
        parent_shas: commit.parent_shas,
        author: commit.author,
        date: commit.date.toISOString(),
        message: commit.message,
        changed_files: changedFiles,
        pr_number: prNumber,
      },
      prDetails,
    };
  }
}
