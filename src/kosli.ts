import { spawn, spawnSync } from 'child_process';
import { KosliTrail } from './types.js';
import { Config } from './config.js';

const PAGE_LIMIT = 100;

export class KosliClient {
  private run(args: string[], env?: Record<string, string>): Promise<void> {
    return new Promise((resolve, reject) => {
      const proc = spawn('kosli', args, {
        stdio: 'inherit',
        env: { ...process.env, ...env },
      });
      proc.on('close', code => {
        if (code === 0) resolve();
        else reject(new Error(`kosli ${args.slice(0, 2).join(' ')} exited with code ${code}`));
      });
      proc.on('error', reject);
    });
  }

  async attestCommit(sha: string, config: Config, repoPath: string): Promise<void> {
    const githubOrg = config.githubRepository.split('/')[0];

    await this.run([
      'begin', 'trail', sha,
      '--flow', config.kosliFlow,
      '--commit', sha,
      '--repo-root', repoPath,
    ]);

    await this.run([
      'attest', 'pullrequest', 'github',
      '--name', config.kosliAttestationName,
      '--github-org', githubOrg,
      '--commit', sha,
      '--repo-root', repoPath,
      '--repository', config.githubRepository,
      '--flow', config.kosliFlow,
      '--trail', sha,
    ], { GITHUB_TOKEN: config.githubToken });
  }

  async listTrailsWithAttestationName(flow: string, attestationName: string): Promise<Set<string>> {
    const result = new Set<string>();
    let page = 1;

    while (true) {
      const proc = spawnSync(
        'kosli',
        ['list', 'trails', '--flow', flow, '--page', String(page), '--page-limit', String(PAGE_LIMIT), '-o', 'json'],
        { encoding: 'utf8' },
      );
      if (proc.error) throw proc.error;
      if (proc.status !== 0) throw new Error(`kosli list trails exited with code ${proc.status}\n${proc.stderr}`);
      const output = proc.stdout;

      const response = JSON.parse(output);
      const trails: KosliTrail[] = response.data || [];

      for (const trail of trails) {
        if (!trail.git_commit_info?.sha1) continue;
        const hasAttestation = trail.compliance_status.attestations_statuses
          .some(a => a.attestation_name === attestationName);
        if (hasAttestation) {
          result.add(trail.git_commit_info.sha1);
        }
      }

      if (trails.length < PAGE_LIMIT) break;
      page++;
    }

    return result;
  }
}
