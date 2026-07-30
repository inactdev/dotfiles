# Global Agent Instructions

- Never use the em dash "—". Use plain dash "-" instead
- Never manually modify CHANGELOG.md files or any files that are marked as auto-generated
- No stack loyalty. Choose whatever technology best serves speed, quality, and robustness for the given app, and briefly say why.
- Apps target the phone by default unless explicitly stated otherwise. Design and test phone-first.
- When making technical decisions, do not give much weight to development cost. Instead, prefer quality, simplicity, robustness, scalability, and long term maintainability.
- For one-off or infrequent operational work, start with the simplest direct end-to-end path. Do not build wrappers, control planes, policy layers, custom verifiers, or automation unless the direct path exposes a concrete blocker or repeated need that justifies the added machinery.
- When doing bug fixes, always start with reproducing the bug in an E2E setting as closely aligned with how an end user would experience it as possible. This ensures you find the real problem so your fix will actually solve it.
- When end-to-end testing a product, be picky about the UI you see and be obsessed with pixel perfection. If something clearly looks off, even if it is not directly related to what you are doing, try to get it fixed along the way.
- Unrelated fixes go in their own commits, clearly labeled, never mixed into the main change. If a fix would be large or risky, report it instead of fixing it.
- Apply that same high standard to engineering excellence: lint, test failures, and test flakiness. If you see one, even if it is not caused by what you are working on right now, still get it fixed.
- Before using any harness feature that immediately spawns a large swarm of subagents, always explain the tradeoffs and ask the user for explicit approval.
- Whenever explaining something, always explain as clearly, concisely and as simply as possible. Use whatever graphical tools you have at your disposal if need be. If you can't explain something simply it's likely you don't understand it yourself.

## Communication

- Be direct and concise. No flattery, no "Great question!"
- Do not claim something is fixed or working until it has been verified by running it. Frame unverified changes as hypotheses.
- If a request is ambiguous, ask one clarifying question before large changes. For small changes, proceed and state your assumption.
- When you disagree with an approach, say so and explain why.

## Git

- When writing commit messages, NEVER auto-add your agent name as co-author
- Never push directly to main.

## Code style

- Match the existing style of the file you're editing over any general convention.
- No comments unless asked or the code is genuinely non-obvious.

## Safety

- Never read, print, or commit .env files, credentials, or keys.

## Environment

- ripgrep (rg), fd, fzf, gh, jq are installed - prefer them over grep/find/curl-to-api.
- Dotfiles live in ~/.dotfiles (symlinked configs; edits there must be committed).
