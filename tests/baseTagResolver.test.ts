import { jest, describe, it, expect, beforeEach } from '@jest/globals';

const mockListTrails = jest.fn();
const MockKosliClient = jest.fn();
const mockGetCommitHistory = jest.fn();
const mockGetInitialCommit = jest.fn();

(jest as any).unstable_mockModule('../src/kosli.js', () => ({
  KosliClient: MockKosliClient,
}));
(jest as any).unstable_mockModule('../src/git.js', () => ({
  getCommitHistory: mockGetCommitHistory,
  getInitialCommit: mockGetInitialCommit,
}));

const { resolveBaseTag } = await import('../src/baseTagResolver.js');

const SHA_A = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const SHA_B = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const SHA_C = 'cccccccccccccccccccccccccccccccccccccccc';
const SHA_INITIAL = '0000000000000000000000000000000000000000';

describe('resolveBaseTag', () => {
  beforeEach(() => {
    jest.resetAllMocks();
    MockKosliClient.mockImplementation(() => ({
      listTrailsWithAttestationName: mockListTrails,
    }));
    mockGetInitialCommit.mockReturnValue(SHA_INITIAL);
  });

  it('should return the commit SHA when a matching commit is found', async () => {
    // History: SHA_A (current) → SHA_B (has attestation) → SHA_C
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
    // SHA_A is currentTag — even though it has an attestation it must be skipped
    mockGetCommitHistory.mockReturnValue([SHA_A, SHA_B]);
    mockListTrails.mockResolvedValue(new Set([SHA_A, SHA_B]));

    const result = await resolveBaseTag('my-flow', 'scr-data', 'v1.1.0', '/repo');

    expect(result).toBe(SHA_B);
  });

  it('should return the closest (most recent) matching commit', async () => {
    // Both SHA_B and SHA_C qualify — SHA_B is closer
    mockGetCommitHistory.mockReturnValue([SHA_A, SHA_B, SHA_C]);
    mockListTrails.mockResolvedValue(new Set([SHA_B, SHA_C]));

    const result = await resolveBaseTag('my-flow', 'scr-data', 'v1.1.0', '/repo');

    expect(result).toBe(SHA_B);
  });
});
