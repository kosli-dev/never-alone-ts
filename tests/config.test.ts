import { jest, describe, it, expect, beforeEach, afterAll } from '@jest/globals';

const mockDotenvConfig = jest.fn();

(jest as any).unstable_mockModule('dotenv', () => ({
  config: mockDotenvConfig,
}));

const { loadConfig } = await import('../src/config.js');

describe('loadConfig', () => {
  const originalEnv = process.env;

  beforeEach(() => {
    process.env = { ...originalEnv };
  });

  afterAll(() => {
    process.env = originalEnv;
  });

  it('should load configuration successfully from environment variables', () => {
    process.env.BASE_TAG = 'v1.0.0';
    process.env.CURRENT_TAG = 'v1.1.0';
    process.env.GITHUB_REPOSITORY = 'owner/repo';
    process.env.GITHUB_TOKEN = 'token123';
    process.env.KOSLI_FLOW = 'test-flow';

    const config = loadConfig();

    expect(config.currentTag).toBe('v1.1.0');
    expect(config.baseTag).toBe('v1.0.0');
    expect(config.githubRepository).toBe('owner/repo');
    expect(config.kosliFlow).toBe('test-flow');
    expect(config.kosliAttestationName).toBe('pr-review');
  });

  it('should default kosliAttestationName to pr-review', () => {
    process.env.CURRENT_TAG = 'v1.1.0';
    process.env.GITHUB_REPOSITORY = 'owner/repo';
    process.env.GITHUB_TOKEN = 'token123';
    process.env.KOSLI_FLOW = 'test-flow';
    delete process.env.KOSLI_ATTESTATION_NAME;

    const config = loadConfig();

    expect(config.kosliAttestationName).toBe('pr-review');
  });

  it('should throw error if CURRENT_TAG is missing', () => {
    process.env.CURRENT_TAG = '';
    process.env.GITHUB_REPOSITORY = 'owner/repo';
    process.env.GITHUB_TOKEN = 'token123';
    process.env.KOSLI_FLOW = 'test-flow';

    expect(() => loadConfig()).toThrow('Missing required environment variables');
  });

  it('should throw error if KOSLI_FLOW is missing', () => {
    process.env.CURRENT_TAG = 'v1.1.0';
    process.env.GITHUB_REPOSITORY = 'owner/repo';
    process.env.GITHUB_TOKEN = 'token123';
    process.env.KOSLI_FLOW = '';

    expect(() => loadConfig()).toThrow('Missing required environment variables');
  });

  it('should throw error if GITHUB_TOKEN is missing', () => {
    process.env.CURRENT_TAG = 'v1.1.0';
    process.env.GITHUB_REPOSITORY = 'owner/repo';
    process.env.GITHUB_TOKEN = '';
    process.env.KOSLI_FLOW = 'test-flow';

    expect(() => loadConfig()).toThrow('Missing required environment variables');
  });
});
