import { jest, describe, it, expect, beforeEach } from '@jest/globals';
import { KosliClient } from '../src/kosli';
import { getCommitHistory, getInitialCommit } from '../src/git';
import { resolveBaseTag } from '../src/baseTagResolver';

jest.mock('../src/kosli');
jest.mock('../src/git');

const MockedKosliClient = KosliClient as jest.MockedClass<typeof KosliClient>;
const mockedGetCommitHistory = getCommitHistory as jest.Mock;
const mockedGetInitialCommit = getInitialCommit as jest.Mock;


const SHA_A = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const SHA_B = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const SHA_C = 'cccccccccccccccccccccccccccccccccccccccc';
const SHA_INITIAL = '0000000000000000000000000000000000000000';

describe('resolveBaseTag', () => {
  beforeEach(() => {
    mockedGetCommitHistory.mockClear();
    mockedGetInitialCommit.mockClear();
    MockedKosliClient.mockClear();
  });

  it('should return the commit SHA when a matching commit is found', async () => {
    // History: SHA_A (current) → SHA_B (has attestation) → SHA_C
    mockedGetCommitHistory.mockReturnValue([SHA_A, SHA_B, SHA_C]);
    const listTrailsMock = jest.fn<() => Promise<Set<string>>>().mockResolvedValue(new Set([SHA_B]));
    MockedKosliClient.mockImplementation(() => ({
      listTrailsWithAttestationName: listTrailsMock,
    } as any));

    const result = await resolveBaseTag('my-flow', 'scr-data', 'v1.1.0', '/repo');

    expect(result).toBe(SHA_B);
  });

  it('should return the initial commit when no qualifying commit is found', async () => {
    mockedGetCommitHistory.mockReturnValue([SHA_A, SHA_B, SHA_C]);
    const listTrailsMock = jest.fn<() => Promise<Set<string>>>().mockResolvedValue(new Set());
    MockedKosliClient.mockImplementation(() => ({
      listTrailsWithAttestationName: listTrailsMock,
    } as any));
    mockedGetInitialCommit.mockReturnValue(SHA_INITIAL);

    const result = await resolveBaseTag('my-flow', 'scr-data', 'v1.1.0', '/repo');

    expect(result).toBe(SHA_INITIAL);
  });

  it('should skip the first commit in history (currentTag itself)', async () => {
    // SHA_A is currentTag — even though it has an attestation it must be skipped
    mockedGetCommitHistory.mockReturnValue([SHA_A, SHA_B]);
    const listTrailsMock = jest.fn<() => Promise<Set<string>>>().mockResolvedValue(new Set([SHA_A, SHA_B]));
    MockedKosliClient.mockImplementation(() => ({
      listTrailsWithAttestationName: listTrailsMock,
    } as any));

    const result = await resolveBaseTag('my-flow', 'scr-data', 'v1.1.0', '/repo');

    expect(result).toBe(SHA_B);
  });

  it('should return the closest (most recent) matching commit', async () => {
    // Both SHA_B and SHA_C qualify — SHA_B is closer
    mockedGetCommitHistory.mockReturnValue([SHA_A, SHA_B, SHA_C]);
    const listTrailsMock = jest.fn<() => Promise<Set<string>>>().mockResolvedValue(new Set([SHA_B, SHA_C]));
    MockedKosliClient.mockImplementation(() => ({
      listTrailsWithAttestationName: listTrailsMock,
    } as any));

    const result = await resolveBaseTag('my-flow', 'scr-data', 'v1.1.0', '/repo');

    expect(result).toBe(SHA_B);
  });
});
