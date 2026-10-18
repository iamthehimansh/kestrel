# Security Policy

Kestrel runs Android virtual machines on your Mac, talks to them over local network ports, and asks for macOS permissions such as Accessibility and, optionally, the microphone. We take security problems in these areas seriously and appreciate responsible reports.

## Supported versions

Kestrel is in preview. Only the latest preview release receives security fixes. Older previews will not be patched; please update before reporting, and confirm the problem still exists on the latest release or on `main`.

| Version | Supported |
|---|---|
| Latest preview release (currently 0.1.x, starting with 0.1.8) | Yes |
| Earlier previews and unreleased forks | No |

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub:

1. Go to <https://github.com/iamthehimansh/kestrel/security/advisories/new> (or the repository's **Security** tab, then **Report a vulnerability**).
2. Describe the problem, the affected version or commit, your macOS version and Mac model, and steps to reproduce.
3. Include a proof of concept, logs or screenshots if you have them. Remove tokens, account data and other personal information first.

Do not open a public issue, pull request or discussion for a security problem until a fix has been released.

What to expect:

- An acknowledgement of your report, normally within a week. Kestrel is maintained by volunteers, so please allow for some delay.
- An assessment of whether the report is in scope and how severe it is.
- Updates while a fix is prepared, and credit in the advisory and changelog if you would like it.

Please give us a reasonable amount of time to release a fix before you disclose the issue publicly. We will agree on a disclosure date with you.

## Scope

Reports about the following are in scope:

- **Local gRPC authentication for the native player.** The native player connects to the emulator's gRPC endpoint on a loopback address (`127.0.0.1` or `::1`) only, and Kestrel requires the endpoint to announce JWT authentication. Tokens are signed per connection with a key that is not written to disk, are limited to the player's methods (`getScreenshot`, `streamScreenshot`, `sendKey`), and the public key is removed when the session ends. Examples of in-scope issues: another local user or process obtaining a usable token, the player connecting to a non-loopback or unauthenticated endpoint, tokens authorising methods beyond that list, or keys and tokens being left behind on disk or in logs.
- **ADB use.** Kestrel uses `adb` to install apps, run shell commands, take screenshots and push the `touchd` helper into the guest. Examples: command injection through package names, file names or other arguments; Kestrel talking to a device or emulator it did not start; `touchd` being reachable by or controllable from something other than Kestrel.
- **Keymap parsing.** Keymap JSON files can be shared between users. Examples: a crafted keymap that crashes the app, writes files outside the keymap folder, causes unbounded memory or CPU use, or makes Kestrel inject input other than what the keymap describes.
- **Packaging and distribution.** The build scripts, app bundle and DMG. Examples: files with unsafe permissions in the bundle, scripts that execute untrusted input, or a release artifact that does not match the source.
- **Local data.** Instance data and logs in `~/Library/Application Support/Kestrel` (or `KESTREL_HOME`) being readable or writable by other local users when they should not be.
- **macOS permissions.** Kestrel using Accessibility, input monitoring or microphone access beyond what a feature needs. Microphone passthrough is off by default and must stay that way unless the user enables it.

## Out of scope

- **Game anti-cheat, emulator detection and Play Integrity.** Reports that a game detects or blocks Kestrel are compatibility questions, not security vulnerabilities; use the game compatibility issue form. Requests or proofs of concept for bypassing anti-cheat or integrity checks will not be accepted.
- Vulnerabilities in the Android emulator, Android system images, Google Play services or the games themselves. Please report those to their vendors. If Kestrel's configuration makes such a problem worse, that part is in scope.
- Vulnerabilities in third-party dependencies that do not affect Kestrel's use of them. Please report them upstream; a note to us is welcome if Kestrel needs to update.
- The fact that release builds are ad-hoc signed and not notarized. This is a known, documented limitation of the preview.
- Attacks that require an attacker who already has full control of your macOS user account, or physical access to an unlocked Mac.
- Denial of service against your own VM by changing its settings to unreasonable values.

If you are unsure whether something is in scope, report it privately anyway and we will tell you.
