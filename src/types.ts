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

export interface CommitData {
  sha: string;
  parent_shas: string[];
  author: UserIdentity;
  date: string;
  message: string;
  changed_files: string[];
  pr_number?: number;
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

export interface AttestationData {
  repository: string;
  range: {
    base: string;
    base_sha?: string;
    current: string;
    current_sha?: string;
  };
  generated_at: string;
  config: {
    exemptions: {
      serviceAccounts: string[];
      filePaths: string[];
      fileNames: string[];
    };
  };
  commits: CommitData[];
  pull_requests: Record<string, PRDetails>;
}
