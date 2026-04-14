import { CommitData, CommitInfo, PRDetails } from './types';
import { getChangedFiles } from './git';
import { GitHubClient } from './github';

export class Collector {
  constructor(private github: GitHubClient, private repoPath: string = process.cwd()) {}

  async collectCommit(commit: CommitInfo): Promise<{ commitData: CommitData; prDetails: PRDetails[] }> {
    const [githubAuthor, prNumbers, changedFiles] = await Promise.all([
      this.github.getCommitDetails(commit.sha),
      this.github.findPRForCommit(commit.sha),
      Promise.resolve(getChangedFiles(commit.sha, this.repoPath)),
    ]);

    if (githubAuthor) {
      commit.author.login = githubAuthor.login;
      commit.author.user_id = githubAuthor.user_id;
      commit.author.web_url = githubAuthor.web_url;
    }

    const prDetails = (
      await Promise.all(prNumbers.map(n => this.github.getPRFullDetails(n)))
    ).filter((pr): pr is PRDetails => pr != null);

    return {
      commitData: {
        sha: commit.sha,
        parent_shas: commit.parent_shas,
        author: commit.author,
        date: commit.date.toISOString(),
        message: commit.message,
        changed_files: changedFiles,
        pr_numbers: prNumbers,
      },
      prDetails,
    };
  }
}
