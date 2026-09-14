# Repository boundary

Include application source, synthetic tests, required public model/dictionary resources, reproducible build tools and public-facing documentation. This repository has one sanitized root history; never push the original development branches or tags here.

Exclude secrets, real private IPs/domains, enrollment material, user data, machine paths and identities, internal operations notes, screenshots of private content, caches, signing files, device exports and compiled app release artifacts. Use `example.invalid` for private service examples. Keep publicly documented vendor endpoints only where needed for interoperable clients.

Original code is proprietary. Preserve all component licenses and corresponding-source obligations. The three reviewed Rime dictionary SQLite databases and source ZIP are intentional large resources, each below GitHub's 100 MiB file limit; their integrity is checked against committed manifests. No other large binary exceptions are implied.

Run `scripts/check_repository.sh`, `scripts/check_publication.py` and `scripts/verify.sh` before publication. Automated checks reduce risk; they do not prove absence of every form of sensitive data. Scan both the tree and reachable Git history before a push. Do not commit local scan reports that contain secret findings.
