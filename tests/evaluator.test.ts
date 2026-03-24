import { Evaluator } from '../src/evaluator';
import { Config, CommitInfo } from '../src/types';
import { getChangedFiles, isMergeCommit } from '../src/git';
import { GitHubClient } from '../src/github';

jest.mock('../src/git');

describe('Evaluator', () => {
  const mockConfig: Config = {
    baseTag: 'v1.0.0',
    currentTag: 'v1.1.0',
    githubRepository: 'owner/repo',
    githubToken: 'token',
    exemptions: {
      serviceAccounts: ['svc_.*'],
      filePaths: ['docs/release-notes.md'],
      fileNames: ['README.md'],
    },
  };

  let evaluator: Evaluator;
  let mockGitHub: any;

  beforeEach(() => {
    jest.resetAllMocks();
    mockGitHub = {
      findPRForCommit: jest.fn(),
      getPRFullDetails: jest.fn(),
      getCommitDetails: jest.fn(),
    };
    evaluator = new Evaluator(mockConfig, mockGitHub as unknown as GitHubClient);
    mockGitHub.getCommitDetails.mockResolvedValue({});
  });

  it('should pass if commit is from a service account', async () => {
    const commit: CommitInfo = {
      sha: 'sha123',
      parent_shas: ['parent123'],
      author: { git_name: 'svc_deployer' },
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
      parent_shas: ['parent123'],
      author: { git_name: 'human' },
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
      parent_shas: ['parent123'],
      author: { git_name: 'human' },
      date: new Date(),
      message: 'msg',
    };

    (getChangedFiles as jest.Mock).mockReturnValue(['README.md', 'src/app.ts']);
    (isMergeCommit as jest.Mock).mockReturnValue(false);
    mockGitHub.findPRForCommit.mockResolvedValue(undefined);
    
    const result = await evaluator.evaluateCommit(commit);
    expect(result.status).toBe('FAIL');
  });

  it('should pass if commit is a merge commit', async () => {
    const commit: CommitInfo = {
      sha: 'sha123',
      parent_shas: ['parent1', 'parent2'],
      author: { git_name: 'human' },
      date: new Date(),
      message: 'msg',
    };

    (getChangedFiles as jest.Mock).mockReturnValue(['src/app.ts']);
    (isMergeCommit as jest.Mock).mockReturnValue(true);
    
    const result = await evaluator.evaluateCommit(commit);
    expect(result.status).toBe('PASS');
    expect(result.reason).toContain('Merge commit');
  });

  it('should pass if PR is independently approved after the latest PR commit', async () => {
    const commitDate = new Date('2023-01-01T10:00:00Z');
    const approvalDate = new Date('2023-01-01T11:00:00Z');
    const commit: CommitInfo = {
      sha: 'sha123',
      parent_shas: ['parent123'],
      author: { git_name: 'author1', github_login: 'gh-author1' },
      date: commitDate,
      message: 'msg',
    };

    (getChangedFiles as jest.Mock).mockReturnValue(['src/app.ts']);
    (isMergeCommit as jest.Mock).mockReturnValue(false);
    mockGitHub.findPRForCommit.mockResolvedValue(123);
    mockGitHub.getPRFullDetails.mockResolvedValue({
      number: 123,
      commits: [{ sha: 'sha123', parent_shas: ['parent123'], date: commitDate }],
      approvals: [{ user: { github_login: 'gh-approver1' }, timestamp: approvalDate.toISOString() }]
    });
    
    const result = await evaluator.evaluateCommit(commit);
    expect(result.status).toBe('PASS');
    expect(result.associated_pr_number).toBe(123);
  });

});


