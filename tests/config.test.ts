import { loadConfig } from '../src/config';
import * as fs from 'fs';

jest.mock('fs');
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

  it('should load configuration successfully from environment and file', () => {
    process.env.BASE_TAG = 'v1.0.0';
    process.env.CURRENT_TAG = 'v1.1.0';
    process.env.GITHUB_REPOSITORY = 'owner/repo';
    process.env.GITHUB_TOKEN = 'token123';

    const mockConfig = {
      exemptions: {
        serviceAccounts: ['svc_.*'],
        filePaths: ['docs/release-notes.md'],
        fileNames: ['README.md'],
      },
    };

    (fs.existsSync as jest.Mock).mockReturnValue(true);
    (fs.readFileSync as jest.Mock).mockReturnValue(JSON.stringify(mockConfig));

    const config = loadConfig();

    expect(config.currentTag).toBe('v1.1.0');
    expect(config.exemptions.serviceAccounts).toContain('svc_.*');
    expect(config.exemptions.filePaths).toContain('docs/release-notes.md');
  });

  it('should throw error if required environment variables are missing', () => {
    process.env.CURRENT_TAG = '';
    expect(() => loadConfig()).toThrow('Missing required environment variables');
  });

  it('should throw error if scr.config.json is missing', () => {
    process.env.CURRENT_TAG = 'v1.1.0';
    process.env.GITHUB_REPOSITORY = 'owner/repo';
    process.env.GITHUB_TOKEN = 'token123';

    (fs.existsSync as jest.Mock).mockReturnValue(false);

    expect(() => loadConfig()).toThrow('scr.config.json file not found at:');
  });
});
