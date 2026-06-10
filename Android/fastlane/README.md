# Android Play Store screenshots

Automated Google Play marketing screenshots for the Folino Android app, modeled on the VocalTuner
pipeline (scene → marketing frame → fastlane supply). Capture runs as an instrumented test on an
emulator because the Reader renders sheet music via native JNI (cannot run on the host JVM).

## What it produces

4 scenes × 2 locales (`en-US`, `ja-JP`) × 2 devices (phone, 10" tablet) = **16 PNGs**, each wrapped
in a device frame with a localized title/subtitle (placeholder marketing copy — see
`app/src/androidTest/.../fixtures/MarketingStrings.kt`, marked `TODO(copy)`).

| order | scene | shows |
| --- | --- | --- |
| 10 | Reader + cursor | score open, playback cursor in measure 1 |
| 20 | Display inspector + hidden staves | inspector open, staves 2/3/4 hidden |
| 30 | Library | library top with three mock scores |
| 60 | PiP-style | faux home screen + floating PiP card (only staves 2/3/4) |

Orders **40** and **50** are reserved for the deferred whole-piece-repeat and AB-repeat scenes
(Android has no repeat feature yet — see `docs/superpowers/specs/2026-06-10-android-playstore-screenshots-design.md`).

## Generate

Prerequisites: a booted emulator (a large-display AVD such as `Pixel_6_Pro_API_36` avoids clipping
the tablet canvas) and the staged native libs (already present in a normal checkout).

```sh
# from Android/ — target the emulator explicitly if a physical device is also connected
ANDROID_SERIAL=emulator-5554 ./gradlew :app:collectScreenshots
```

This runs the `connectedDebugAndroidTest` capture (`ScreenshotTest.captureAll`) and copies the PNGs
into `fastlane/metadata/android/<locale>/images/<phoneScreenshots|tenInchScreenshots>/<NN>.png`.

The generated PNGs are git-ignored (`fastlane/.gitignore`); regenerate them rather than committing.

## Upload (manual)

```sh
export PLAY_PACKAGE_NAME=com.keynumber.folino
export PLAY_JSON_KEY_PATH=/path/to/play-service-account.json
PLAY_VALIDATE_ONLY=1 bundle exec fastlane android upload_screenshots   # dry run
bundle exec fastlane android upload_screenshots                        # real upload
```

Images only — no binary, metadata, or changelogs are touched.
