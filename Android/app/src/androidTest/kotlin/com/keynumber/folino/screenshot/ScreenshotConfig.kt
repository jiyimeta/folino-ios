package com.keynumber.folino.screenshot

import com.keynumber.folino.screenshot.frame.ScreenshotLayout

// Device classes. On a real device we cannot change screen qualifiers, so the device identity is
// entirely the marketing-frame output size (widthPx×heightPx) + the layout preset's innerDesignWidth.
enum class Device(
    val alias: String,
    val widthPx: Int,
    val heightPx: Int,
    val playDir: String,
    val layout: () -> ScreenshotLayout,
) {
    PHONE("phone", 1080, 1920, "phoneScreenshots", { ScreenshotLayout.phone() }),
    TABLET("tablet", 1280, 1920, "tenInchScreenshots", { ScreenshotLayout.tablet() }),
}

// Locales we ship screenshots for. `tag` is passed to MarketingStrings; `playLocale` is the dir name.
enum class ScreenshotLocale(val tag: String, val playLocale: String) {
    EN("en", "en-US"),
    JA("ja", "ja-JP"),
    KO("ko", "ko-KR"),
    ZH_HANS("zh-Hans", "zh-CN"),
    ZH_HANT("zh-Hant", "zh-TW"),
}
