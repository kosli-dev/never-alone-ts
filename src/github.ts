import { Octokit } from '@octokit/rest';
import { throttling } from '@octokit/plugin-throttling';
import { PRDetails, UserIdentity } from './types';

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

  async findPRForCommit(sha: string): Promise<number[]> {
    try {
      const q = `is:pr is:merged sha:${sha} repo:${this.owner}/${this.repo}`;
      const response = await this.octokit.search.issuesAndPullRequests({ q });
      return response.data.items.map((item: any) => item.number);
    } catch (error) {
      console.error(`Error searching PR for commit ${sha}: ${error}`);
      return [];
    }
  }

  async getPRFullDetails(prNumber: number): Promise<PRDetails | undefined> {
    try {
      const [pr, reviews, commits] = await Promise.all([
        this.octokit.pulls.get({ owner: this.owner, repo: this.repo, pull_number: prNumber }),
        this.octokit.pulls.listReviews({ owner: this.owner, repo: this.repo, pull_number: prNumber }),
        this.octokit.paginate(this.octokit.pulls.listCommits, { owner: this.owner, repo: this.repo, pull_number: prNumber, per_page: 100 }),
      ]);

      return {
        number: prNumber,
        url: pr.data.html_url,
        title: pr.data.title,
        author: {
          login: pr.data.user?.login,
          user_id: pr.data.user?.id,
          web_url: pr.data.user?.html_url,
        },
        state: pr.data.state,
        merged_at: pr.data.merged_at || null,
        approvals: reviews.data
          .filter((r: any) => r.state === 'APPROVED')
          .map((r: any) => ({
            user: {
              login: r.user?.login,
              user_id: r.user?.id,
              web_url: r.user?.html_url,
            },
            approved_at: r.submitted_at,
          })),
        commits: commits.map((c: any) => ({
          sha: c.sha,
          parent_shas: c.parents.map((p: any) => p.sha),
          author: {
            git_name: c.commit.author?.name,
            git_email: c.commit.author?.email,
            login: c.author?.login,
            user_id: c.author?.id,
            web_url: c.author?.html_url,
          },
          date: new Date(c.commit.author?.date || 0),
          message: c.commit.message,
        })),
      };
    } catch (error) {
      console.error(`Error fetching full details for PR #${prNumber}: ${error}`);
      return undefined;
    }
  }

  async getCommitDetails(sha: string): Promise<UserIdentity | undefined> {
    try {
      const response = await this.octokit.repos.getCommit({
        owner: this.owner,
        repo: this.repo,
        ref: sha,
      });
      return {
        login: response.data.author?.login,
        user_id: response.data.author?.id,
        web_url: response.data.author?.html_url,
      };
    } catch (error) {
      console.error(`Error fetching commit details for ${sha}: ${error}`);
      return undefined;
    }
  }
}
