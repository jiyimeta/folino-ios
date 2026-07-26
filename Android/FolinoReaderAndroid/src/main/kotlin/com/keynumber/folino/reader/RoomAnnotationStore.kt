package com.keynumber.folino.reader

import android.content.Context
import androidx.room.ColumnInfo
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase

/**
 * Room row — one persisted annotation layer per score. `payload` is the raw layer blob the
 * shared `Domain.AnnotationSaveCoordinator` assembled (byte-identical to iOS's GRDB
 * `annotation_layers.payload` BLOB); `updatedAt` is the layer's updated-at in epoch millis.
 *
 * Room warns that a `ByteArray` field makes structural `equals`/`hashCode` reference-based; that is
 * harmless here — the entity is a transient write/read carrier, never compared or used as a map key.
 */
@Entity(tableName = "annotation_layers")
data class AnnotationLayerEntity(
    @PrimaryKey @ColumnInfo(name = "score_id") val scoreId: String,
    @ColumnInfo(name = "updated_at") val updatedAt: Long,
    val payload: ByteArray,
)

@Dao
interface AnnotationLayerDao {
    @Query("SELECT payload FROM annotation_layers WHERE score_id = :scoreId")
    fun load(scoreId: String): ByteArray?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsert(entity: AnnotationLayerEntity)

    @Query("DELETE FROM annotation_layers WHERE score_id = :scoreId")
    fun delete(scoreId: String)
}

@Database(
    entities = [AnnotationLayerEntity::class],
    // Pre-release: single canonical v1 schema, no migration history. Schema changes reset
    // destructively via fallbackToDestructiveMigration (+ ...OnDowngrade for dev devices that
    // ran a throwaway higher version). Mirrors the Library module's Room policy.
    version = 1,
    exportSchema = false,
)
abstract class AnnotationDatabase : RoomDatabase() {
    abstract fun annotationLayerDao(): AnnotationLayerDao
}

/**
 * Kotlin implementation of the generated `@WireletProvided` `AnnotationPersistenceStore`
 * interface, injected into the Swift `AnnotationSaveBridge` over JNI.
 *
 * Rule-free backend: it persists whatever bytes the coordinator hands it (raw layer payload +
 * the `updatedAtMillis` the coordinator computed). All policy — debounce, empty→delete, layer
 * assembly — lives in the shared `Domain.AnnotationSaveCoordinator`, in lockstep with iOS.
 *
 * Room queries run synchronously on the calling (JNI) thread; a single per-score blob is tiny, so
 * `allowMainThreadQueries()` is acceptable here (mirrors `RoomLibraryStore`).
 */
class RoomAnnotationStore(context: Context) : AnnotationPersistenceStore {
    private val dao = sharedDatabase(context).annotationLayerDao()

    private companion object {
        @Volatile
        private var sharedDb: AnnotationDatabase? = null

        /**
         * Process-wide singleton DB so multiple [RoomAnnotationStore] instances share one connection
         * pool + invalidation tracker (Room's recommended pattern), avoiding a leaked connection per
         * Reader entry. Pre-release: destructive reset on any schema change (no migrations).
         */
        fun sharedDatabase(context: Context): AnnotationDatabase =
            sharedDb ?: synchronized(this) {
                sharedDb ?: Room.databaseBuilder(
                    context.applicationContext,
                    AnnotationDatabase::class.java,
                    "folino-reader-annotations.db",
                ).allowMainThreadQueries()
                    .fallbackToDestructiveMigration()
                    .fallbackToDestructiveMigrationOnDowngrade()
                    .build()
                    .also { sharedDb = it }
            }
    }

    /** Stored payload bytes for [scoreId], or empty when no layer has been saved yet. */
    override fun loadBytes(scoreId: String): ByteArray = dao.load(scoreId) ?: ByteArray(0)

    /** Insert or replace the stored payload bytes for [scoreId], recording [updatedAtMillis]. */
    override fun saveBytes(scoreId: String, updatedAtMillis: Long, bytes: ByteArray) {
        dao.upsert(AnnotationLayerEntity(scoreId, updatedAtMillis, bytes))
    }

    /** Remove the score's annotation layer entirely (the coordinator's empty→delete policy). */
    override fun delete(scoreId: String) {
        dao.delete(scoreId)
    }
}
