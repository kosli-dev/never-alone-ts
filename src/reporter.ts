import * as fs from 'fs';
import { EvaluationResult } from './types';

export function generateJsonReport(results: EvaluationResult[], tagName: string) {
  const filename = `att_report_${tagName}.json`;
  const reportData = results.map(result => ({
    sha: result.commit.sha,
    author: result.commit.author,
    date: result.commit.date.toISOString(),
    message: result.commit.message,
    status: result.status,
    reason: result.reason,
    prNumber: result.prNumber,
  }));

  fs.writeFileSync(filename, JSON.stringify(reportData, null, 2));
  console.log(`JSON report generated: ${filename}`);
}
