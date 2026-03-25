export interface Config {
  baseTag: string;
  currentTag: string;
  githubRepository: string;
  githubToken: string;
  exemptions: {
    serviceAccounts: string[];
    filePaths: string[];
    fileNames: string[];
  };
  behaviours: {
    postApprovalMergeCommits: 'strict' | 'ignore';
  };
}

export interface UserIdentity {
  git_name?: string;
  git_email?: string;
  github_login?: string;
  github_id?: number;
  html_url?: string;
}

export interface CommitInfo {
  sha: string;
  parent_shas: string[];
  author: UserIdentity;
  date: Date;
  message: string;
}

export interface PRDetails {
  number: number;
  url: string;
  title: string;
  author: UserIdentity;
  state: string;
  merged_at: string | null;
  approvals: {
    user: UserIdentity;
    timestamp: string;
  }[];
  commits: CommitInfo[];
}

export interface EvaluationResult {
  commit: CommitInfo;
  status: 'PASS' | 'FAIL';
  reason: string;
  associated_pr_number?: number;
  pr_details?: PRDetails;
}

export interface StructuredReport {
  report_info: {
    repository: string;
    range: {
      base: string;
      base_sha?: string;
      current: string;
      current_sha?: string;
    };
    generated_at: string;
    overall_status: 'PASSED' | 'FAILED';
  };
  main_branch_commits: {
    sha: string;
    parent_shas: string[];
    author: UserIdentity;
    date: string;
    message: string;
    evaluation: {
      status: 'PASS' | 'FAIL';
      reason: string;
    };
    associated_pr_number?: number;
  }[];
  pull_requests: Record<string, PRDetails>;
}

