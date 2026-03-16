---
max_turns: 5
max_concurrent: 3
mode: hybrid
workspace_root: /tmp/orchestra
github_repo: i2y/orchestra-test
github_labels: orchestra

hooks:
  after_create: "git clone https://github.com/$ORCHESTRA_GITHUB_REPO . && git checkout -b orchestra-$ORCHESTRA_TASK_ID"
  before_run: "git pull origin main --no-edit 2>/dev/null; true"
  after_run: "git add -A && git commit -m 'orchestra: fix #'$ORCHESTRA_TASK_ID && git push -u origin HEAD && gh pr create --fill --label orchestra 2>/dev/null; true"
  before_review_run: "git fetch origin && git pull --no-edit 2>/dev/null; true"
  after_review_run: "git add -A && git commit -m '[orchestra] address review feedback' && git push 2>&1; true"
  timeout_ms: 120000

review:
  max_rounds: 5
  poll_interval_ms: 60000

allowed_tools: "Read Edit Write Bash(python:*) Bash(pytest:*) Bash(git:*)"
---
You are a software engineer. Fix the following issue.

Title: {{task.title}}
Description: {{task.description}}

This is attempt {{attempt}}. Please make the necessary code changes and ensure all tests pass.
