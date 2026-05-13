import { jest, describe, it, expect, beforeEach } from '@jest/globals';
import { execSync } from 'child_process';
import { getCommits } from '../src/git';

jest.mock('child_process');
const mockExecSync = jest.mocked(execSync);

describe('Git Interaction', () => {
  beforeEach(() => {
    mockExecSync.mockClear();
  });

  it('should parse commits from git log output', () => {
    const mockOutput = 'sha1||p1||author1||email1||2023-01-01T00:00:00Z||msg1\nsha2||p2 p3||author2||email2||2023-01-02T00:00:00Z||msg2';
    mockExecSync.mockReturnValue(mockOutput);

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
    mockExecSync.mockReturnValue('');
    const commits = getCommits('v1.0.0', 'v1.1.0');
    expect(commits).toHaveLength(0);
  });
});
