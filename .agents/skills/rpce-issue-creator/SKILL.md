---
name: rpce-issue-creator
description: Draft, refine, review, or create maintainer-friendly GitHub issues for RepoPrompt CE from rough notes, chat snippets, logs, investigation findings, or agent context. Use when a user or agent needs a clear issue draft or explicitly requests filing an issue.
---

# RepoPrompt CE Issue Creator

Create concise, actionable RepoPrompt CE GitHub issues. Start from the available notes, chat context, logs, screenshots, investigation findings, or file references, then ask only for missing details that materially affect the issue.

## Draft the Issue

- Clarify the issue type: bug, regression, enhancement, task, docs, investigation follow-up, or question.
- Write a clear, specific title that names the affected area and user-visible problem or desired change.
- Summarize the problem, need, or opportunity in a short opening paragraph.
- Preserve relevant source context without dumping transcripts; quote or summarize only the parts needed to understand the issue.
- State the desired outcome or expected behavior.
- Include reproduction steps, observed behavior, logs, screenshots, file references, environment details, versions, or commands when applicable.
- Identify scope, non-goals, risks, constraints, dependencies, and open questions when useful.
- Propose practical acceptance criteria, preferably as a short checklist.

## Review and Filing

- Review drafts for clarity, deduplication clues, missing repro details, and maintainer-friendly scope.
- Do not file an issue automatically. Only create one after the user explicitly requests or approves filing.
- When filing is approved, use `gh issue create` with the reviewed title and body, then report the created issue URL.
