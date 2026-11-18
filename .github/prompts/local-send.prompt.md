---
mode: agent
description: execute patch/minor/major send workflow
---
You are executing a release send workflow for this project.

Tasks:
1. Determine whether the request is `patch send`, `minor send`, or `major send`.
2. Run preflight checks before release actions:
	- Confirm testing is explicitly accepted by the user.
	- Confirm tracker docs are aligned with changes.
	- Confirm release wording and commands stay tool-agnostic.
3. If any preflight check fails, stop and return a concise blocker list.
4. If preflight checks pass, perform the release sequence:
	- Create a release commit and tag for the requested version level.
	- Push commits and tags.
5. Return a short completion summary with branch, new tag, and pushed status.

Constraints:
- Do not run destructive git commands.
- Do not guess missing confirmations.
- Keep output terse and action-focused.
