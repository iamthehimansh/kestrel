# Emulator detection surface: measured limits

This chapter summarizes the separate detection-research work already merged into Kestrel. It is measurement research, **not a claim that Kestrel is undetectable**, a publisher-policy recommendation or a game-protection bypass.

## Why measure instead of rename

Apps can observe several independent properties of their environment: product/build fields, graphics identity, hardware/driver names, services, input devices and integrity/attestation responses. Changing a cosmetic label cannot establish that all such observations changed. Source configuration and actual guest values must be compared after a real boot.

The original diagnostic activity and result-analysis source are retained under [`research/stealth`](../../research/stealth/). The directory's historical name does not describe a supported evasion guarantee. Raw device dumps are withheld from the public history because they include device keys and machine details.

## Recorded experiments

| Change attempted | Measured result | Conclusion |
|---|---|---|
| Device identity profile emitted as launcher properties | Stock Android 16 still reported emulator model/brand/hardware/fingerprint characteristics | Configuration intent did not override existing read-only properties |
| GL vendor/renderer AVD keys | GL strings remained the emulator translator's values | This renderer path did not honor those overrides in the tested build |
| Touch helper/device label changes | Original input implementation continued to function | Renaming is not proof of reduced detectability |
| Naive system image extract/edit/repack | Image reconstruction completed, guest did not finish booting; original configuration restored | Invalid guest image, not a working compatibility solution |

The repeated probe counted **15 → 15 tracked indicators: zero closed** after the property/GL changes. This is a finite probe, not an exhaustive enumeration of what a game may inspect. See the recorded [findings](../../research/stealth/FINDINGS.md).

The failed repack could have lost boot-critical filesystem metadata or verification structures; the experiment did not identify a proven root cause. Earlier notes describe a custom image pipeline as a future direction, but the failed boot does not prove that such a pipeline would solve detection or publisher acceptance. Do not use the historical patch script on valuable user disks.

## Attestation and policy

**Play Integrity and hardware-backed attestation were not tested.** Local property changes do not establish any result about remotely checked integrity. Neither “all checks bypassed” nor “impossible in every conceivable configuration” is supported by these measurements.

A publisher can change policy or detect an emulator independently of this probe. Kestrel does not modify games, offer anti-cheat bypasses, or guarantee an account will be accepted. Compatibility reports should distinguish rendering/input failures from explicit publisher blocking instead of assigning every crash to detection.

## Contributions

Useful contributions improve measurement, test isolation, compatibility documentation and legitimate platform behavior. Preserve original results, negative results and unknowns. Do not publish private keys, user identities, restricted images or proprietary implementation text. Do not present a configuration knob or renamed binary as a successful runtime measurement.
