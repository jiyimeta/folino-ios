# Android Play Store screenshots

Automated Google Play marketing screenshots for the Folino Android app, modeled on the VocalTuner
pipeline (scene → marketing frame → fastlane supply). Capture runs as an instrumented test on an
emulator because the Reader renders sheet music via native JNI (cannot run on the host JVM).

## What it produces

6 scenes × 5 locales (`en-US`, `ja-JP`, `ko-KR`, `zh-CN`, `zh-TW`) × 2 devices (phone, 10" tablet)
= **60 PNGs**, each wrapped in a device frame with a localized title/subtitle.

In addition, `collectScreenshots` emits two supplementary assets per run:

- **`images/featureGraphic.png`** — one 1024×500 feature graphic per locale (brand gradient,
  wordmark + tagline left, Reader frame right). `upload_listing` uploads these alongside the text
  metadata.
- **`images/icon.png`** — one 512×512 full-bleed store icon (same file for every locale).
  `upload_listing` uploads it as part of the store listing.

> **Icon upload note:** the Play Developer API can reject icon updates with a validation error.
> Always run `PLAY_VALIDATE_ONLY=1` first to check for rejections before committing the change.
> If the API rejects the icon, upload `icon.png` manually via the Play Console — that path bypasses
> the API validator.

| order | scene | shows |
| --- | --- | --- |
| 10 | Reader + cursor | score open, playback cursor in measure 1, floating play FAB (seek bar hidden) |
| 20 | Display inspector + hidden staves | inspector open, staves 2/3/4 hidden |
| 30 | Whole-piece repeat | playback inspector General section, repeat set to "Repeat one" |
| 40 | AB-section repeat | horizontal layout, accent band + A/B flags over measures 5–7 |
| 50 | Library | library top with three mock scores |
| 60 | PiP-style | faux home screen + floating PiP card (only staves 2/3/4) |

## Generate

Prerequisites: a booted emulator (a large-display AVD such as `Pixel_6_Pro_API_36` avoids clipping
the tablet canvas) and the staged native libs (already present in a normal checkout).

```sh
# from Android/ — target the emulator explicitly if a physical device is also connected
ANDROID_SERIAL=emulator-5554 ./gradlew :app:collectScreenshots
```

This runs the `connectedDebugAndroidTest` capture (`ScreenshotTest.captureAll`) and copies the PNGs
into `fastlane/metadata/android/<locale>/images/<phoneScreenshots|tenInchScreenshots>/<NN>.png`,
plus `featureGraphic.png` and `icon.png` under `fastlane/metadata/android/<locale>/images/`.

The generated PNGs are git-ignored (`fastlane/.gitignore`); regenerate them rather than committing.

## Upload (manual)

```sh
export PLAY_PACKAGE_NAME=com.harmolo.folino
export PLAY_JSON_KEY_PATH=/path/to/play-service-account.json

# Screenshots only (no metadata or changelogs)
PLAY_VALIDATE_ONLY=1 bundle exec fastlane android upload_screenshots   # dry run
bundle exec fastlane android upload_screenshots                        # real upload

# Full listing: title/description + feature graphic + icon + screenshots (no binary)
PLAY_VALIDATE_ONLY=1 bundle exec fastlane android upload_listing       # dry run first (catches icon rejections)
bundle exec fastlane android upload_listing                            # real upload
```

Images only — no binary, metadata, or changelogs are touched by `upload_screenshots`. `upload_listing`
also pushes text metadata, feature graphics, and the store icon.
