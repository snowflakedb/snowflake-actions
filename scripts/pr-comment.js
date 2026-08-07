// Generic helpers for posting run summaries to a pull request from an
// actions/github-script step. No project-specific assumptions.
//
// Load from an actions/github-script step:
//
//   const { resolvePrNumber, resolvePrBranch, postSummaryComment } =
//     require(`${process.env.GITHUB_ACTION_PATH}/../../scripts/pr-comment.js`);

const fs = require('fs');

// GitHub rejects issue/PR comment bodies longer than this with
// "body is too long (maximum is 65536 characters)".
const MAX_COMMENT_LENGTH = 65536;

// Trim content so that `prefix + content + footer` fits within GitHub's comment
// size limit, cutting at a line boundary and closing an open ``` fence so the
// remaining markdown still renders. Returns the assembled body.
function assembleBody(prefix, content, footer) {
  if (prefix.length + content.length + footer.length <= MAX_COMMENT_LENGTH) {
    return prefix + content + footer;
  }

  const notice =
    "\n> ⚠️ Output truncated: the full summary exceeded GitHub's " +
    `${MAX_COMMENT_LENGTH}-character comment limit. ` +
    'See the run log and the uploaded artifact for the complete output.\n';

  // Reserve room for the notice, the footer and a possible closing fence.
  const fenceClose = '```\n';
  const detailsClose = '</details>\n';
  const budget =
    MAX_COMMENT_LENGTH -
    prefix.length -
    footer.length -
    notice.length -
    fenceClose.length -
    detailsClose.length;

  let kept = content.slice(0, Math.max(budget, 0));
  const lastNewline = kept.lastIndexOf('\n');
  if (lastNewline > 0) {
    kept = kept.slice(0, lastNewline + 1);
  }

  // An odd number of fences means the truncation happened inside a code block.
  const fenceCount = (kept.match(/^```/gm) || []).length;
  if (fenceCount % 2 === 1) {
    kept += fenceClose;
  }

  // Same for a <details> block the cut landed inside.
  const opened = (kept.match(/<details\b/g) || []).length;
  const closed = (kept.match(/<\/details>/g) || []).length;
  if (opened > closed) {
    kept += detailsClose;
  }

  return prefix + kept + notice + footer;
}

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
// When marker is provided (e.g. 'dcm-plan:DCM_STAGE'), the comment is written
// as <!-- marker --> so subsequent runs update the existing comment in place
// rather than stacking duplicates on the PR.
async function postSummaryComment(github, context, summaryFile, fallback, marker) {
  const prNumber = await resolvePrNumber(github, context);
  if (prNumber == null) {
    console.log('No PR found for this commit. Skipping comment.');
    return;
  }

  const markerTag = marker ? `<!-- ${marker} -->` : null;

  const prefix = markerTag ? `${markerTag}\n` : '';
  let content;
  try {
    content = fs.readFileSync(summaryFile, 'utf8');
  } catch {
    content = `${fallback}\n`;
  }
  const runUrl = `https://github.com/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}`;
  const footer = `\n[🔎 View Full Run Details](${runUrl})\n`;

  const body = assembleBody(prefix, content, footer);

  if (markerTag) {
    const { data: comments } = await github.rest.issues.listComments({
      owner: context.repo.owner,
      repo: context.repo.repo,
      issue_number: prNumber,
    });
    const existing = comments.find(c => c.body && c.body.includes(markerTag));
    if (existing) {
      await github.rest.issues.updateComment({
        owner: context.repo.owner,
        repo: context.repo.repo,
        comment_id: existing.id,
        body: body,
      });
      return;
    }
  }

  await github.rest.issues.createComment({
    owner: context.repo.owner,
    repo: context.repo.repo,
    issue_number: prNumber,
    body: body,
  });
}

module.exports = { resolvePrNumber, resolvePrBranch, postSummaryComment };
