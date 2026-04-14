import { execSync } from 'child_process';
import { getCommits, getChangedFiles, isMergeCommit } from '../src/git';

jest.mock('child_process');

describe('Git Interaction', () => {
  it('should parse commits from git log output', () => {
    const mockOutput = 'sha1||p1||author1||email1||2023-01-01T00:00:00Z||msg1\nsha2||p2 p3||author2||email2||2023-01-02T00:00:00Z||msg2';
    (execSync as jest.Mock).mockReturnValue(mockOutput);

    const commits = getCommits('v1.0.0', 'v1.1.0');

    expect(commits).toHaveLength(2);
    expect(commits[0].sha).toBe('sha1');
    expect(commits[0].parent_shas).toEqual(['p1']);
    expect(commits[0].author.git_name).toBe('author1');
    expect(commits[0].author.git_email).toBe('email1');
    expect(commits[1].sha).toBe('sha2');
    expect(commits[1].parent_shas).toEqual(['p2', 'p3']);
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

  it('should detect merge commit by parent count', () => {
    (execSync as jest.Mock).mockReturnValueOnce('p1 p2');
    expect(isMergeCommit('sha123')).toBe(true);
  });

  it('should not detect non-merge commit', () => {
    (execSync as jest.Mock).mockReturnValueOnce('p1');
    expect(isMergeCommit('sha123')).toBe(false);
  });

  it('should not treat "Merge pull request #" message as merge commit when single parent', () => {
    (execSync as jest.Mock).mockReturnValueOnce('p1');
    expect(isMergeCommit('sha123')).toBe(false);
  });
});
