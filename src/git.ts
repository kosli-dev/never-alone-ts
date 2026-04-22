import { execSync } from 'child_process';
import { CommitInfo } from './types';

export function getCommits(baseTag: string, currentTag: string, repoPath: string = process.cwd()): CommitInfo[] {
  const range = baseTag ? `${baseTag}..${currentTag}` : currentTag;
  const command = `git log ${range} --first-parent --pretty="format:%H||%P||%an||%ae||%aI||%s"`;
  
  try {
    const output = execSync(command, { encoding: 'utf8', cwd: repoPath });
    if (!output.trim()) return [];
    
    return output.trim().split('\n').map(line => {
      const [sha, parents, name, email, dateStr, message] = line.split('||');
      return {
        sha,
        parent_shas: parents ? parents.split(' ') : [],
        author: {
          git_name: name,
          git_email: email,
        },
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

export function getCommitHistory(ref: string, repoPath: string = process.cwd()): string[] {
  try {
    const output = execSync(`git log ${ref} --first-parent --pretty=format:%H`, { encoding: 'utf8', cwd: repoPath });
    return output.trim().split('\n').filter(line => line.length > 0);
  } catch (error) {
    console.error(`Error getting commit history for ${ref}: ${error}`);
    throw error;
  }
}


export function getInitialCommit(repoPath: string = process.cwd()): string {
  try {
    return execSync('git rev-list --max-parents=0 HEAD', { encoding: 'utf8', cwd: repoPath }).trim();
  } catch (error) {
    console.error(`Error getting initial commit: ${error}`);
    throw error;
  }
}

export function getSingleCommit(sha: string, repoPath: string = process.cwd()): CommitInfo {
  const command = `git show -s --pretty="format:%H||%P||%an||%ae||%aI||%s" ${sha}`;
  try {
    const output = execSync(command, { encoding: 'utf8', cwd: repoPath });
    const [shaOut, parents, name, email, dateStr, message] = output.trim().split('||');
    return {
      sha: shaOut,
      parent_shas: parents ? parents.trim().split(' ') : [],
      author: { git_name: name, git_email: email },
      date: new Date(dateStr),
      message,
    };
  } catch (error) {
    console.error(`Error getting single commit ${sha}: ${error}`);
    throw error;
  }
}

export function isMergeCommit(sha: string, repoPath: string = process.cwd()): boolean {
  try {
    const parentCount = execSync(`git show -s --format=%p ${sha}`, { encoding: 'utf8', cwd: repoPath }).trim().split(' ').length;
    return parentCount > 1;
  } catch (error) {
    console.error(`Error checking merge commit for ${sha}: ${error}`);
    return false;
  }
}
