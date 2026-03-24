import { Octokit } from '@octokit/rest';
import { throttling } from '@octokit/plugin-throttling';

const ThrottledOctokit = Octokit.plugin(throttling as any);

export class GitHubClient {
  private octokit: any;
  private owner: string;
  private repo: string;

  constructor(repository: string, token: string) {
    const [owner, repo] = repository.split('/');
    this.owner = owner;
    this.repo = repo;
    
    this.octokit = new ThrottledOctokit({
      auth: token,
      throttle: {
        onRateLimit: (retryAfter: number, options: any, octokit: any, retryCount: number) => {
          octokit.log.warn(`Request quota exhausted for request ${options.method} ${options.url}`);
          if (retryCount < 3) {
            octokit.log.info(`Retrying after ${retryAfter} seconds!`);
            return true;
          }
        },
        onSecondaryRateLimit: (retryAfter: number, options: any, octokit: any) => {
          octokit.log.warn(`Secondary rate limit exceeded for request ${options.method} ${options.url}`);
          return true; // retry
        },
      },
    });
  }

  async findPRForCommit(sha: string): Promise<number | undefined> {
    try {
      const q = `is:pr is:merged sha:${sha}`;
      const response = await this.octokit.search.issuesAndPullRequests({ q });
      
      if (response.data.total_count > 0) {
        return response.data.items[0].number;
      }
      return undefined;
    } catch (error) {
      // If we already handled the rate limit via throttling, we shouldn't reach here unless all retries failed
      console.error(`Error searching PR for commit ${sha}: ${error}`);
      return undefined;
    }
  }

  async getPRReviews(prNumber: number) {
    try {
      const response = await this.octokit.pulls.listReviews({
        owner: this.owner,
        repo: this.repo,
        pull_number: prNumber,
      });
      return response.data;
    } catch (error) {
      console.error(`Error fetching reviews for PR #${prNumber}: ${error}`);
      return [];
    }
  }

  async getPRCommits(prNumber: number) {
    try {
      const response = await this.octokit.pulls.listCommits({
        owner: this.owner,
        repo: this.repo,
        pull_number: prNumber,
      });
      return response.data;
    } catch (error) {
      console.error(`Error fetching commits for PR #${prNumber}: ${error}`);
      return [];
    }
  }
}
