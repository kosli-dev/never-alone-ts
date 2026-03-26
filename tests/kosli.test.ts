import { execSync } from 'child_process';
import { KosliClient } from '../src/kosli';

jest.mock('child_process');

const mockTrail = (sha: string, attestationNames: string[]) => ({
  name: sha.substring(0, 7),
  git_commit_info: { sha1: sha },
  compliance_status: {
    attestations_statuses: attestationNames.map(name => ({ attestation_name: name })),
  },
});

const makeResponse = (trails: any[], total = trails.length) =>
  JSON.stringify({ data: trails, pagination: { total } });

describe('KosliClient', () => {
  let client: KosliClient;

  beforeEach(() => {
    jest.resetAllMocks();
    client = new KosliClient();
  });

  it('should return SHAs of trails that have the target attestation', async () => {
    (execSync as jest.Mock).mockReturnValue(makeResponse([
      mockTrail('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', ['scr-data', 'lint']),
      mockTrail('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', ['lint']),
    ]));

    const result = await client.listTrailsWithAttestationName('my-flow', 'scr-data');

    expect(result.size).toBe(1);
    expect(result.has('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')).toBe(true);
    expect(result.has('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb')).toBe(false);
  });

  it('should skip trails with null git_commit_info', async () => {
    (execSync as jest.Mock).mockReturnValue(JSON.stringify({
      data: [{ name: 'abc', git_commit_info: null, compliance_status: { attestations_statuses: [{ attestation_name: 'scr-data' }] } }],
    }));

    const result = await client.listTrailsWithAttestationName('my-flow', 'scr-data');

    expect(result.size).toBe(0);
  });

  it('should accumulate results across multiple pages', async () => {
    const page1 = Array.from({ length: 100 }, (_, i) =>
      mockTrail(`${'a'.repeat(39)}${i.toString().padStart(1, '0')}`, ['scr-data']),
    );
    const page2 = [mockTrail('cccccccccccccccccccccccccccccccccccccccc', ['scr-data'])];

    (execSync as jest.Mock)
      .mockReturnValueOnce(makeResponse(page1))
      .mockReturnValueOnce(makeResponse(page2));

    const result = await client.listTrailsWithAttestationName('my-flow', 'scr-data');

    expect(result.size).toBe(101);
    expect((execSync as jest.Mock)).toHaveBeenCalledTimes(2);
  });

  it('should stop paginating when page returns fewer than 100 results', async () => {
    (execSync as jest.Mock).mockReturnValue(makeResponse([
      mockTrail('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', ['scr-data']),
    ]));

    await client.listTrailsWithAttestationName('my-flow', 'scr-data');

    expect((execSync as jest.Mock)).toHaveBeenCalledTimes(1);
  });

  it('should return empty set when no trails match', async () => {
    (execSync as jest.Mock).mockReturnValue(makeResponse([]));

    const result = await client.listTrailsWithAttestationName('my-flow', 'scr-data');

    expect(result.size).toBe(0);
  });
});
