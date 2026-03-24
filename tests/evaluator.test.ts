import { Evaluator } from '../src/evaluator';
import { Config, CommitInfo } from '../src/types';
import { getChangedFiles, isMergeCommit } from '../src/git';
import { GitHubClient } from '../src/github';

jest.mock('../src/git');
jest.mock('../src/github');

describe('Evaluator', () => {
  const mockConfig: Config = {
    serviceName: 'test',
    releaseBranch: 'main',
    baseTag: 'v1.0.0',
    currentTag: 'v1.1.0',
    releaseCommitSha: 'sha',
    githubRepository: 'owner/repo',
    githubToken: 'token',
    exemptions: {
      serviceAccounts: ['svc_.*'],
      filePaths: ['docs/release-notes.md'],
      fileNames: ['README.md'],
    },
  };

  let mockGithub: jest.Mocked<GitHubClient>;
  let evaluator: Evaluator;

  beforeEach(() => {
    mockGithub = new GitHubClient('owner/repo', 'token') as jest.Mocked<GitHubClient>;
    evaluator = new Evaluator(mockConfig, mockGithub);
    jest.resetAllMocks();
  });

  it('should pass if commit is from a service account', async () => {
    const commit: CommitInfo = {
      sha: 'sha123',
      author: 'svc_deployer',
      date: new Date(),
      message: 'msg',
    };

    const result = await evaluator.evaluateCommit(commit);
    expect(result.status).toBe('PASS');
    expect(result.reason).toContain('Service Account');
  });

  it('should pass if all changed files are exempted', async () => {
    const commit: CommitInfo = {
      sha: 'sha123',
      author: 'human',
      date: new Date(),
      message: 'msg',
    };

    (getChangedFiles as jest.Mock).mockReturnValue(['README.md', 'docs/release-notes.md']);
    
    const result = await evaluator.evaluateCommit(commit);
    expect(result.status).toBe('PASS');
    expect(result.reason).toContain('exempted');
  });

  it('should fail if any changed file is not exempted', async () => {
    const commit: CommitInfo = {
      sha: 'sha123',
      author: 'human',
      date: new Date(),
      message: 'msg',
    };

    (getChangedFiles as jest.Mock).mockReturnValue(['README.md', 'src/app.ts']);
    (isMergeCommit as jest.Mock).mockReturnValue(false);
    mockGithub.findPRForCommit.mockResolvedValue(undefined);
    
    const result = await evaluator.evaluateCommit(commit);
    expect(result.status).toBe('FAIL');
  });

  it('should pass if commit is a merge commit', async () => {
    const commit: CommitInfo = {
      sha: 'sha123',
      author: 'human',
      date: new Date(),
      message: 'msg',
    };

    (getChangedFiles as jest.Mock).mockReturnValue(['src/app.ts']);
    (isMergeCommit as jest.Mock).mockReturnValue(true);
    
    const result = await evaluator.evaluateCommit(commit);
    expect(result.status).toBe('PASS');
    expect(result.reason).toContain('Merge commit');
  });

  it('should pass if PR is independently approved before the commit', async () => {
    const commitDate = new Date('2023-01-01T10:00:00Z');
    const approvalDate = new Date('2023-01-01T11:00:00Z');
    const commit: CommitInfo = {
      sha: 'sha123',
      author: 'author1',
      date: commitDate,
      message: 'msg',
    };

    (getChangedFiles as jest.Mock).mockReturnValue(['src/app.ts']);
    (isMergeCommit as jest.Mock).mockReturnValue(false);
    mockGithub.findPRForCommit.mockResolvedValue(123);
    mockGithub.getPRReviews.mockResolvedValue([
      { state: 'APPROVED', user: { login: 'approver1' }, submitted_at: approvalDate.toISOString() } as any,
    ]);
    
    const result = await evaluator.evaluateCommit(commit);
    expect(result.status).toBe('PASS');
    expect(result.prNumber).toBe(123);
  });

  it('should fail if PR is approved by the same author', async () => {
    const commitDate = new Date('2023-01-01T10:00:00Z');
    const approvalDate = new Date('2023-01-01T11:00:00Z');
    const commit: CommitInfo = {
      sha: 'sha123',
      author: 'author1',
      date: commitDate,
      message: 'msg',
    };

    (getChangedFiles as jest.Mock).mockReturnValue(['src/app.ts']);
    (isMergeCommit as jest.Mock).mockReturnValue(false);
    mockGithub.findPRForCommit.mockResolvedValue(123);
    mockGithub.getPRReviews.mockResolvedValue([
      { state: 'APPROVED', user: { login: 'author1' }, submitted_at: approvalDate.toISOString() } as any,
    ]);
    
    const result = await evaluator.evaluateCommit(commit);
    expect(result.status).toBe('FAIL');
    expect(result.reason).toContain('does not have an independent approval');
  });

  it('should fail if PR is approved BEFORE the commit date', async () => {
    // Note: The logic in src/evaluator.ts says:
    // const isApprovedBefore = approvalDate ? approvalDate.getTime() > commit.date.getTime() : false;
    // So "isApprovedBefore" here means "Approval Date is LATER than Commit Date".
    // Wait, let's re-read the requirement: "Verify that the commit's author date is earlier than the date of the independent approval."
    // Yes, Commit Date < Approval Date.
    
    const commitDate = new Date('2023-01-01T12:00:00Z');
    const approvalDate = new Date('2023-01-01T10:00:00Z');
    const commit: CommitInfo = {
      sha: 'sha123',
      author: 'author1',
      date: commitDate,
      message: 'msg',
    };

    (getChangedFiles as jest.Mock).mockReturnValue(['src/app.ts']);
    (isMergeCommit as jest.Mock).mockReturnValue(false);
    mockGithub.findPRForCommit.mockResolvedValue(123);
    mockGithub.getPRReviews.mockResolvedValue([
      { state: 'APPROVED', user: { login: 'approver1' }, submitted_at: approvalDate.toISOString() } as any,
    ]);
    
    const result = await evaluator.evaluateCommit(commit);
    expect(result.status).toBe('FAIL');
  });
});
