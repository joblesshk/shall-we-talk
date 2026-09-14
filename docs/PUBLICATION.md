# Publication audit

This repository was assembled as a new history from an allowlist of application source, tests, build tools and required public resources. The private development repository, its original commits/tags, user recordings, operational notes, screenshots, local credentials, certificates and device exports were not copied.

Private relay hosts/IPs were replaced with reserved `.invalid` examples. Apple signing and bundle identities were replaced with placeholders. Default network routing was changed to direct API, requiring the operator's own configuration. Public provider API paths and fake test credentials remain as functional interface/test documentation.

Third-party licenses and model/dictionary provenance are supplied separately. The model's local files are compared byte-for-byte with the pinned upstream revision in MODEL_PROVENANCE.json. Dictionary resources and their source archive are retained with original manifests and licenses. Archive contents are included in publication scanning.

The original product license remains proprietary; this is not an open-source relicensing. Public GitHub hosting is not a substitute for reviewing obligations before binary redistribution.

## Verified on 2026-09-14

- Repository policy and publication text/ZIP checks passed.
- Gitleaks directory scan reported no credential findings; synthetic test credentials preserve their runtime values without resembling embedded production keys.
- Known original private relay markers and personal home paths were absent from the exported files and archive members.
- Full `scripts/verify.sh` passed: 294 core tests, four explicitly skipped external-service tests, transaction/keyboard/macOS regression checks, unsigned iOS Simulator and macOS Debug builds.
- The bundled model matches its pinned upstream files; dictionary/source hashes pass the repository integrity checks.

Physical-device behavior of this independently configured snapshot is not certified by the source build. Provider onboarding requires developer configuration as explained in CONFIGURATION.md. The initial publication has fresh history; no original branches, tags or commits are ancestors.


## Follow-up review

A follow-up review found three hardcoded local iCloud mirror paths missed by the first scan. They now derive their directory name from `containerID`, and the publication scanner rejects private identifier tokens in text, binary files and ZIP members. The denylist stores token hashes rather than republishing an operator identifier. The initial publication commit is replaced to remove the old identifiers from branch history; this does not certify deletion of provider caches or earlier clones.

Two unreferenced runtime probe source files were removed from the publication snapshot. Production keyboard host-return code still uses private runtime interfaces, including host PID discovery. This snapshot is **not cleared for App Store submission**; removing those production dependencies requires redesign and real-device regression testing. Publishing source is not itself the cause of this pre-existing dependency.

Historical section-number comments refer to private development notes that are not included. They are historical rationale, not instructions to retrieve private files. GPL distribution review and future dictionary storage growth remain release considerations. That follow-up revision retained private visibility and proprietary licensing. On 2026-09-14 the owner subsequently authorized public visibility; the original code license remains unchanged.

The first hosted CI run also exposed a date resolver overwriting an explicitly supplied calendar time zone with the machine time zone. Both platform implementations now preserve the supplied calendar; default callers still use the current calendar. Validation includes running under UTC to reproduce the hosted environment.

The second hosted CI run passed the date checks but stopped because ripgrep was not installed on the runner. CI now explicitly installs it. Local build validation remains distinct from the pending hosted run. Public source visibility is not a Product Hunt contest submission or confirmation of eligibility.
