# Changelog

## 0.4.4 — Unreleased

- Backend package: recover the dashboard endpoint after an unexpected exit,
  retry failed starts, and ignore stale restart messages while it is healthy.
- Frontend 0.3.11: validate extension-tab events without crashing on malformed,
  non-string, oversized or incomplete input.
- Run backend and frontend test suites in CI with locked dependencies.
- Align the backend Mix version with the swarmidx release version (previous
  repository tags 0.4.0–0.4.3 retained the backend's 0.4.0 version stamp).

The swarmidx `genlayerlabs/genswarms-dashboard` package contains `backend/`.
The frontend is a separate application built from `frontend/` in the same tag.
Consumers must update the repository pin and rebuild their swarm and dashboard
images to adopt both changes. Genmochi can then replace its provisional #60 pin
with the published 0.4.4 package digest.
