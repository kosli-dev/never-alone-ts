import { jest, describe, it, expect, beforeEach } from '@jest/globals';
import { spawn, spawnSync } from 'child_process';
import { KosliClient } from '../src/kosli';

jest.mock('child_process');
const mockSpawn = jest.mocked(spawn);
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

const makeSpawnProcess = (exitCode: number, error?: Error) => {
  const proc: any = {
    on(event: string, handler: (value: number | Error) => void) {
      if (event === 'error' && error) {
        process.nextTick(() => handler(error));
      }

      if (event === 'close' && !error) {
        process.nextTick(() => handler(exitCode));
      }

      return proc;
    },
  };

  return proc;
};

const testConfig = {
  baseTag: '',
  currentTag: 'v1.1.0',
  githubRepository: 'owner/repo',
  githubToken: 'github-token',
  kosliFlow: 'my-flow',
  kosliAttestationName: 'pr-review',
};

describe('KosliClient', () => {
  let client: KosliClientType;

  beforeEach(() => {
    jest.resetAllMocks();
    client = new KosliClient();
  });

  it('should create a trail and then attest the pull request for a commit', async () => {
    mockSpawn
      .mockReturnValueOnce(makeSpawnProcess(0))
      .mockReturnValueOnce(makeSpawnProcess(0));

    await client.attestCommit('abc1234', testConfig, '/repo');

    expect(mockSpawn).toHaveBeenCalledTimes(2);
    expect(mockSpawn).toHaveBeenNthCalledWith(
      1,
      'kosli',
      ['begin', 'trail', 'abc1234', '--flow', 'my-flow', '--commit', 'abc1234', '--repo-root', '/repo'],
      expect.objectContaining({
        stdio: 'inherit',
        env: expect.any(Object),
      }),
    );
    expect(mockSpawn).toHaveBeenNthCalledWith(
      2,
      'kosli',
      ['attest', 'pullrequest', 'github', '--name', 'pr-review', '--github-org', 'owner', '--commit', 'abc1234', '--repo-root', '/repo', '--repository', 'owner/repo', '--flow', 'my-flow', '--trail', 'abc1234'],
      expect.objectContaining({
        stdio: 'inherit',
        env: expect.objectContaining({
          KOSLI_GITHUB_TOKEN: 'github-token',
        }),
      }),
    );
  });

  it('should stop if trail creation fails', async () => {
    mockSpawn.mockReturnValueOnce(makeSpawnProcess(1));

    await expect(client.attestCommit('abc1234', testConfig, '/repo')).rejects.toThrow('kosli begin trail exited with code 1');

    expect(mockSpawn).toHaveBeenCalledTimes(1);
  });

  it('should surface pull request attestation failures', async () => {
    mockSpawn
      .mockReturnValueOnce(makeSpawnProcess(0))
      .mockReturnValueOnce(makeSpawnProcess(2));

    await expect(client.attestCommit('abc1234', testConfig, '/repo')).rejects.toThrow('kosli attest pullrequest exited with code 2');

    expect(mockSpawn).toHaveBeenCalledTimes(2);
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
