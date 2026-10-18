# Releasing Kestrel

This is a maintainer how-to for preparing an **Apple Silicon, app-only preview release**, using `0.1.8` as the concrete version. It is a runbook, not evidence that a build, push, tag, GitHub release, or compatibility test has happened. Commands below are instructions for a later, explicitly authorized release session; none were executed while writing this document.

**Publication target:** `iamthehimansh/kestrel`. The repository was reported to be initially empty. That is historical context, not permission to overwrite anything: check the live remote again immediately before publishing.

## 1. Release contract and stop conditions

A release is eligible only when all of these agree:

| Item | Required value for this release |
|---|---|
| Version environment variable | `KESTREL_VERSION=0.1.8` |
| Source tag | `v0.1.8`, pointing to the exact reviewed build commit |
| App | `build/Kestrel.app` |
| Disk image | `build/Kestrel-0.1.8.dmg` |
| Published binary asset | `Kestrel-0.1.8.dmg` |
| Published checksum asset | `SHA256SUMS.txt`, containing the SHA-256 of that exact DMG |
| Bundle identifier | `org.kestrel.app` |
| Both bundle version fields | `0.1.8` |
| Main app and bundled macOS CLI architecture | `arm64` only |
| Signing statement | Ad-hoc signed; **not notarized**, not Developer ID signed |
| Intended publication identity | `Himansh Raj <iamthehimansh@gmail.com>` |

Stop on any failed command, unexpected remote ref, dirty build source, unresolved privacy finding, missing notice, version mismatch, or unsupported public claim. A failed gate must be fixed and rerun; do not suppress its exit status or describe a partial check as a pass.

