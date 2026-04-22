import { loadConfig, loadGranularConfig } from '../src/config';

jest.mock('dotenv', () => ({
  config: jest.fn(),
}));

describe('Config Loader', () => {
  const originalEnv = process.env;

  beforeEach(() => {
    jest.resetModules();
    process.env = { ...originalEnv };
  });

  afterAll(() => {
    process.env = originalEnv;
  });

  describe('loadConfig', () => {
    it('should load configuration successfully from environment variables', () => {
      process.env.BASE_TAG = 'v1.0.0';
      process.env.CURRENT_TAG = 'v1.1.0';
      process.env.GITHUB_REPOSITORY = 'owner/repo';
      process.env.GITHUB_TOKEN = 'token123';

      const config = loadConfig();

      expect(config.currentTag).toBe('v1.1.0');
      expect(config.baseTag).toBe('v1.0.0');
      expect(config.githubRepository).toBe('owner/repo');
    });

    it('should throw error if required environment variables are missing', () => {
      process.env.CURRENT_TAG = '';
      expect(() => loadConfig()).toThrow('Missing required environment variables');
    });
  });

  describe('loadGranularConfig', () => {
    it('should load granular configuration from environment variables', () => {
      process.env.GITHUB_REPOSITORY = 'owner/repo';
      process.env.GITHUB_TOKEN = 'token123';

      const config = loadGranularConfig();

      expect(config.githubRepository).toBe('owner/repo');
      expect(config.githubToken).toBe('token123');
    });

    it('should throw error if GITHUB_REPOSITORY or GITHUB_TOKEN are missing', () => {
      process.env.GITHUB_REPOSITORY = '';
      process.env.GITHUB_TOKEN = '';
      expect(() => loadGranularConfig()).toThrow('Missing required environment variables');
    });
  });
});
