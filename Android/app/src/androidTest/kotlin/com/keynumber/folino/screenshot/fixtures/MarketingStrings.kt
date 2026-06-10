package com.keynumber.folino.screenshot.fixtures

// Placeholder marketing copy per scene, keyed by language tag. TODO(copy): replace with final
// store copy before release — these are intentionally provisional ("仮").
data class SceneCopy(val title: String, val subtitle: String?)

object MarketingStrings {
    // sceneId -> tag -> copy
    private val table: Map<String, Map<String, SceneCopy>> = mapOf(
        "ReaderCursor" to mapOf(
            "en" to SceneCopy("Read your scores", "Follow along as the music plays"),
            "ja" to SceneCopy("楽譜を表示", "再生に合わせて自動で追従"),
        ),
        "DisplayHidden" to mapOf(
            "en" to SceneCopy("Show only the parts you want", "Hide any staff with a tap"),
            "ja" to SceneCopy("見たいパートだけ表示", "不要な段はタップで非表示"),
        ),
        "Library" to mapOf(
            "en" to SceneCopy("Your whole library", "All your scores in one place"),
            "ja" to SceneCopy("あなたの楽譜棚", "すべての楽譜をひとつに"),
        ),
        "Pip" to mapOf(
            "en" to SceneCopy("Keep playing anywhere", "Picture-in-picture playback"),
            "ja" to SceneCopy("ながら再生", "ピクチャinピクチャで再生"),
        ),
    )

    fun forScene(sceneId: String, tag: String): SceneCopy =
        table[sceneId]?.get(tag) ?: table[sceneId]?.get("en") ?: SceneCopy(sceneId, null)
}
