import { CommitInfo, CommitSummary, PRSummary, RawPRData } from './types';
import { getChangedFiles } from './git';
import { GitHubClient } from './github';

export class Collector {
  constructor(private github: GitHubClient, private repoPath: string = process.cwd()) {}

  async collectCommitGranular(commit: CommitInfo): Promise<{
    commitSummary: CommitSummary;
    pullRequests: PRSummary[];
    rawData: { githubCommit: unknown; prRaws: RawPRData[] };
  }> {
    const [githubCommitRaw, prNumbers, changedFiles] = await Promise.all([
      this.github.getRawCommitData(commit.sha),
      this.github.findPRForCommit(commit.sha),
      Promise.resolve(getChangedFiles(commit.sha, this.repoPath)),
    ]);

    const rawCommit = githubCommitRaw as any;
    if (rawCommit?.author) {
      commit.author.login = rawCommit.author?.login;
      commit.author.user_id = rawCommit.author?.id;
      commit.author.web_url = rawCommit.author?.html_url;
    }

    const prResults = (
      await Promise.all(prNumbers.map(n => this.github.getPRSummaryAndRaw(n)))
    ).filter((r): r is { summary: PRSummary; raw: RawPRData } => r != null);

    const commitSummary: CommitSummary = {
      sha: commit.sha,
      parent_shas: commit.parent_shas,
      author: commit.author,
      date: commit.date.toISOString(),
      message: commit.message,
      changed_files: changedFiles,
    };

    return {
      commitSummary,
      pullRequests: prResults.map(r => r.summary),
      rawData: {
        githubCommit: githubCommitRaw,
        prRaws: prResults.map(r => r.raw),
      },
    };
  }
}
