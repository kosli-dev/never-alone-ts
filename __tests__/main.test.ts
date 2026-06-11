import * as path from 'path';
import { jest, describe, it, expect, beforeEach, afterEach } from '@jest/globals';

const flushPromises = async () => {
  await new Promise(resolve => setImmediate(resolve));
};

describe('main CLI', () => {
  const originalArgv = process.argv;
  let exitSpy: jest.SpiedFunction<typeof process.exit>;
  let cwdSpy: jest.SpiedFunction<typeof process.cwd>;
  let errorSpy: jest.SpiedFunction<typeof console.error>;

  beforeEach(() => {
    jest.resetModules();
    jest.clearAllMocks();
    process.argv = ['node', 'main'];
    exitSpy = jest.spyOn(process, 'exit').mockImplementation((() => undefined) as never);
    cwdSpy = jest.spyOn(process, 'cwd').mockReturnValue('/workspace');
    errorSpy = jest.spyOn(console, 'error').mockImplementation(() => {});
  });

  afterEach(() => {
    process.argv = originalArgv;
    exitSpy.mockRestore();
    cwdSpy.mockRestore();
    errorSpy.mockRestore();
  });

  it('resolves the base tag when BASE_TAG is missing and attests each commit', async () => {
    const loadConfig = jest.fn((_options?: { envFile?: string }) => ({
      baseTag: '',
      currentTag: 'v1.1.0',
      githubRepository: 'owner/repo',
      githubToken: 'token123',
      kosliFlow: 'flow-a',
      kosliAttestationName: 'pr-review',
    }));
    const resolveBaseTag = jest.fn(async (_flow: string, _attestationName: string, _currentTag: string, _repoPath: string) => 'resolved-base');
    const getCommits = jest.fn((_baseTag: string, _currentTag: string, _repoPath: string) => [
      { sha: 'abc1234def', message: 'first commit' },
      { sha: 'def5678abc', message: 'second commit' },
    ]);
    const attestCommit = jest.fn(async (_sha: string, _config: object, _repoPath: string) => undefined);

    jest.doMock('p-limit', () => ({
      __esModule: true,
      default: jest.fn(() => (task: () => Promise<void>) => task()),
    }));
    jest.doMock('../src/config', () => ({ __esModule: true, loadConfig }));
    jest.doMock('../src/baseTagResolver', () => ({ __esModule: true, resolveBaseTag }));
    jest.doMock('../src/git', () => ({ __esModule: true, getCommits }));
    jest.doMock('../src/kosli', () => ({
      __esModule: true,
      KosliClient: jest.fn(() => ({ attestCommit })),
    }));

    process.argv = ['node', 'main', '--repo', './relative-repo', '--env-file', '.env.test'];

    await jest.isolateModulesAsync(async () => {
      await import('../src/main');
      await flushPromises();
    });

    const resolvedEnvFile = path.resolve('.env.test');
    const resolvedRepo = path.resolve('./relative-repo');

    expect(loadConfig).toHaveBeenCalledWith({ envFile: resolvedEnvFile });
    expect(resolveBaseTag).toHaveBeenCalledWith('flow-a', 'pr-review', 'v1.1.0', resolvedRepo);
    expect(getCommits).toHaveBeenCalledWith('resolved-base', 'v1.1.0', resolvedRepo);
    expect(attestCommit).toHaveBeenNthCalledWith(1, 'abc1234def', expect.any(Object), resolvedRepo);
    expect(attestCommit).toHaveBeenNthCalledWith(2, 'def5678abc', expect.any(Object), resolvedRepo);
    expect(exitSpy).toHaveBeenCalledWith(0);
  });

  it('uses the configured base tag without resolving it again', async () => {
    const loadConfig = jest.fn((_options?: { envFile?: string }) => ({
      baseTag: 'v1.0.0',
      currentTag: 'v1.1.0',
      githubRepository: 'owner/repo',
      githubToken: 'token123',
      kosliFlow: 'flow-a',
      kosliAttestationName: 'pr-review',
    }));
    const resolveBaseTag = jest.fn(async (_flow: string, _attestationName: string, _currentTag: string, _repoPath: string) => 'resolved-base');
    const getCommits = jest.fn((_baseTag: string, _currentTag: string, _repoPath: string) => []);
    const attestCommit = jest.fn(async (_sha: string, _config: object, _repoPath: string) => undefined);

    jest.doMock('p-limit', () => ({
      __esModule: true,
      default: jest.fn(() => (task: () => Promise<void>) => task()),
    }));
    jest.doMock('../src/config', () => ({ __esModule: true, loadConfig }));
    jest.doMock('../src/baseTagResolver', () => ({ __esModule: true, resolveBaseTag }));
    jest.doMock('../src/git', () => ({ __esModule: true, getCommits }));
    jest.doMock('../src/kosli', () => ({
      __esModule: true,
      KosliClient: jest.fn(() => ({ attestCommit })),
    }));

    await jest.isolateModulesAsync(async () => {
      await import('../src/main');
      await flushPromises();
    });

    expect(resolveBaseTag).not.toHaveBeenCalled();
    expect(getCommits).toHaveBeenCalledWith('v1.0.0', 'v1.1.0', '/workspace');
    expect(exitSpy).toHaveBeenCalledWith(0);
  });

  it('exits with an error when the commit range exceeds the hard limit', async () => {
    const loadConfig = jest.fn((_options?: { envFile?: string }) => ({
      baseTag: 'v1.0.0',
      currentTag: 'v1.1.0',
      githubRepository: 'owner/repo',
      githubToken: 'token123',
      kosliFlow: 'flow-a',
      kosliAttestationName: 'pr-review',
    }));
    const getCommits = jest.fn((_baseTag: string, _currentTag: string, _repoPath: string) => Array.from({ length: 5001 }, (_, i) => ({
      sha: `sha-${i}`,
      message: 'commit',
    })));
    const attestCommit = jest.fn(async (_sha: string, _config: object, _repoPath: string) => undefined);

    jest.doMock('p-limit', () => ({
      __esModule: true,
      default: jest.fn(() => (task: () => Promise<void>) => task()),
    }));
    jest.doMock('../src/config', () => ({ __esModule: true, loadConfig }));
    jest.doMock('../src/baseTagResolver', () => ({ __esModule: true, resolveBaseTag: jest.fn() }));
    jest.doMock('../src/git', () => ({ __esModule: true, getCommits }));
    jest.doMock('../src/kosli', () => ({
      __esModule: true,
      KosliClient: jest.fn(() => ({ attestCommit })),
    }));

    await jest.isolateModulesAsync(async () => {
      await import('../src/main');
      await flushPromises();
    });

    expect(attestCommit).not.toHaveBeenCalled();
    expect(errorSpy).toHaveBeenCalledWith(expect.stringContaining('Range contains 5001 commits'));
    expect(exitSpy).toHaveBeenCalledWith(1);
  });
});