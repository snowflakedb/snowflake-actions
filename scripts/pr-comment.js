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
  const budget =
    MAX_COMMENT_LENGTH - prefix.length - footer.length - notice.length - fenceClose.length;

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

// Rewrite an already-posted comment body so its content sits inside a collapsed
// <details> block. Returns null when the body is already collapsed or has no
// recognisable content. `runLabel` is appended to the summary line when known.
function collapseCommentBody(body, runLabel) {
  if (!body || body.includes('<details>')) {
    return null;
  }

  const lines = body.split('\n');
  const markerLine = lines[0].startsWith('<!--') ? lines.shift() : null;

  // Use the summary's own heading as the <summary> label, so the collapsed row
  // still shows status and target without expanding.
  let title = 'Previous DCM Plan';
  const headingIndex = lines.findIndex(l => /^#{1,6}\s+\S/.test(l));
  if (headingIndex !== -1) {
    title = lines[headingIndex].replace(/^#{1,6}\s+/, '').trim();
    lines.splice(headingIndex, 1);
  }
  if (runLabel) {
    title += ` · ${runLabel}`;
  }

  // Lift the run link above the content so truncation can never cut it away.
  let runLink = '';
  const linkIndex = lines.findIndex(l => l.includes('](https://') && l.includes('/actions/runs/'));
  if (linkIndex !== -1) {
    runLink = `${lines[linkIndex].trim()}\n\n`;
    lines.splice(linkIndex, 1);
  }

  const prefix =
    `${markerLine ? `${markerLine}\n` : ''}<details><summary>${title}</summary>\n\n${runLink}`;
  const footer = '\n</details>\n';

  return assembleBody(prefix, `${lines.join('\n').trim()}\n`, footer);
}

// Post a summary as a new PR comment per run, collapsing the comments from
// earlier runs of the same kind so only the latest output is expanded.
//
// `markerFamily` (e.g. 'dcm-plan:PREPROD:my-project') identifies the family of
// comments to manage. Each comment carries `<!-- <family> run:<id>.<attempt> -->`
// so a re-run of the same attempt updates its own comment in place instead of
// stacking a duplicate.
async function postVersionedSummaryComment(github, context, summaryFile, fallback, markerFamily) {
  const prNumber = await resolvePrNumber(github, context);
  if (prNumber == null) {
    console.log('No PR found for this commit. Skipping comment.');
    return;
  }

  const attempt = process.env.GITHUB_RUN_ATTEMPT || '1';
  const runRef = `run:${context.runId}.${attempt}`;
  const markerTag = `<!-- ${markerFamily} ${runRef} -->`;

  let content;
  try {
    content = fs.readFileSync(summaryFile, 'utf8');
  } catch {
    content = `${fallback}\n`;
  }
  const runUrl = `https://github.com/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}`;
  const body = assembleBody(
    `${markerTag}\n`,
    content,
    `\n[🔎 View Full Run Details](${runUrl})\n`,
  );

  const { owner, repo } = context.repo;
  const listParams = { owner, repo, issue_number: prNumber };
  const comments = github.paginate
    ? await github.paginate(github.rest.issues.listComments, listParams)
    : (await github.rest.issues.listComments(listParams)).data;

  // Comments from earlier runs, plus any single sticky comment written by an
  // older version of this action (marker without a run reference).
  const family = comments.filter(
    c => c.body && c.body.includes(markerFamily) && !c.body.includes(markerTag),
  );
  for (const comment of family) {
    const runMatch = comment.body.match(/run:(\d+)\.(\d+)/);
    const runLabel = runMatch
      ? `run ${runMatch[1]}${runMatch[2] === '1' ? '' : ` (attempt ${runMatch[2]})`}`
      : null;
    const collapsed = collapseCommentBody(comment.body, runLabel);
    if (collapsed) {
      await github.rest.issues.updateComment({ owner, repo, comment_id: comment.id, body: collapsed });
    }
  }

  const current = comments.find(c => c.body && c.body.includes(markerTag));
  if (current) {
    await github.rest.issues.updateComment({ owner, repo, comment_id: current.id, body });
    return;
  }

  await github.rest.issues.createComment({ owner, repo, issue_number: prNumber, body });
}

module.exports = {
  resolvePrNumber,
  resolvePrBranch,
  postSummaryComment,
  postVersionedSummaryComment,
};
