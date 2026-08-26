# Lock contract

All files in this directory form one reviewed release transaction:

- `release.env` pins the annotated tag object, peeled source commit, build revision, source epoch, kernel release, media geometry and the project Release tag used to distribute locked binary inputs.
- `feeds.tsv` is the complete feed set. Every feed must use a 40-character commit; missing and extra feeds are rejected.
- `targets.tsv` pins target/profile, package architecture, ImageBuilder filename, byte size and SHA-256, and per-target kernel vermagic.
- `manifests/*.manifest` stores the complete resolved package name/version set for all six combinations. `package-manifests.tsv` is its count/digest index.
- `artifacts.tsv` stores exactly ten reviewed compressed-image SHA-256 values: one x86 image and two Raspberry Pi images per preset.
- `package-snapshots.tsv` is mandatory and records each portable signed-index/APK bundle's filename, byte size and SHA-256 plus an external SHA-256 of the unpacked tree's `SHA256SUMS`. The latter prevents a local payload and its self-authored inner checksum list from being changed together.

`SHA256SUMS` inside an output directory protects that downloaded directory from corruption. It is generated with the output and is therefore not a substitute for `artifacts.tsv`; canonical verification checks both.

The normal build path never writes these files. `scripts/locks/refresh-locks.sh` writes a candidate below `build/lock-refresh/<version>/`, captures the signed package indexes/APKs used by the live build, then rebuilds against that snapshot. Only `scripts/locks/apply-lock-candidate.sh` can replace this directory, after revalidating the complete candidate.

Package snapshot bundles and ImageBuilder archives are intentionally too large for this configuration repository. Applying a candidate persists all six locked assets plus the unpacked snapshots below local `.cache/` roots before replacing these locks; an identical version is idempotent and conflicting content is rejected. Production builds restore missing inputs from the separately published project Release (or an explicitly configured HTTPS mirror), authenticate them only with this directory's size/SHA locks, and build exclusively from the snapshot. The Release location provides availability rather than trust. Automated refresh first stages and remotely verifies its seven-file Release as a draft, then applies and pushes these locks with an exact branch lease, rebinds the draft tag to that pushed commit, and publishes once. If publication is interrupted after the lock push, a later run may publish only after every draft byte matches the current locks; it never regenerates that version from live repositories.