Read the [known issues](#10-known-script-and-documentation-issues) before starting. In particular, the current packaging path does not copy the project's third-party notice document into the app. Resolve that distribution-notice gap before uploading a binary.

## 2. Protect the source before preparing publication

Keep the development repository intact. Do not rewrite its authors, delete its history, or inspect a separate private worktree as part of this procedure.

Before any publication-history transformation:

1. Make a private source backup of the authorized repository, including uncommitted and untracked source needed to recover the current work. Review what is being copied; do not collect unrelated private worktrees, VM directories, or credential stores. A Git archive alone does not preserve uncommitted work.
2. Make a separate Git bundle backup of all local refs. Record its checksum and verify it. A bundle preserves reachable Git history, not every working-tree file, ignored file, reflog-only commit, or external large-file object; it complements the source backup rather than replacing it.
3. Store both backups outside any public repository, release staging directory, or cloud publication destination. They may contain precisely the history that must not be made public. Confirm recovery is possible before rewriting anything.
4. Create a **separate publication clone** with independent objects, then perform only the reviewed author/history transformations there. Keep an old-to-new commit mapping privately. Never use the original development repository as the rewrite workspace.

Illustrative backup and clone commands, for a later authorized session with `SOURCE_REPO`, `BACKUP_DIR`, and `PUBLICATION_DIR` set to reviewed paths:

```sh
git -C "$SOURCE_REPO" bundle create "$BACKUP_DIR/kestrel-before-publication.bundle" --all
git -C "$SOURCE_REPO" bundle verify "$BACKUP_DIR/kestrel-before-publication.bundle"
shasum -a 256 "$BACKUP_DIR/kestrel-before-publication.bundle"
git clone --no-hardlinks "$SOURCE_REPO" "$PUBLICATION_DIR"
```

The source backup is a separate, required step; the commands above do not make it. Do not publish the backup bundle or a backup archive as a release asset.

### Identity and history decisions

In the publication clone, configure new commits with:

```sh
git config user.name 'Himansh Raj'
git config user.email 'iamthehimansh@gmail.com'
```

This changes neither existing authors nor existing committers. The history checker requires **both** fields to match the intended identity for every reachable commit. Review any required rewrite explicitly; do not falsely attribute other people's contributions. Preserve upstream provenance, copyrights, and licenses. If genuine third-party commits conflict with the checker, resolve the publication policy rather than falsifying authorship to make the check green.

History rewriting changes commit IDs and invalidates signatures and existing tag relationships. Finish it before selecting the final build commit and creating the release tag. Rebuild from the final publication source, not an earlier pre-rewrite checkout.

## 3. Audit all material that will leave the machine

The public tree and **every commit reachable from every outgoing branch and tag** must be safe. Removing a file from the latest tree, adding it to `.gitignore`, or scanning only a staged diff does not remove it from history.

Do not publish:

- Raw research results, raw device logs, screen recordings, private screenshots, identifying crash reports, or unredacted experiment output. Publish only reviewed, sanitized summaries and reproducible methods.
- Private VM/AVD directories, snapshots, user-data disks, Android system images, or Google Play images.
- Credential stores, ADB key pairs, signing keystores, private keys, tokens, account identifiers, or environment files containing private configuration.
- Proprietary emulator binaries, extracted vendor libraries, decompiled proprietary code, game APKs, or other artifacts without redistribution rights.
- Local agent/session state, private machine paths, private-worktree references, backup bundles, backup archives, or generated release binaries in Git history.

This policy covers source commits, tag messages, commit messages, release descriptions, screenshots, attachments, and public CI logs—not just the DMG. Redact or omit unsafe content; do not upload it to a public scanner to decide whether it is private.

### Automated history gate

From the publication clone, explicitly enumerate the exact intended outgoing refs. For a release containing only `main` and `v0.1.8`, run this after the tag exists:

```sh
python3 scripts/check-public-history.py --repo . refs/heads/main refs/tags/v0.1.8
```

Before tagging, run it against the intended branch; run it again after tagging and after any changes. Add every additional outgoing ref to the invocation. Its default is only `HEAD`; that is insufficient when other branches or tags will be published.

The checker:

- Walks every reachable commit and compares author and committer with the exact intended identity.
- Inspects historical tree entries, rejects configured forbidden paths and unreviewed non-blob entries, and scans unique blob contents for its configured secret and machine-identity patterns.
- Treats blobs larger than 5,000,000 bytes as findings instead of silently treating them as scanned.
- Exits nonzero on findings and reports counts of commits, historical paths, and scanned blobs.

Record those counts and the exit status in the private release record. This is a necessary gate, **not a comprehensive privacy or licensing audit**. Its path patterns do not cover all credential formats, binary names, or VM formats; it does not scan commit messages or annotated-tag messages for secrets. Review those manually and independently inventory the outgoing tree and history. An annotated tag's message must be reviewed even when its target commit passes.

## 4. Fix documentation and license readiness

Review [README](../../README.md), [LICENSE](../../LICENSE), and [third-party notices](../../THIRD_PARTY_NOTICES.md) against the release's actual behavior. Then run:

```sh
python3 scripts/check-public-docs.py
```

This checks the required public document set, selected README headings, local Markdown link targets, private-path patterns, and selected overclaims. It checks neither external URL availability nor all Markdown syntax, heading anchors, technical accuracy, or license compliance. Missing required guides are a release blocker, not a reason to weaken the check.

The current notices require:

- MIT attribution for Kestrel's original code.
- Attribution and Apache-2.0 obligations for the adapted Android emulator protocol subset, including its modification statement.
- License and notice material for pinned direct and transitive dependencies. The direct pins are grpc-swift-2 `2.4.4`, grpc-swift-nio-transport `2.11.0`, grpc-swift-protobuf `2.5.0`, and swift-protobuf `1.39.0`; use `Package.resolved` for the full set.
- Clear separation from Google's SDK and image distribution terms. Those components are not included in the DMG; first-run setup downloads them separately and accepts SDK licenses on the user's behalf. Do not imply that Kestrel's MIT license permits redistribution of Google Play images.

`package-dependencies.py` collects regular, non-symlink files whose names begin with LICENSE, NOTICE, or COPYING from each pinned checkout, requires a root LICENSE/COPYING file, and writes `ThirdPartyNotices/manifest.json` with pin state, source URL, notice paths, and SHA-256 hashes. It also copies built Swift resource bundles, requires `SwiftProtobuf_SwiftProtobuf.bundle`, and rejects symlinked, empty, or unsupported bundle contents.

The script does **not** verify that each checkout's actual revision or modifications match its recorded pin. Verify clean pinned dependency checkouts independently. Its manifest is an inventory, not legal clearance or a vulnerability assessment. A full transitive vulnerability audit is not claimed.

## 5. Prepare repeatable build inputs

Use a clean checkout of the final reviewed publication commit on an Apple Silicon Mac. Build tools and dependencies must already be approved and available before starting an offline build; SwiftPM may otherwise fetch dependencies. Do not treat a build as network-free merely because these scripts contain no explicit download command.

Required inputs:

- Xcode/Swift toolchain supporting Swift tools version `6.2` and the macOS SDK. The package declares macOS 13 as its deployment floor; current user-facing native-player requirements are macOS 15 or later. A successful build does not prove native-player support on macOS 13.
- Python 3, executable `protoc`, and standard macOS tools used by the scripts: `codesign`, `plutil`, `sips`, `iconutil`, `hdiutil`, `lipo`, and `shasum`.
- Android NDK with `aarch64-linux-android29-clang`. `touchd/build.sh` suggests NDK `27.1.12297006` when none is found. It chooses an available NDK by reverse directory-name order, not an explicitly pinned semantic version. Use a controlled SDK root containing the intended NDK and record the selected compiler.
- Reviewed `Package.swift`, committed `Package.resolved`, clean matching dependency checkouts, keymaps, and build scripts.

Record the source commit, lockfile hash, macOS version, machine architecture, Xcode/Swift/macOS SDK versions, Python version, `protoc` path and version, and NDK/compiler version in the private build record. Publish only a sanitized toolchain summary.

“Repeatable” here means repeatable inputs and procedure, **not demonstrated byte-for-byte reproducibility**. Toolchain selection, cached build products, signatures, filesystem metadata, and DMG creation can affect bytes. The scripts do not enforce a hermetic or deterministic build.

### Exact versioned build sequence

Run from the clean publication checkout in a later authorized build session. Export the version once so all subprocesses inherit it:

```sh
export KESTREL_VERSION=0.1.8
export PROTOC_PATH=/opt/homebrew/bin/protoc
# If protoc is elsewhere, replace the value with its verified absolute executable path.
test -x "$PROTOC_PATH"

python3 scripts/check-public-docs.py
PROTOC_PATH="$PROTOC_PATH" swift test --jobs 1
KESTREL_VERSION="$KESTREL_VERSION" PROTOC_PATH="$PROTOC_PATH" bash scripts/build-app.sh
KESTREL_VERSION="$KESTREL_VERSION" SKIP_APP_BUILD=1 bash scripts/build-dmg.sh
KESTREL_VERSION="$KESTREL_VERSION" bash scripts/verify-release.sh "build/Kestrel-${KESTREL_VERSION}.dmg"
```

Require a successful exit from **each** line before proceeding. `KESTREL_VERSION=0.1.8` is an environment assignment, not `KESTREL_VERSION0.1.8`.

`build-app.sh` builds the release `KestrelApp` and `kestrel` products with two jobs, builds the Android touch helper, assembles resources and dependency notices, generates the icon and plist, ad-hoc signs the CLI and app, and verifies the result. It stages under `build/` and preserves an existing app under a timestamped `Kestrel.previous.*.app` name before replacing it.

The helper cache is reused solely when `.build/touchd/touchd` is executable and newer than `touchd/touchd.c`. That does not account for changed compiler versions, flags, or `touchd/build.sh`; use a fresh build checkout/cache for release inputs rather than trusting that timestamp test.

`SKIP_APP_BUILD=1` packages the app just built, avoiding an unnecessary second build. It is safe only after successful app verification and explicit version checks: the DMG builder itself does not compare app version with the requested filename. Alternatively, `KESTREL_VERSION=0.1.8 PROTOC_PATH="$PROTOC_PATH" bash scripts/build-dmg.sh` builds the app itself before packaging. Never mix a newly named DMG with an unreviewed or stale app.

Unit tests are required evidence, but not a game-compatibility certification. The release verifier does not launch Kestrel or Android. Any UI, microphone, input, or game smoke tests require a separate authorized session and a sanitized test matrix; do not claim them from packaging success alone.

## 6. Inspect the app-only payload

`build-dmg.sh` stages `Kestrel.app` and an `Applications` symlink pointing to `/Applications`, then creates an HFS+ compressed UDZO image named `Kestrel-0.1.8.dmg` with volume name `Kestrel`. It verifies the image before moving it into place and preserves an earlier same-name DMG under a timestamped `.previous.*.dmg` filename.

Expected distributable payload:

```text
Kestrel.app/
  Contents/Info.plist
  Contents/MacOS/Kestrel
  Contents/Resources/bin/kestrel
  Contents/Resources/touchd
  Contents/Resources/keymaps/
  Contents/Resources/Kestrel.icns
  Contents/Resources/LICENSE
  Contents/Resources/ThirdPartyNotices/manifest.json
  Contents/Resources/ThirdPartyNotices/<dependency>/...
  Contents/Resources/*.bundle
Applications -> /Applications
```

The assembly also includes `Contents/Resources/THIRD_PARTY_NOTICES.md`; the release verifier compares it and the original-code license against the source checkout. The Android `touchd` helper is Kestrel's own built helper, not an Android runtime or SDK. The disk image must not contain the Android Emulator, SDK/NDK tools, system images, private VM data, proprietary binaries, research output, or key stores.

Check the entire mounted volume, not just the app: only the intended app, Applications shortcut, and reviewed filesystem-generated metadata should be present. Never upload `build/` wholesale; it may contain old apps, old images, staging directories, and verifier artifacts.

## 7. Validate architecture, signature, mount, and checksum

`verify-release.sh` runs five stages without launching the app or Android:

1. `hdiutil verify` checks disk image integrity.
2. `hdiutil attach -readonly -nobrowse` mounts at a temporary location without opening Finder.
3. `codesign --verify --deep --strict` validates the mounted app's code signature.
4. Python checks the short version, bundle identifier, microphone usage description, Applications symlink target, exactly `arm64` for the main executable and bundled CLI, presence of notices and a resource bundle, and selected forbidden filenames/extensions inside the app.
5. `shasum -a 256` prints the DMG checksum.

The verifier checks both bundle-version fields, allowed top-level volume entries, project license/notices, and bundled keymaps against the checkout. Also inspect the complete dependency notice inventory and all nested executable code. Only the two named macOS executables' architectures are asserted; the filename denylist is not an exhaustive privacy or proprietary-content audit.

Use `codesign -dv --verbose=4` on the mounted app to inspect signing metadata as well as signature integrity. `codesign --verify` alone does not establish a Developer ID identity, notarization, or Gatekeeper acceptance. These build scripts sign with `-s -` (ad-hoc); they do not submit for notarization, staple a ticket, or use a Developer ID certificate. Release copy must say **ad-hoc signed, not notarized**. Do not recommend disabling Gatekeeper globally.

The verifier detaches the image before its final success summary. Its failure trap also attempts cleanup; an unmount failure exits nonzero and preserves the working directory. Inspect cleanup output and resolve any remaining mount before marking verification complete.

### Create and verify the checksum asset

Only after all inspection is complete and the final DMG will no longer change:

```sh
(
  cd build
  shasum -a 256 Kestrel-0.1.8.dmg > SHA256SUMS.txt
  shasum -a 256 -c SHA256SUMS.txt
)
```

Running in `build/` records a portable asset filename instead of a local directory path. Require `Kestrel-0.1.8.dmg: OK`. Compare this digest with the verifier's output, and retain the actual value in the release record. Never invent a digest or reuse one from an earlier build. The checksum file provides integrity comparison, not an authenticated signature by itself.

## 8. Freeze source and publish only explicit refs and assets

1. Confirm the source tree is clean and the release build used the final reviewed commit. Record its full commit ID. If source or packaging changes, rebuild and rerun all gates.
2. Create `v0.1.8` at that exact commit only after identity/history decisions are final. Do not retarget an already published tag or silently replace a released binary.
3. Re-run the public-docs gate and the whole-outgoing-history gate, including the new tag. Review the tag message and release notes separately.
4. Recheck the **live** `https://github.com/iamthehimansh/kestrel.git` destination, its refs, and existing release/assets at publication time. A successful `git ls-remote` with no refs supports an empty Git repository at that moment; an authentication or network failure does not. Git refs alone do not establish that no draft release/assets exist.
5. If anything exists that differs from the reviewed publication plan, stop and reconcile it. Do not overwrite another branch, tag, release, or user's work based on the earlier empty-repository report.
6. Review the remote URL and a dry run for the exact intended branch/tag refspecs. Push only those refs, without force. Do not publish all local refs, backup refs, or remote-tracking refs. A dry run is not a substitute for rechecking live state or auditing data.
7. Create a **draft preview/prerelease** for the already verified tag. Upload only `Kestrel-0.1.8.dmg` and `SHA256SUMS.txt` as binary-release assets. GitHub-generated source archives must resolve to the same tag; do not substitute a source archive from another checkout.
8. Inspect the draft's target commit, tag, asset names, file sizes, notes, and download links. In an authorized network session, download the uploaded assets into a clean directory and run `shasum -a 256 -c SHA256SUMS.txt`; compare the downloaded manifest with the locally approved digest as well. A successful upload is not checksum verification.
9. Publish only after every gate is recorded as passed. If publication fails partway, inspect remote state before retrying; do not assume an all-or-nothing outcome.

No mirror publication or blind forced push belongs in this workflow. Any later need to replace public history is a separate, explicitly approved migration, not a release shortcut.

Record the final commit, tag, exact asset names, sizes, SHA-256 digest, toolchain summary, gate exit statuses, test counts/results, mount-cleanup outcome, unresolved limitations, and publication URLs. Keep raw logs and private backup locations out of the public release notes. Do not say “released” until the remote release and downloads have actually been checked.

## 9. Accurate release notes and discoverability

Use a specific title such as **Kestrel 0.1.8 — Apple Silicon Android gaming preview**. The description should state what Kestrel manages, what changed, what was tested, installation requirements, known limitations, signature status, and the separate first-run Android SDK/image download.

Useful repository topics, where supported by the released code, include `macos`, `apple-silicon`, `android-emulator`, `android-gaming`, `swift`, `metal`, `grpc`, `keymapping`, and `keyboard-mouse`. Use searchable descriptive headings and real screenshots that have been reviewed for privacy. Do not add unrelated popular topics, promise rankings or trending placement, imply universal game compatibility, or market anti-cheat evasion.

Separate measured results from reports and hypotheses. A packaging test does not prove a game runs, an emulator is accepted by a game service, or performance matches commercial products. Do not publish raw research archives to substantiate a headline; publish a sanitized method, environment summary, and bounded finding instead.

Credit wording consistent with current notices:

> Kestrel was researched and built with [Cana.build](https://cana.build) using its REA mod, based on the open-source [REA](https://github.com/morluto/rea) project. No REA code is included in this repository. These credits describe tools used and do not imply endorsement.

Retain third-party license attribution and distinguish tooling credits from included code. Do not imply affiliation with Google, game publishers, or emulator vendors.

## 10. Remaining limits and review corrections

The publication review corrected the README's version-export example, added project notices to app assembly, added both-version/volume/keymap checks to the verifier, and made successful unmount precede its success summary. The building guide is now present. Re-run every gate after changing any release input.

| Remaining limit | Required handling |
|---|---|
| Build defaults differ from the verifier default | Export the intended `KESTREL_VERSION` throughout the sequence. |
| `SKIP_APP_BUILD=1` reuses an existing app | Run the mounted-image verifier; do not assume a filename proves its version or contents. |
| Dependency notice presence is not a full license audit | Review upstream terms and retain all required attribution and license texts. |
| Helper-cache/NDK and dependency checkout state affect output | Record actual toolchain and inputs; no bit-for-bit reproducibility claim. |
| Pattern scanners are finite | Review content/provenance, commit/tag messages and all outgoing refs independently. |
| Local validation differs from a clean Mac or CI | Report local tests, remote CI and user gameplay separately. |

This is a runbook, not a claim that a future release already passed. Consult the actual release record for command results and the final digest.
