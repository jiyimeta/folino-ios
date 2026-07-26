package com.keynumber.folino.settings

/**
 * The bank-128 drum kits, loaded once from Swift (`Domain.GMDrumKit`) and cached.
 *
 * Swift is the source of truth: the kit list tracks what the `musescore-general-sf2-split` release actually
 * ships, and a kit outside that list resolves to the Standard fallback — so a Kotlin copy that drifted
 * would silently offer sounds the user never gets. Mirrors how ssm surfaces `GMInstrument`.
 */
data class DrumKit(
    /** Bank-128 program number. */
    val program: Int,
    val displayName: String,
    /** Index into [DrumKitCatalog.familyNames]; kits group under their family in the picker. */
    val familyIndex: Int,
)

object DrumKitCatalog {
    @Volatile private var cached: GMDrumKitCatalogWire? = null

    private fun load(): GMDrumKitCatalogWire =
        cached ?: runCatching { GMDrumKitCatalogWireCodec.decode(SettingsJNI.nativeGMDrumKitCatalog()) }
            .getOrElse { GMDrumKitCatalogWire(familyNames = emptyList(), kits = emptyList()) }
            .also { cached = it }

    /** Family display names in catalog order; [DrumKit.familyIndex] indexes into this. */
    val familyNames: List<String> get() = load().familyNames

    /** Every kit, in the catalog's own order (program order within family order). */
    val entries: List<DrumKit>
        get() = load().kits.map { DrumKit(it.program, it.name, it.familyIndex) }

    /**
     * The kit for a stored program, or null when it is not one the catalog knows. Callers fall back to a
     * synthesized `"Kit N"` label so an override written by a future release still renders — same
     * contract as iOS `GMDrumKit.kit(for:)`.
     */
    fun forProgram(program: Int): DrumKit? = entries.firstOrNull { it.program == program }
}
