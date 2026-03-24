import { execSync } from 'child_process';
import { CommitInfo } from './types';

export function getCommits(baseTag: string, currentTag: string, releaseBranch: string, repoPath: string = process.cwd()): CommitInfo[] {
  const range = baseTag ? `${baseTag}..${currentTag}` : currentTag;
  const command = `git log ${range} --first-parent --pretty="format:%H||%an||%aI||%s"`;
  
  try {
    const output = execSync(command, { encoding: 'utf8', cwd: repoPath });
    if (!output.trim()) return [];
    
    return output.trim().split('\n').map(line => {
      const [sha, author, dateStr, message] = line.split('||');
      return {
        sha,
        author,
        date: new Date(dateStr),
        message,
      };
    });
  } catch (error) {
    console.error(`Error executing git log: ${error}`);
    throw error;
  }
}

export function getChangedFiles(sha: string, repoPath: string = process.cwd()): string[] {
  const command = `git show --name-only --pretty="format:" ${sha}`;
  
  try {
    const output = execSync(command, { encoding: 'utf8', cwd: repoPath });
    return output.trim().split('\n').filter(line => line.length > 0);
  } catch (error) {
    console.error(`Error executing git show for ${sha}: ${error}`);
    throw error;
  }
}

export function isMergeCommit(sha: string, repoPath: string = process.cwd()): boolean {
  try {
    const parentCount = parseInt(execSync(`git show -s --format=%p ${sha}`, { encoding: 'utf8', cwd: repoPath }).trim().split(' ').length.toString());
    const message = execSync(`git show -s --format=%s ${sha}`, { encoding: 'utf8', cwd: repoPath }).trim();
    
    return parentCount > 1 || message.startsWith('Merge pull request #');
  } catch (error) {
    console.error(`Error checking merge commit for ${sha}: ${error}`);
    return false;
  }
}
