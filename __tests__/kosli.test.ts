import { jest, describe, it, expect, beforeEach } from '@jest/globals';
import { spawnSync } from 'child_process';
import { KosliClient } from '../src/kosli';

jest.mock('child_process');
const mockSpawnSync = jest.mocked(spawnSync);

type KosliClientType = InstanceType<typeof KosliClient>;

const mockTrail = (sha: string, attestationNames: string[]) => ({
  name: sha.substring(0, 7),
  git_commit_info: { sha1: sha },
  compliance_status: {
    attestations_statuses: attestationNames.map(name => ({ attestation_name: name })),
  },
});

const makeResponse = (trails: unknown[], total = trails.length) =>
  JSON.stringify({ data: trails, pagination: { total } });

describe('KosliClient', () => {
  let client: KosliClientType;

  beforeEach(() => {
    jest.resetAllMocks();
    client = new KosliClient();
  });

  it('should return SHAs of trails that have the target attestation', async () => {
    mockSpawnSync.mockReturnValue({ stdout: makeResponse([
      mockTrail('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', ['scr-data', 'lint']),
      mockTrail('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', ['lint']),
    ]), stderr: '', status: 0, pid: 0, output: [], signal: null });

    const result = await client.listTrailsWithAttestationName('my-flow', 'scr-data');

    expect(result.size).toBe(1);
    expect(result.has('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')).toBe(true);
    expect(result.has('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb')).toBe(false);
  });

  it('should skip trails with null git_commit_info', async () => {
    mockSpawnSync.mockReturnValue({ stdout: JSON.stringify({
      data: [{ name: 'abc', git_commit_info: null, compliance_status: { attestations_statuses: [{ attestation_name: 'scr-data' }] } }],
    }), stderr: '', status: 0, pid: 0, output: [], signal: null });

    const result = await client.listTrailsWithAttestationName('my-flow', 'scr-data');

    expect(result.size).toBe(0);
  });

  it('should accumulate results across multiple pages', async () => {
    const page1 = Array.from({ length: 100 }, (_, i) =>
      mockTrail(`${'a'.repeat(39)}${i.toString().padStart(1, '0')}`, ['scr-data']),
    );
    const page2 = [mockTrail('cccccccccccccccccccccccccccccccccccccccc', ['scr-data'])];

    mockSpawnSync
      .mockReturnValueOnce({ stdout: makeResponse(page1), stderr: '', status: 0, pid: 0, output: [], signal: null })
      .mockReturnValueOnce({ stdout: makeResponse(page2), stderr: '', status: 0, pid: 0, output: [], signal: null });

    const result = await client.listTrailsWithAttestationName('my-flow', 'scr-data');

    expect(result.size).toBe(101);
    expect(mockSpawnSync).toHaveBeenCalledTimes(2);
  });

  it('should stop paginating when page returns fewer than 100 results', async () => {
    mockSpawnSync.mockReturnValue({ stdout: makeResponse([
      mockTrail('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', ['scr-data']),
    ]), stderr: '', status: 0, pid: 0, output: [], signal: null });

    await client.listTrailsWithAttestationName('my-flow', 'scr-data');

    expect(mockSpawnSync).toHaveBeenCalledTimes(1);
  });

  it('should return empty set when no trails match', async () => {
    mockSpawnSync.mockReturnValue({ stdout: makeResponse([]), stderr: '', status: 0, pid: 0, output: [], signal: null });

    const result = await client.listTrailsWithAttestationName('my-flow', 'scr-data');

    expect(result.size).toBe(0);
  });
});
