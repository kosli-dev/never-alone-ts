import { resolveBaseTag } from '../src/baseTagResolver';
import { KosliClient } from '../src/kosli';
import { getCommitHistory, getInitialCommit } from '../src/git';

jest.mock('../src/kosli');
jest.mock('../src/git');

const SHA_A = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const SHA_B = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const SHA_C = 'cccccccccccccccccccccccccccccccccccccccc';
const SHA_INITIAL = '0000000000000000000000000000000000000000';

describe('resolveBaseTag', () => {
  let mockListTrails: jest.Mock;

  beforeEach(() => {
    jest.resetAllMocks();
    mockListTrails = jest.fn();
    (KosliClient as jest.Mock).mockImplementation(() => ({
      listTrailsWithAttestationName: mockListTrails,
    }));
    (getInitialCommit as jest.Mock).mockReturnValue(SHA_INITIAL);
  });

  it('should return the commit SHA when a matching commit is found', async () => {
    // History: SHA_A (current) → SHA_B (has attestation) → SHA_C
    (getCommitHistory as jest.Mock).mockReturnValue([SHA_A, SHA_B, SHA_C]);
    mockListTrails.mockResolvedValue(new Set([SHA_B]));

    const result = await resolveBaseTag('my-flow', 'scr-data', 'v1.1.0', '/repo');

    expect(result).toBe(SHA_B);
  });

  it('should return the initial commit when no qualifying commit is found', async () => {
    (getCommitHistory as jest.Mock).mockReturnValue([SHA_A, SHA_B, SHA_C]);
    mockListTrails.mockResolvedValue(new Set());

    const result = await resolveBaseTag('my-flow', 'scr-data', 'v1.1.0', '/repo');

    expect(result).toBe(SHA_INITIAL);
  });

  it('should skip the first commit in history (currentTag itself)', async () => {
    // SHA_A is currentTag — even though it has an attestation it must be skipped
    (getCommitHistory as jest.Mock).mockReturnValue([SHA_A, SHA_B]);
    mockListTrails.mockResolvedValue(new Set([SHA_A, SHA_B]));

    const result = await resolveBaseTag('my-flow', 'scr-data', 'v1.1.0', '/repo');

    expect(result).toBe(SHA_B);
  });

  it('should return the closest (most recent) matching commit', async () => {
    // Both SHA_B and SHA_C qualify — SHA_B is closer
    (getCommitHistory as jest.Mock).mockReturnValue([SHA_A, SHA_B, SHA_C]);
    mockListTrails.mockResolvedValue(new Set([SHA_B, SHA_C]));

    const result = await resolveBaseTag('my-flow', 'scr-data', 'v1.1.0', '/repo');

    expect(result).toBe(SHA_B);
  });
});
