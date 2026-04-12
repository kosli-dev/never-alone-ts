import * as fs from 'fs';
import { generateAttestationData } from '../src/reporter';
import { Config, CommitData, PRDetails } from '../src/types';

jest.mock('fs');

const mockConfig: Config = {
  baseTag: 'v1.0.0',
  currentTag: 'v1.1.0',
  githubRepository: 'owner/repo',
  githubToken: 'token',
  kosliFlow: '',
  kosliAttestationName: 'scr-data',
  exemptions: {
    serviceAccounts: ['svc_.*'],
    filePaths: ['docs/release-notes.md'],
    fileNames: ['README.md'],
  },
};

const mockCommit: CommitData = {
  sha: 'abc123',
  parent_shas: ['parent1'],
  author: { login: 'alice' },
  date: '2023-01-01T10:00:00.000Z',
  message: 'feat: add feature',
  changed_files: ['src/app.ts'],
  pr_numbers: [42],
};

const mockPR: PRDetails = {
  number: 42,
  url: 'https://github.com/owner/repo/pull/42',
  title: 'Add feature',
  author: { login: 'alice' },
  state: 'closed',
  merged_at: '2023-01-01T11:00:00Z',
  approvals: [{ user: { login: 'bob' }, approved_at: '2023-01-01T10:30:00Z' }],
  commits: [],
};

describe('Reporter', () => {
  beforeEach(() => jest.resetAllMocks());

  it('should write to att_data_<currentTag>.json', () => {
    generateAttestationData([], {}, mockConfig);
    expect(fs.writeFileSync).toHaveBeenCalledWith('att_data_v1.1.0.json', expect.any(String));
  });

  it('should embed config exemptions in the output', () => {
    generateAttestationData([], {}, mockConfig);
    const written = JSON.parse((fs.writeFileSync as jest.Mock).mock.calls[0][1]);
    expect(written.config.exemptions).toEqual(mockConfig.exemptions);
  });

  it('should include commits and pull_requests in the output', () => {
    generateAttestationData([mockCommit], { '42': mockPR }, mockConfig);
    const written = JSON.parse((fs.writeFileSync as jest.Mock).mock.calls[0][1]);
    expect(written.commits).toHaveLength(1);
    expect(written.commits[0].sha).toBe('abc123');
    expect(written.pull_requests['42'].number).toBe(42);
  });

  it('should include repository and range in the output', () => {
    generateAttestationData([], {}, mockConfig, 'baseSha123', 'currentSha456');
    const written = JSON.parse((fs.writeFileSync as jest.Mock).mock.calls[0][1]);
    expect(written.repository).toBe('owner/repo');
    expect(written.range.base).toBe('v1.0.0');
    expect(written.range.current).toBe('v1.1.0');
    expect(written.range.base_sha).toBe('baseSha123');
    expect(written.range.current_sha).toBe('currentSha456');
  });

  it('should set generated_at to a valid ISO timestamp', () => {
    generateAttestationData([], {}, mockConfig);
    const written = JSON.parse((fs.writeFileSync as jest.Mock).mock.calls[0][1]);
    expect(() => new Date(written.generated_at).toISOString()).not.toThrow();
  });
});
