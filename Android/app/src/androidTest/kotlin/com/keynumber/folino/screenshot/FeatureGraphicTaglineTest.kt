package com.keynumber.folino.screenshot

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.keynumber.folino.screenshot.fixtures.MarketingStrings
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class FeatureGraphicTaglineTest {
    @Test
    fun taglinesPerLocale() {
        assertEquals("Read and play your scores", MarketingStrings.featureGraphicTagline("en"))
        assertEquals("楽譜を、読んで、鳴らす。", MarketingStrings.featureGraphicTagline("ja"))
        assertEquals("악보를 읽고, 연주하세요", MarketingStrings.featureGraphicTagline("ko"))
        assertEquals("读谱，奏乐，练习", MarketingStrings.featureGraphicTagline("zh-Hans"))
        assertEquals("讀譜，奏樂，練習", MarketingStrings.featureGraphicTagline("zh-Hant"))
    }

    @Test
    fun unknownLocaleFallsBackToEnglish() {
        assertEquals("Read and play your scores", MarketingStrings.featureGraphicTagline("xx"))
    }
}
