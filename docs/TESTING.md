# Testing and release

Run `./scripts/verify.sh` with full Xcode selected. It checks repository policy, Core and smoke tests, keyboard behavior, storage and concurrency, iOS Simulator and macOS builds. Use external build/scratch directories to avoid file-provider metadata contamination.

Live tests are opt-in: ASR/model credentials and synthetic or authorized audio/corpora must be supplied locally. Never set production credentials in pull-request workflows. Skipped live tests are not passes.

Before device distribution, test microphone permission denial/grant, keyboard document ownership, dictation clipboard output, consecutive meeting start/stop, interruption/recovery, at least one minute of background capture, nonzero saved audio and transcript generation. macOS additionally needs actual target-app insertion and overnight lifecycle tests.

CI is an unsigned source check. Signing, TestFlight upload and Apple processing are separate operator steps. No automatic release, signing secret, hosted account or TestFlight invitation is supplied by this repository.

Publication verification results are recorded in docs/PUBLICATION.md. Known device acceptance gaps from the development baseline remain open until reproduced by a tester.
