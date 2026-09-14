# Contributing

This is a private, proprietary development repository. Access is not a grant to redistribute original code. Discuss changes with the maintainer before substantial work.

1. Create a focused branch from `main`.
2. Keep secrets, private endpoints, user recordings and diagnostic exports out of changes and examples.
3. Add behavioral tests for state, ownership, persistence and concurrency changes; do not rely only on static source checks.
4. Run `scripts/verify.sh` and `scripts/check_publication.py` before opening a pull request.
5. Describe behavior, validation, skipped tests and device acceptance limits. Follow the pull request template.
6. Identify every copied/adapted third-party component, pinned source revision, license and modifications; update notices and full license texts.

Do not change licenses, broaden data collection, enable hosted services, upload signing material or distribute binaries as an incidental refactor. Avoid committing generated iOS projects or build products. See SECURITY.md for vulnerability reporting.
