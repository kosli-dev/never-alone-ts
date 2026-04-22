import * as fs from 'fs';
import { generateGranularAttestation } from '../src/reporter';
import { CommitSummary, PRSummary } from '../src/types';

jest.mock('fs');

const mockConfig = {
  githubRepository: 'owner/repo',
  exemptions: { serviceAccounts: ['svc_.*'] },
};

const mockCommitSummary: CommitSummary = {
  sha: 'abc123def456abc123def456abc123def456abc1',
  parent_shas: ['parent1'],
  author: { login: 'alice' },
  date: '2023-01-01T10:00:00.000Z',
  message: 'feat: add feature',
  changed_files: ['src/app.ts'],
};

const mockPR: PRSummary = {
  number: 42,
  url: 'https://github.com/owner/repo/pull/42',
  title: 'Add feature',
  state: 'closed',
  merged_at: '2023-01-01T11:00:00Z',
  author: { login: 'alice' },
  approvals: [{ user: { login: 'bob' }, approved_at: '2023-01-01T10:30:00Z' }],
  pr_commits: [],
};

describe('Reporter', () => {
  beforeEach(() => jest.resetAllMocks());

  it('should write att_data_<sha>.json and raw_<sha>.json', () => {
    generateGranularAttestation(mockCommitSummary, [], { githubCommit: {}, prRaws: [] }, mockConfig);
    const calls = (fs.writeFileSync as jest.Mock).mock.calls.map((c: any[]) => c[0]);
    expect(calls).toContain(`att_data_${mockCommitSummary.sha}.json`);
    expect(calls).toContain(`raw_${mockCommitSummary.sha}.json`);
  });

  it('should embed config exemptions in the attestation output', () => {
    generateGranularAttestation(mockCommitSummary, [], { githubCommit: {}, prRaws: [] }, mockConfig);
    const attCall = (fs.writeFileSync as jest.Mock).mock.calls.find((c: any[]) => c[0].startsWith('att_data_'));
    const written = JSON.parse(attCall[1]);
    expect(written.config.exemptions).toEqual(mockConfig.exemptions);
  });

  it('should include commit and pull_requests in the attestation output', () => {
    generateGranularAttestation(mockCommitSummary, [mockPR], { githubCommit: {}, prRaws: [] }, mockConfig);
    const attCall = (fs.writeFileSync as jest.Mock).mock.calls.find((c: any[]) => c[0].startsWith('att_data_'));
    const written = JSON.parse(attCall[1]);
    expect(written.commit.sha).toBe(mockCommitSummary.sha);
    expect(written.pull_requests).toHaveLength(1);
    expect(written.pull_requests[0].number).toBe(42);
  });

  it('should include repository and commit_sha in the attestation output', () => {
    generateGranularAttestation(mockCommitSummary, [], { githubCommit: {}, prRaws: [] }, mockConfig);
    const attCall = (fs.writeFileSync as jest.Mock).mock.calls.find((c: any[]) => c[0].startsWith('att_data_'));
    const written = JSON.parse(attCall[1]);
    expect(written.repository).toBe('owner/repo');
    expect(written.commit_sha).toBe(mockCommitSummary.sha);
  });

  it('should set generated_at to a valid ISO timestamp', () => {
    generateGranularAttestation(mockCommitSummary, [], { githubCommit: {}, prRaws: [] }, mockConfig);
    const attCall = (fs.writeFileSync as jest.Mock).mock.calls.find((c: any[]) => c[0].startsWith('att_data_'));
    const written = JSON.parse(attCall[1]);
    expect(() => new Date(written.generated_at).toISOString()).not.toThrow();
  });
});
