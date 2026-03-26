import { execSync } from 'child_process';
import { KosliTrail } from './types';

const PAGE_LIMIT = 100;

export class KosliClient {
  async listTrailsWithAttestationName(flow: string, attestationName: string): Promise<Set<string>> {
    const result = new Set<string>();
    let page = 1;

    while (true) {
      const output = execSync(
        `kosli list trails --flow ${flow} --page ${page} --page-limit ${PAGE_LIMIT} -o json`,
        { encoding: 'utf8' },
      );

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
