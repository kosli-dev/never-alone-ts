import { jest, describe, it, expect, beforeEach } from '@jest/globals';

const mockedGetCommitHistory = jest.fn();
const mockedGetInitialCommit = jest.fn();
const MockedKosliClient = jest.fn();

(jest as any).unstable_mockModule('../src/kosli.js', () => ({
  KosliClient: MockedKosliClient,
}));
(jest as any).unstable_mockModule('../src/git.js', () => ({
  getCommitHistory: mockedGetCommitHistory,
  getInitialCommit: mockedGetInitialCommit,
}));

const { resolveBaseTag } = await import('../src/baseTagResolver.js');

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
    mockedGetCommitHistory.mockReturnValue([SHA_A, SHA_B, SHA_C]);
    const listTrailsMock = jest.fn<() => Promise<Set<string>>>().mockResolvedValue(new Set([SHA_B]));
    MockedKosliClient.mockImplementation(() => ({
      listTrailsWithAttestationName: listTrailsMock,
    }));

    const result = await resolveBaseTag('my-flow', 'scr-data', 'v1.1.0', '/repo');

    expect(result).toBe(SHA_B);
  });

  it('should return the initial commit when no qualifying commit is found', async () => {
    mockedGetCommitHistory.mockReturnValue([SHA_A, SHA_B, SHA_C]);
    const listTrailsMock = jest.fn<() => Promise<Set<string>>>().mockResolvedValue(new Set());
    MockedKosliClient.mockImplementation(() => ({
      listTrailsWithAttestationName: listTrailsMock,
    }));
    mockedGetInitialCommit.mockReturnValue(SHA_INITIAL);

    const result = await resolveBaseTag('my-flow', 'scr-data', 'v1.1.0', '/repo');

    expect(result).toBe(SHA_INITIAL);
  });

  it('should skip the first commit in history (currentTag itself)', async () => {
    mockedGetCommitHistory.mockReturnValue([SHA_A, SHA_B]);
    const listTrailsMock = jest.fn<() => Promise<Set<string>>>().mockResolvedValue(new Set([SHA_A, SHA_B]));
    MockedKosliClient.mockImplementation(() => ({
      listTrailsWithAttestationName: listTrailsMock,
    }));

    const result = await resolveBaseTag('my-flow', 'scr-data', 'v1.1.0', '/repo');

    expect(result).toBe(SHA_B);
  });

  it('should return the closest (most recent) matching commit', async () => {
    mockedGetCommitHistory.mockReturnValue([SHA_A, SHA_B, SHA_C]);
    const listTrailsMock = jest.fn<() => Promise<Set<string>>>().mockResolvedValue(new Set([SHA_B, SHA_C]));
    MockedKosliClient.mockImplementation(() => ({
      listTrailsWithAttestationName: listTrailsMock,
    }));

    const result = await resolveBaseTag('my-flow', 'scr-data', 'v1.1.0', '/repo');

    expect(result).toBe(SHA_B);
  });
});
