import { execSync } from 'child_process';
import { getCommits, getChangedFiles, isMergeCommit } from '../src/git';

jest.mock('child_process');

describe('Git Interaction', () => {
  it('should parse commits from git log output', () => {
    const mockOutput = 'sha1||author1||2023-01-01T00:00:00Z||msg1\nsha2||author2||2023-01-02T00:00:00Z||msg2';
    (execSync as jest.Mock).mockReturnValue(mockOutput);

    const commits = getCommits('v1.0.0', 'v1.1.0');

    expect(commits).toHaveLength(2);
    expect(commits[0].sha).toBe('sha1');
    expect(commits[0].author).toBe('author1');
    expect(commits[1].message).toBe('msg2');
  });

  it('should return empty list if git log is empty', () => {
    (execSync as jest.Mock).mockReturnValue('');
    const commits = getCommits('v1.0.0', 'v1.1.0');
    expect(commits).toHaveLength(0);
  });

  it('should get changed files', () => {
    (execSync as jest.Mock).mockReturnValue('file1.txt\nfile2.js\n');
    const files = getChangedFiles('sha123');
    expect(files).toEqual(['file1.txt', 'file2.js']);
  });

  it('should detect merge commit', () => {
    (execSync as jest.Mock)
      .mockReturnValueOnce('p1 p2') // First call for parents
      .mockReturnValueOnce('Merge pull request #123'); // Second call for subject
      
    expect(isMergeCommit('sha123')).toBe(true);
  });

  it('should not detect non-merge commit', () => {
    (execSync as jest.Mock)
      .mockReturnValueOnce('p1') // First call for parents
      .mockReturnValueOnce('feat: some feature'); // Second call for subject
      
    expect(isMergeCommit('sha123')).toBe(false);
  });
});
