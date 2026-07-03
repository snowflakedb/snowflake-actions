// Generic helpers for posting run summaries to a pull request from an
// actions/github-script step. No project-specific assumptions.
//
// Load from an actions/github-script step:
//
//   const { resolvePrNumber, resolvePrBranch, postSummaryComment } =
//     require(`${process.env.GITHUB_ACTION_PATH}/../../scripts/pr-comment.js`);

const fs = require('fs');

// Resolve the PR number associated with the current event/commit, or null.
async function resolvePrNumber(github, context) {
  if (context.eventName === 'pull_request') {
    return context.issue.number;
  }
  const { data: prs } = await github.rest.repos.listPullRequestsAssociatedWithCommit({
    owner: context.repo.owner,
    repo: context.repo.repo,
    commit_sha: context.sha,
  });
  return prs.length > 0 ? prs[0].number : null;
}

// Resolve the source branch of the associated PR, or '' when none is found.
async function resolvePrBranch(github, context) {
  if (context.eventName === 'pull_request') {
    return context.payload.pull_request.head.ref || '';
  }
  try {
    const { data: prs } = await github.rest.repos.listPullRequestsAssociatedWithCommit({
      owner: context.repo.owner,
      repo: context.repo.repo,
      commit_sha: context.sha,
    });
    if (prs.length > 0) {
      return prs[0].head.ref || '';
    }
  } catch (e) {
    console.log(`Could not look up PR for commit: ${e.message}`);
  }
  return '';
}

// Post the contents of a summary file (plus a run link) as a PR comment.
async function postSummaryComment(github, context, summaryFile, fallback) {
  const prNumber = await resolvePrNumber(github, context);
  if (prNumber == null) {
    console.log('No PR found for this commit. Skipping comment.');
    return;
  }

  let body = '';
  try {
    body += fs.readFileSync(summaryFile, 'utf8');
  } catch {
    body += `${fallback}\n`;
  }
  const runUrl = `https://github.com/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}`;
  body += `\n[🔎 View Full Run Details](${runUrl})\n`;

  await github.rest.issues.createComment({
    owner: context.repo.owner,
    repo: context.repo.repo,
    issue_number: prNumber,
    body: body,
  });
}

module.exports = { resolvePrNumber, resolvePrBranch, postSummaryComment };
