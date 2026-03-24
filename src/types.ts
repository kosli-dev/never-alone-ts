export interface Config {
  serviceName: string;
  releaseBranch: string;
  baseTag: string;
  currentTag: string;
  releaseCommitSha: string;
  githubRepository: string;
  githubToken: string;
  exemptions: {
    serviceAccounts: string[];
    filePaths: string[];
    fileNames: string[];
  };
}

export interface CommitInfo {
  sha: string;
  author: string;
  date: Date;
  message: string;
}

export interface EvaluationResult {
  commit: CommitInfo;
  status: 'PASS' | 'FAIL';
  reason: string;
  prNumber?: number;
}
