# BleepTube

Standalone YouTube profanity-filter tweak for **Feather / ElleKit**. It is independent of YTLite, uYou, YouTube Plus, or any other modded YouTube IPA.

## What it does

- Reads YouTube's timed caption objects.
- Detects configured profanity and censored caption markers.
- Estimates the offending word's position inside each caption cue.
- Temporarily mutes the YouTube player and plays a local censor beep.
- Restores the previous mute state afterwards.
- Attempts to load captions even if you normally keep captions off.
- Hooks the YouTube executable rather than a specific bundle ID, so it can be injected into differently modified IPAs.

## Build with GitHub Actions

Open **Actions → Build BleepTube → Run workflow**. Download the `BleepTube-Feather` artifact when it finishes. It contains the raw `BleepTube.dylib` plus the generated `.deb`.

## Install with Feather

1. Import your existing YouTube IPA into Feather.
2. Open its tweak/injection options.
3. Inject **either** `BleepTube.dylib` **or** the generated `.deb`.
4. Keep ElleKit/tweak injection enabled.
5. Sign and install normally.

Do not inject both files at once.

## Limitations

BleepTube currently depends on YouTube captions. Videos with no caption track cannot be filtered. YouTube exposes caption-level timing here, so BleepTube estimates word timing and may occasionally beep slightly early or late. YouTube private classes can also change between app versions.

## Word list

Edit `BTProfanity()` in `Tweak.x` and rebuild to change the filtered words.
