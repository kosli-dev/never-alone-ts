import { Collector } from '../src/evaluator';
import { CommitInfo } from '../src/types';
import { getChangedFiles } from '../src/git';
import { GitHubClient } from '../src/github';

jest.mock('../src/git');

describe('Collector', () => {
  let collector: Collector;
  let mockGitHub: any;

  beforeEach(() => {
    jest.resetAllMocks();
    mockGitHub = {
      findPRForCommit: jest.fn(),
      getPRFullDetails: jest.fn(),
      getCommitDetails: jest.fn().mockResolvedValue({}),
    };
    collector = new Collector(mockGitHub as unknown as GitHubClient);
  });

  it('should collect commit data with changed files and no PR', async () => {
    const commit: CommitInfo = {
      sha: 'sha123',
      parent_shas: ['parent123'],
      author: { git_name: 'Alice' },
      date: new Date('2023-01-01T10:00:00Z'),
      message: 'feat: add feature',
    };

    (getChangedFiles as jest.Mock).mockReturnValue(['src/app.ts']);
    mockGitHub.findPRForCommit.mockResolvedValue(undefined);

    const { commitData, prDetails } = await collector.collectCommit(commit);

    expect(commitData.sha).toBe('sha123');
    expect(commitData.changed_files).toEqual(['src/app.ts']);
    expect(commitData.pr_number).toBeUndefined();
    expect(prDetails).toBeUndefined();
  });

  it('should collect commit data with PR details', async () => {
    const commit: CommitInfo = {
      sha: 'sha123',
      parent_shas: ['parent123'],
      author: { git_name: 'Alice', github_login: 'alice' },
      date: new Date('2023-01-01T10:00:00Z'),
      message: 'feat: add feature',
    };

    const mockPR = {
      number: 42,
      url: 'https://github.com/owner/repo/pull/42',
      title: 'Add feature',
      author: { github_login: 'alice' },
      state: 'closed',
      merged_at: '2023-01-01T11:00:00Z',
      approvals: [{ user: { github_login: 'bob' }, timestamp: '2023-01-01T10:30:00Z' }],
      commits: [{ sha: 'sha123', parent_shas: ['parent123'], author: { github_login: 'alice' }, date: new Date('2023-01-01T10:00:00Z'), message: 'feat: add feature' }],
    };

    (getChangedFiles as jest.Mock).mockReturnValue(['src/app.ts']);
    mockGitHub.findPRForCommit.mockResolvedValue(42);
    mockGitHub.getPRFullDetails.mockResolvedValue(mockPR);

    const { commitData, prDetails } = await collector.collectCommit(commit);

    expect(commitData.pr_number).toBe(42);
    expect(prDetails).toEqual(mockPR);
  });

  it('should enrich author with GitHub identity', async () => {
    const commit: CommitInfo = {
      sha: 'sha123',
      parent_shas: ['parent123'],
      author: { git_name: 'Alice' },
      date: new Date(),
      message: 'msg',
    };

    mockGitHub.getCommitDetails.mockResolvedValue({
      github_login: 'alice-gh',
      github_id: 12345,
      html_url: 'https://github.com/alice-gh',
    });
    (getChangedFiles as jest.Mock).mockReturnValue([]);
    mockGitHub.findPRForCommit.mockResolvedValue(undefined);

    const { commitData } = await collector.collectCommit(commit);

    expect(commitData.author.github_login).toBe('alice-gh');
    expect(commitData.author.github_id).toBe(12345);
  });

  it('should serialize date as ISO string', async () => {
    const commit: CommitInfo = {
      sha: 'sha123',
      parent_shas: [],
      author: { git_name: 'Alice' },
      date: new Date('2023-06-15T12:00:00Z'),
      message: 'msg',
    };

    (getChangedFiles as jest.Mock).mockReturnValue([]);
    mockGitHub.findPRForCommit.mockResolvedValue(undefined);

    const { commitData } = await collector.collectCommit(commit);

    expect(commitData.date).toBe('2023-06-15T12:00:00.000Z');
  });
});
