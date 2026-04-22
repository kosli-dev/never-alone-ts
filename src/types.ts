export interface Config {
  baseTag: string;
  currentTag: string;
  githubRepository: string;
  githubToken: string;
  kosliFlow: string;
  kosliAttestationName: string;
}

export interface KosliTrail {
  name: string;
  git_commit_info: {
    sha1: string;
  } | null;
  compliance_status: {
    attestations_statuses: {
      attestation_name: string;
    }[];
  };
}

export interface UserIdentity {
  git_name?: string;
  git_email?: string;
  login?: string;
  user_id?: number;
  web_url?: string;
}

export interface CommitInfo {
  sha: string;
  parent_shas: string[];
  author: UserIdentity;
  date: Date;
  message: string;
}

// ─── Granular (per-commit) attestation types ─────────────────────────────────

export interface CommitSummary {
  sha: string;
  parent_shas: string[];
  author: UserIdentity;
  date: string;
  message: string;
  changed_files: string[];
}

export interface PRCommitSummary {
  sha: string;
  parent_shas: string[];
  author: UserIdentity;
  date: string;
  message: string;
}

export interface PRSummary {
  number: number;
  url: string;
  title: string;
  state: string;
  merged_at: string | null;
  author: UserIdentity;
  approvals: {
    user: UserIdentity;
    approved_at: string;
  }[];
  pr_commits: PRCommitSummary[];
}

export interface CommitAttestation {
  commit_sha: string;
  repository: string;
  generated_at: string;
  commit: CommitSummary;
  pull_requests: PRSummary[];
}

export interface RawPRData {
  number: number;
  github_pr: unknown;
  github_reviews: unknown[];
  github_commits: unknown[];
}

export interface RawAttachment {
  commit_sha: string;
  provider: string;
  generated_at: string;
  github_commit: unknown;
  pull_requests: RawPRData[];
}
