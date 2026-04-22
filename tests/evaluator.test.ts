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
      getPRSummaryAndRaw: jest.fn(),
      getRawCommitData: jest.fn().mockResolvedValue({}),
    };
    collector = new Collector(mockGitHub as unknown as GitHubClient);
  });

  it('should collect commit summary with changed files and no PR', async () => {
    const commit: CommitInfo = {
      sha: 'sha123',
      parent_shas: ['parent123'],
      author: { git_name: 'Alice' },
      date: new Date('2023-01-01T10:00:00Z'),
      message: 'feat: add feature',
    };

    (getChangedFiles as jest.Mock).mockReturnValue(['src/app.ts']);
    mockGitHub.findPRForCommit.mockResolvedValue([]);

    const { commitSummary, pullRequests } = await collector.collectCommitGranular(commit);

    expect(commitSummary.sha).toBe('sha123');
    expect(commitSummary.changed_files).toEqual(['src/app.ts']);
    expect(pullRequests).toEqual([]);
  });

  it('should collect commit summary with PR data', async () => {
    const commit: CommitInfo = {
      sha: 'sha123',
      parent_shas: ['parent123'],
      author: { git_name: 'Alice', login: 'alice' },
      date: new Date('2023-01-01T10:00:00Z'),
      message: 'feat: add feature',
    };

    const mockSummary = {
      number: 42,
      url: 'https://github.com/owner/repo/pull/42',
      title: 'Add feature',
      author: { login: 'alice' },
      state: 'closed',
      merged_at: '2023-01-01T11:00:00Z',
      approvals: [{ user: { login: 'bob' }, approved_at: '2023-01-01T10:30:00Z' }],
      pr_commits: [{ sha: 'sha123', parent_shas: ['parent123'], author: { login: 'alice' }, date: '2023-01-01T10:00:00Z', message: 'feat: add feature' }],
    };
    const mockRaw = { number: 42, github_pr: {}, github_reviews: [], github_commits: [] };

    (getChangedFiles as jest.Mock).mockReturnValue(['src/app.ts']);
    mockGitHub.findPRForCommit.mockResolvedValue([42]);
    mockGitHub.getPRSummaryAndRaw.mockResolvedValue({ summary: mockSummary, raw: mockRaw });

    const { commitSummary, pullRequests } = await collector.collectCommitGranular(commit);

    expect(commitSummary.sha).toBe('sha123');
    expect(pullRequests).toHaveLength(1);
    expect(pullRequests[0].number).toBe(42);
  });

  it('should enrich author with GitHub identity', async () => {
    const commit: CommitInfo = {
      sha: 'sha123',
      parent_shas: ['parent123'],
      author: { git_name: 'Alice' },
      date: new Date(),
      message: 'msg',
    };

    mockGitHub.getRawCommitData.mockResolvedValue({
      author: { login: 'alice-gh', id: 12345, html_url: 'https://github.com/alice-gh' },
    });
    (getChangedFiles as jest.Mock).mockReturnValue([]);
    mockGitHub.findPRForCommit.mockResolvedValue([]);

    const { commitSummary } = await collector.collectCommitGranular(commit);

    expect(commitSummary.author.login).toBe('alice-gh');
    expect(commitSummary.author.user_id).toBe(12345);
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
    mockGitHub.findPRForCommit.mockResolvedValue([]);

    const { commitSummary } = await collector.collectCommitGranular(commit);

    expect(commitSummary.date).toBe('2023-06-15T12:00:00.000Z');
  });

  it('should preserve existing author fields when getRawCommitData returns no author', async () => {
    const commit: CommitInfo = {
      sha: 'sha123',
      parent_shas: [],
      author: { git_name: 'Alice', git_email: 'alice@example.com' },
      date: new Date(),
      message: 'msg',
    };

    mockGitHub.getRawCommitData.mockResolvedValue({});
    (getChangedFiles as jest.Mock).mockReturnValue([]);
    mockGitHub.findPRForCommit.mockResolvedValue([]);

    const { commitSummary } = await collector.collectCommitGranular(commit);

    expect(commitSummary.author.git_name).toBe('Alice');
    expect(commitSummary.author.git_email).toBe('alice@example.com');
    expect(commitSummary.author.login).toBeUndefined();
  });

  it('should return empty pullRequests when getPRSummaryAndRaw returns null', async () => {
    const commit: CommitInfo = {
      sha: 'sha123',
      parent_shas: ['parent123'],
      author: { git_name: 'Alice' },
      date: new Date(),
      message: 'msg',
    };

    (getChangedFiles as jest.Mock).mockReturnValue(['src/app.ts']);
    mockGitHub.findPRForCommit.mockResolvedValue([42]);
    mockGitHub.getPRSummaryAndRaw.mockResolvedValue(null);

    const { pullRequests } = await collector.collectCommitGranular(commit);

    expect(pullRequests).toEqual([]);
  });

  it('should return empty changed_files array when git returns nothing', async () => {
    const commit: CommitInfo = {
      sha: 'sha123',
      parent_shas: [],
      author: { git_name: 'Alice' },
      date: new Date(),
      message: 'msg',
    };

    (getChangedFiles as jest.Mock).mockReturnValue([]);
    mockGitHub.findPRForCommit.mockResolvedValue([]);

    const { commitSummary } = await collector.collectCommitGranular(commit);

    expect(commitSummary.changed_files).toEqual([]);
  });
});
