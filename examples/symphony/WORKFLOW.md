---
name: github-fix-issue
polling:
  interval_ms: 30000
agent:
  max_turns: 10
  max_concurrent: 5
  max_retries: 2
  retry_delay_ms: 5000
  max_retry_backoff_ms: 300000
workspace:
  root: /tmp/symphony
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
    git checkout -b symphony/$SYMPHONY_ISSUE_IDENTIFIER
  before_run: |
    git fetch origin main && git rebase origin/main || true
  after_run: |
    git add -A
    git diff --cached --quiet || git commit -m "Fix #$SYMPHONY_ISSUE_NUMBER: $SYMPHONY_ISSUE_TITLE"
    git push -u origin HEAD 2>/dev/null || true
    gh pr create --title "Fix #$SYMPHONY_ISSUE_NUMBER: $SYMPHONY_ISSUE_TITLE" --body "Automated fix by Symphony" --repo "$SYMPHONY_GITHUB_REPO" 2>/dev/null || true
  before_remove:
  timeout_ms: 120000
---
You are a software engineer working on a codebase.

## Task
Fix the following GitHub issue:

**Issue:** #{{issue.identifier}}

**Title:** {{issue.title}}

**Description:** {{issue.description}}

## Attempt
This is attempt #{{attempt}}.

## Instructions
1. Read the relevant code
2. Identify the root cause
3. Implement a fix
4. Write or update tests
5. Ensure all tests pass
