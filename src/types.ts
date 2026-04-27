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

export interface CommitInfo {
  sha: string;
  parent_shas: string[];
  author: {
    git_name?: string;
    git_email?: string;
  };
  date: Date;
  message: string;
}
