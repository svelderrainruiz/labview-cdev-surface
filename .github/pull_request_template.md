## Summary
- Update `workspace-governance.json` `pinned_sha` values for repos whose default branches moved.

## Validation
- [ ] Ran `pwsh -NoProfile -File .\scripts\Test-WorkspaceManifestBranchDrift.ps1 -ManifestPath .\workspace-governance.json -OutputPath .\artifacts\workspace-drift\workspace-drift-report.json`
- [ ] Verified drift report is `in_sync` for intended repos.
- [ ] Ran `Invoke-Pester` for contract tests in `tests/`.

## Notes
- Link to failing run from `Workspace SHA Drift Signal`.
- Confirm no policy relaxation in `AGENTS.md` or workflow disablement.
