import { jest, describe, it, expect, beforeEach } from '@jest/globals';
import { KosliClient } from '../src/kosli';
import { getCommitHistory, getInitialCommit } from '../src/git';
import { resolveBaseTag } from '../src/baseTagResolver';

jest.mock('../src/kosli');
jest.mock('../src/git');

const MockKosliClient = jest.mocked(KosliClient);
const mockGetCommitHistory = jest.mocked(getCommitHistory);
const mockGetInitialCommit = jest.mocked(getInitialCommit);

const SHA_A = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const SHA_B = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const SHA_C = 'cccccccccccccccccccccccccccccccccccccccc';
const SHA_INITIAL = '0000000000000000000000000000000000000000';

const mockListTrails = jest.fn<() => Promise<Set<string>>>();

describe('resolveBaseTag', () => {
  beforeEach(() => {
    jest.resetAllMocks();
    MockKosliClient.mockImplementation(() => ({
      listTrailsWithAttestationName: mockListTrails,
    } as any));
    mockGetInitialCommit.mockReturnValue(SHA_INITIAL);
  });

  it('should return the commit SHA when a matching commit is found', async () => {
    mockGetCommitHistory.mockReturnValue([SHA_A, SHA_B, SHA_C]);
    mockListTrails.mockResolvedValue(new Set([SHA_B]));

    const result = await resolveBaseTag('my-flow', 'scr-data', 'v1.1.0', '/repo');

    expect(result).toBe(SHA_B);
  });

  it('should return the initial commit when no qualifying commit is found', async () => {
    mockGetCommitHistory.mockReturnValue([SHA_A, SHA_B, SHA_C]);
    mockListTrails.mockResolvedValue(new Set());

    const result = await resolveBaseTag('my-flow', 'scr-data', 'v1.1.0', '/repo');

    expect(result).toBe(SHA_INITIAL);
  });

  it('should skip the first commit in history (currentTag itself)', async () => {
    mockGetCommitHistory.mockReturnValue([SHA_A, SHA_B]);
    mockListTrails.mockResolvedValue(new Set([SHA_A, SHA_B]));

    const result = await resolveBaseTag('my-flow', 'scr-data', 'v1.1.0', '/repo');

    expect(result).toBe(SHA_B);
  });

  it('should return the closest (most recent) matching commit', async () => {
    mockGetCommitHistory.mockReturnValue([SHA_A, SHA_B, SHA_C]);
    mockListTrails.mockResolvedValue(new Set([SHA_B, SHA_C]));

    const result = await resolveBaseTag('my-flow', 'scr-data', 'v1.1.0', '/repo');

    expect(result).toBe(SHA_B);
  });
});
