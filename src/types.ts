export interface Config {
  baseTag: string;
  currentTag: string;
  githubRepository: string;
  githubToken: string;
  kosliFlow: string;
  kosliAttestationName: string;
  exemptions: {
    serviceAccounts: string[];
  };
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

export interface CommitData {
  sha: string;
  parent_shas: string[];
  author: UserIdentity;
  date: string;
  message: string;
  changed_files: string[];
  pr_numbers: number[];
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
    approved_at: string;
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
    };
  };
  commits: CommitData[];
  pull_requests: Record<string, PRDetails>;
}
