package com.keynumber.folino.screenshot.fixtures

// Marketing copy per scene, keyed by language tag. Ported verbatim from the iOS source of truth
// `FolinoScreenshot/ScreenshotStrings.xcstrings` (keys `scene.<name>.title` / `scene.<name>.subtitle`).
// Subtitles keep their `\n` line breaks exactly as authored. `bullet` is per-scene (same across
// locales): when true the frame renders the subtitle lines as a left-aligned bulleted list, matching
// the iOS scenes that set `subtitleBullet: true` (Reader/VisualInspector/PlaybackInspector/Library).
data class SceneCopy(val title: String, val subtitle: String?, val bullet: Boolean = false)

object MarketingStrings {
    // sceneId -> tag -> (title, subtitle). `bullet` is attached per-scene in `forScene`.
    private val table: Map<String, Map<String, SceneCopy>> = mapOf(
        // scene.reader -> ReaderCursor (bullet)
        "ReaderCursor" to mapOf(
            "en" to SceneCopy(
                "View & play scores",
                "Clear, focused notation\nImport MIDI and mscz files",
            ),
            "ja" to SceneCopy(
                "楽譜を表示・再生",
                "見やすく集中できる楽譜表示\nMIDIやmsczを取り込める",
            ),
            "ko" to SceneCopy(
                "악보 보기와 재생",
                "보기 편하고 집중되는 악보 표시\nMIDI와 mscz 가져오기",
            ),
            "zh-Hans" to SceneCopy(
                "显示与播放乐谱",
                "清晰易读、专注的乐谱显示\n可导入 MIDI 和 mscz",
            ),
            "zh-Hant" to SceneCopy(
                "顯示與播放樂譜",
                "清晰易讀、專注的樂譜顯示\n可匯入 MIDI 和 mscz",
            ),
        ),
        // scene.visualInspector -> DisplayHidden (bullet)
        "DisplayHidden" to mapOf(
            "en" to SceneCopy(
                "Flexible display",
                "Change the layout\nShow only the parts you need\nChange clefs",
            ),
            "ja" to SceneCopy(
                "柔軟な表示設定",
                "レイアウトの変更\n必要なパートだけ表示\n音部記号の変更",
            ),
            "ko" to SceneCopy(
                "유연한 표시 설정",
                "레이아웃 변경\n필요한 파트만 표시\n음자리표 변경",
            ),
            "zh-Hans" to SceneCopy(
                "灵活的显示设置",
                "更改排版\n仅显示需要的声部\n更改谱号",
            ),
            "zh-Hant" to SceneCopy(
                "彈性的顯示設定",
                "變更排版\n僅顯示需要的聲部\n變更譜號",
            ),
        ),
        // scene.playbackInspector -> LoopAll (bullet)
        "LoopAll" to mapOf(
            "en" to SceneCopy(
                "Flexible playback",
                "Change tempo and key\nSwitch repeat modes\nAdjust volume per part",
            ),
            "ja" to SceneCopy(
                "柔軟な再生設定",
                "テンポやキーの変更\nリピートモードの切り替え\nパートごとの音量調整",
            ),
            "ko" to SceneCopy(
                "유연한 재생 설정",
                "템포와 조 변경\n반복 모드 전환\n파트별 음량 조절",
            ),
            "zh-Hans" to SceneCopy(
                "灵活的播放设置",
                "调整速度与调号\n切换重复模式\n分声部调节音量",
            ),
            "zh-Hant" to SceneCopy(
                "彈性的播放設定",
                "調整速度與調號\n切換重複模式\n分聲部調節音量",
            ),
        ),
        // scene.abRepeat -> AbRepeat (no bullet)
        "AbRepeat" to mapOf(
            "en" to SceneCopy(
                "A–B Repeat",
                "Loop just the section you choose\nFocus practice on the tricky parts",
            ),
            "ja" to SceneCopy(
                "A–B リピート機能",
                "指定した区間だけループし、\n苦手な部分を重点的に練習",
            ),
            "ko" to SceneCopy(
                "A–B 반복 재생",
                "지정한 구간만 반복하여\n어려운 부분을 집중 연습",
            ),
            "zh-Hans" to SceneCopy(
                "A–B 重复播放",
                "只循环指定的乐段\n集中练习不擅长的部分",
            ),
            "zh-Hant" to SceneCopy(
                "A–B 重複播放",
                "只循環指定的樂段\n集中練習不擅長的部分",
            ),
        ),
        // scene.library -> Library (bullet)
        "Library" to mapOf(
            "en" to SceneCopy(
                "Collect & organize scores",
                "All your scores in one place\nOrganize with playlists and tags",
            ),
            "ja" to SceneCopy(
                "楽譜を集約・整理",
                "すべての楽譜を一か所に\nプレイリストとタグで整理",
            ),
            "ko" to SceneCopy(
                "악보를 한곳에 정리",
                "모든 악보를 한곳에\n재생목록과 태그로 정리",
            ),
            "zh-Hans" to SceneCopy(
                "汇集与整理乐谱",
                "所有乐谱集于一处\n用播放列表和标签整理",
            ),
            "zh-Hant" to SceneCopy(
                "彙整與整理樂譜",
                "所有樂譜集於一處\n用播放列表和標籤整理",
            ),
        ),
        // scene.pip -> Pip (no bullet)
        "Pip" to mapOf(
            "en" to SceneCopy(
                "Picture in Picture",
                "Read scores while using other apps\n*Enable the feature in Settings",
            ),
            "ja" to SceneCopy(
                "ピクチャ・イン・ピクチャ",
                "他のアプリを使いながら譜読み\n※設定画面から機能を有効にしてください。",
            ),
            "ko" to SceneCopy(
                "픽처 인 픽처",
                "다른 앱을 쓰면서 악보 보기\n*설정 화면에서 기능을 켜 주세요",
            ),
            "zh-Hans" to SceneCopy(
                "画中画",
                "使用其他应用时也能看谱\n*请在设置中开启此功能",
            ),
            "zh-Hant" to SceneCopy(
                "子母畫面",
                "使用其他 App 時也能看譜\n*請在設定中開啟此功能",
            ),
        ),
    )

    // Per-scene bullet flag (mirrors the iOS scenes' `subtitleBullet`). Same across all locales.
    private val bulletScenes: Set<String> = setOf(
        "ReaderCursor",
        "DisplayHidden",
        "LoopAll",
        "Library",
    )

    fun forScene(sceneId: String, tag: String): SceneCopy {
        val base = table[sceneId]?.get(tag)
            ?: table[sceneId]?.get("en")
            ?: SceneCopy(sceneId, null)
        return base.copy(bullet = sceneId in bulletScenes)
    }

    // Short marketing-banner tagline for the Play Store feature graphic, per language tag. Tighter than
    // the per-scene subtitles / Play short_description. Falls back to English for unknown tags.
    private val featureGraphicTaglines: Map<String, String> = mapOf(
        "en" to "Read and play your scores",
        "ja" to "楽譜を、読んで、鳴らす。",
        "ko" to "악보를 읽고, 연주하세요",
        "zh-Hans" to "读谱，奏乐，练习",
        "zh-Hant" to "讀譜，奏樂，練習",
    )

    fun featureGraphicTagline(tag: String): String =
        featureGraphicTaglines[tag] ?: featureGraphicTaglines.getValue("en")
}
