import { jest, describe, it, expect, beforeEach } from '@jest/globals';

const mockSpawnSync = jest.fn();

(jest as any).unstable_mockModule('child_process', () => ({
  spawn: jest.fn(),
  spawnSync: mockSpawnSync,
}));

const { KosliClient } = await import('../src/kosli.js');
type KosliClientType = InstanceType<typeof KosliClient>;

const spawnResult = (json: string) =>
  ({ stdout: json, stderr: '', status: 0, error: undefined, pid: 0, output: [], signal: null });

const mockTrail = (sha: string, attestationNames: string[]) => ({
  name: sha.substring(0, 7),
  git_commit_info: { sha1: sha },
  compliance_status: {
    attestations_statuses: attestationNames.map(name => ({ attestation_name: name })),
  },
});

const makeResponse = (trails: unknown[]) => JSON.stringify({ data: trails });

describe('KosliClient', () => {
  let client: KosliClientType;

  beforeEach(() => {
    jest.resetAllMocks();
    client = new KosliClient();
  });

  it('should return SHAs of trails that have the target attestation', async () => {
    mockSpawnSync.mockReturnValue(spawnResult(makeResponse([
      mockTrail('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', ['scr-data', 'lint']),
      mockTrail('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', ['lint']),
    ])));

    const result = await client.listTrailsWithAttestationName('my-flow', 'scr-data');

    expect(result.size).toBe(1);
    expect(result.has('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')).toBe(true);
    expect(result.has('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb')).toBe(false);
  });

  it('should skip trails with null git_commit_info', async () => {
    mockSpawnSync.mockReturnValue(spawnResult(JSON.stringify({
      data: [{ name: 'abc', git_commit_info: null, compliance_status: { attestations_statuses: [{ attestation_name: 'scr-data' }] } }],
    })));

    const result = await client.listTrailsWithAttestationName('my-flow', 'scr-data');

    expect(result.size).toBe(0);
  });

  it('should accumulate results across multiple pages', async () => {
    const page1 = Array.from({ length: 100 }, (_, i) =>
      mockTrail(`${'a'.repeat(39)}${i.toString().padStart(1, '0')}`, ['scr-data']),
    );
    const page2 = [mockTrail('cccccccccccccccccccccccccccccccccccccccc', ['scr-data'])];

    mockSpawnSync
      .mockReturnValueOnce(spawnResult(makeResponse(page1)))
      .mockReturnValueOnce(spawnResult(makeResponse(page2)));

    const result = await client.listTrailsWithAttestationName('my-flow', 'scr-data');

    expect(result.size).toBe(101);
    expect(mockSpawnSync).toHaveBeenCalledTimes(2);
  });

  it('should stop paginating when page returns fewer than 100 results', async () => {
    mockSpawnSync.mockReturnValue(spawnResult(makeResponse([
      mockTrail('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', ['scr-data']),
    ])));

    await client.listTrailsWithAttestationName('my-flow', 'scr-data');

    expect(mockSpawnSync).toHaveBeenCalledTimes(1);
  });

  it('should return empty set when no trails match', async () => {
    mockSpawnSync.mockReturnValue(spawnResult(makeResponse([])));

    const result = await client.listTrailsWithAttestationName('my-flow', 'scr-data');

    expect(result.size).toBe(0);
  });
});
