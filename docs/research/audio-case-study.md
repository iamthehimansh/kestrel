# Audio investigation: gameplay silence without a proven root cause

## Report and outcome

The maintainer reported audible startup/lobby audio but missing sounds during gameplay, especially while driving or firing. After a later app/emulator restart, the maintainer reported that audio worked. No audio-specific correction had been shipped in that build, so the restart is an observation, not a proven fix or causal explanation.

The investigation stopped when requested. MuMu comparison was reserved as a fallback after focused Kestrel experiments; it was not needed before the report of recovery. The evidence below is preserved so another contributor does not start by guessing at volume toggles.

## Capture method

During two minutes of user-operated driving/firing, twelve samples were taken, approximately ten seconds apart, from the explicitly identified Game Boss process and guest:

```text
dumpsys audio
dumpsys media.audio_flinger
dumpsys media.audio_policy
```

These were state/diagnostic dumps, not microphone recordings. Process command, console/ADB ports and opened userdata path were checked before access. No audio settings or game actions were changed during capture. Raw dumps stay private because they can identify apps, sessions and the local environment.

Host checks read output volume, device inventory and a five-second sample of the identified emulator process. The sample inspected thread stacks; it did not capture PCM or prove audible output.

## Observations

| Boundary | Observation | What it does not prove |
|---|---|---|
| Android focus/mode | BGMI held focus; normal mode, no observed communication-mode transition | Voice chat can never affect routing in another session |
| Android volume | Media stream at its maximum reported index, no mute in sampled state | Every in-game sound category is enabled |
| BGMI playback | Active OpenSL ES 48 kHz playback track; frame counts advancing | Samples contain the specific gunshots/vehicle sounds the user expects |
| Mixer/output | Nonzero changing output-power history, no reported underruns in the sampled track | Individual sources are audible or physical speakers received them |
| Mac state | Built-in speakers selected, 48 kHz, output volume 100 and unmuted | This default device is necessarily the process's current output route |
| Emulator process | CoreAudio I/O thread present separately from graphics threads; most sampled time waiting | A QEMU callback produced nonzero buffers; no intermittent rendering contention exists |
| Selected audio logs | No errors in the bounded selected-tag query | No errors occurred outside the query's time/tag coverage |

The aggregate power history, roughly −63 to −14 dB in inspected data, was stronger than a mere “track active” flag, but still could not identify which game sounds contributed.

## Hypotheses evaluated

1. **Simple guest or host mute:** contradicted by the sampled mute/volume state; not ruled out for every earlier/later moment.
2. **Voice-chat switches the guest into communication mode:** not observed during this capture. Do not silently disable microphones based on this hypothesis.
3. **GPU-rendered audio or rendering contention:** Unreal's game audio mix feeds a platform audio path; the capture showed OpenSL ES, while host stacks showed CoreAudio separately from graphics. This distinguishes the paths but does not exclude resource contention affecting timing.
4. **Game sound-category/resource issue:** still possible. A nonzero mixed output may contain music/UI/voice without the missing effects. The exact proprietary game's engine configuration was not established from general Unreal documentation.
5. **Emulator-to-Mac playback loss:** still possible. Default-device metadata and an I/O thread do not substitute for measuring the process's actual PCM/output route.

## Next discriminating experiment if it returns

Preserve one audible-lobby sample and one silent-gameplay sample under otherwise identical conditions. Record whether music, voice, engine sounds and gunshots differ. Generate a known finite low-amplitude tone in an original diagnostic app on a disposable instance, separately from game actions. Compare Android output activity with a user-confirmed audible result. If measuring host audio requires a process tap or permission, request that scope explicitly; never capture unrelated apps or a microphone silently.

Change one reversible factor at a time and restore it. Keep BGMI's known-working graphics selection constant unless the experiment specifically tests rendering/audio contention. Do not infer a fix from a successful settings write or an error-free log.

## Microphone is a separate feature

The later 0.1.8 microphone option forwards host input only when enabled and Sound is on, using `-allow-host-audio`. Its unit/build checks do not explain the playback incident, and actual voice-chat capture remains unverified. See [sound and microphone use](../guide/user-guide.md).

References: [Unreal Audio Mixer overview](https://dev.epicgames.com/documentation/en-us/unreal-engine/audio-mixer-overview-in-unreal-engine), [Android OpenSL ES](https://developer.android.com/ndk/guides/audio/opensl/opensl-for-android), [Launcher.swift](../../Sources/KestrelCore/Launcher.swift). General platform documents are context, not proof of BGMI's precise internal implementation.
