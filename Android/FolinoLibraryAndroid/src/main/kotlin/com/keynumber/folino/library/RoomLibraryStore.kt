package com.keynumber.folino.library

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
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import java.io.File

/** Room row — 1:1 with the Swift `ScoreRecordWire`. */
@Entity(tableName = "score_records")
data class ScoreRecordEntity(
    @PrimaryKey val id: String,
    val title: String,
    val subtitle: String,
    val composer: String,
    val arranger: String? = null,
    val lyricist: String? = null,
    val copyright: String? = null,
    @ColumnInfo(name = "local_file_name") val localFileName: String,
    @ColumnInfo(name = "content_hash") val contentHash: String = "",
    @ColumnInfo(name = "deleted_at") val deletedAt: Double,
    @ColumnInfo(name = "last_opened_at") val lastOpenedAt: Double = 0.0, // 0 == never opened
    @ColumnInfo(name = "is_favorite") val isFavorite: Boolean = false,
    /**
     * Unix time of import — the key the default library sort ("date added, newest first") orders by.
     * Rows migrated from v1 carry their backfilled `rowid` instead of a real instant; see
     * [MIGRATION_1_2].
     */
    @ColumnInfo(name = "added_at") val addedAt: Double = 0.0,
)

@Dao
interface ScoreRecordDao {
    @Query("SELECT * FROM score_records")
    fun loadAll(): List<ScoreRecordEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsert(record: ScoreRecordEntity)

    /**
     * The two columns a note-edit save derives, written back without touching the rest of the row.
     *
     * A partial update rather than an `upsert`, because the editor's session carries a deliberately partial
     * `ScoreItem` (`EditorBridge.stubRowPendingSave`) — a whole-row write from that side would blank the user's
     * title, tags and dates. See `ScoreRowRefreshing` in `:FolinoEditorAndroid`, which is the seam this backs.
     */
    @Query(
        "UPDATE score_records SET local_file_name = :localFileName, content_hash = :contentHash WHERE id = :id",
    )
    fun refreshAfterSave(id: String, localFileName: String, contentHash: String)

    @Query("DELETE FROM score_records WHERE id = :id")
    fun delete(id: String)
}

@Entity(tableName = "playlists")
data class PlaylistEntity(
    @PrimaryKey val id: String,
    val name: String,
    @ColumnInfo(name = "created_at") val createdAt: Double,
)

@Entity(
    tableName = "playlist_items",
    primaryKeys = ["playlist_id", "score_item_id"],
)
data class PlaylistItemEntity(
    @ColumnInfo(name = "playlist_id") val playlistId: String,
    @ColumnInfo(name = "score_item_id") val scoreItemId: String,
    val position: Int,
)

@Dao
interface PlaylistDao {
    @Query("SELECT * FROM playlists")
    fun loadPlaylists(): List<PlaylistEntity>

    @Query("SELECT * FROM playlist_items ORDER BY playlist_id, position")
    fun loadItems(): List<PlaylistItemEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsertPlaylist(record: PlaylistEntity)

    @Query("DELETE FROM playlist_items WHERE playlist_id = :playlistId")
    fun deleteItems(playlistId: String)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun insertItems(items: List<PlaylistItemEntity>)

    @Query("DELETE FROM playlists WHERE id = :id")
    fun deletePlaylist(id: String)

    @androidx.room.Transaction
    fun replaceItems(playlistId: String, items: List<PlaylistItemEntity>) {
        deleteItems(playlistId)
        insertItems(items)
    }

    @androidx.room.Transaction
    fun deletePlaylistCascade(id: String) {
        deleteItems(id)
        deletePlaylist(id)
    }
}

@Entity(tableName = "tags")
data class TagEntity(
    @PrimaryKey val id: String,
    val name: String,
    @ColumnInfo(name = "color_hex") val colorHex: String,
)

@Entity(
    tableName = "tag_items",
    primaryKeys = ["tag_id", "score_item_id"],
    indices = [androidx.room.Index("tag_id"), androidx.room.Index("score_item_id")],
)
data class TagItemEntity(
    @ColumnInfo(name = "tag_id") val tagId: String,
    @ColumnInfo(name = "score_item_id") val scoreItemId: String,
)

@Dao
interface TagDao {
    @Query("SELECT * FROM tags")
    fun loadTags(): List<TagEntity>

    @Query("SELECT * FROM tag_items")
    fun loadItems(): List<TagItemEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsertTag(record: TagEntity)

    @Query("DELETE FROM tag_items WHERE tag_id = :tagId")
    fun deleteItems(tagId: String)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun insertItems(items: List<TagItemEntity>)

    @Query("DELETE FROM tags WHERE id = :id")
    fun deleteTag(id: String)

    @androidx.room.Transaction
    fun replaceItems(tagId: String, items: List<TagItemEntity>) {
        deleteItems(tagId)
        insertItems(items)
    }

    @androidx.room.Transaction
    fun deleteTagCascade(id: String) {
        deleteItems(id)
        deleteTag(id)
    }
}

@Entity(tableName = "reader_ab_repeat")
data class ReaderAbRepeatEntity(
    @PrimaryKey @ColumnInfo(name = "score_id") val scoreId: String,
    @ColumnInfo(name = "start_measure") val startMeasure: Int,
    @ColumnInfo(name = "end_measure") val endMeasure: Int,
)

@Dao
interface ReaderAbRepeatDao {
    @Query("SELECT * FROM reader_ab_repeat WHERE score_id = :scoreId")
    fun load(scoreId: String): ReaderAbRepeatEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsert(entity: ReaderAbRepeatEntity)

    @Query("DELETE FROM reader_ab_repeat WHERE score_id = :scoreId")
    fun delete(scoreId: String)
}

@Entity(tableName = "reader_preferences")
data class ReaderPreferencesEntity(
    @PrimaryKey @ColumnInfo(name = "score_id") val scoreId: String,
    val json: String,
)

@Dao
interface ReaderPreferencesDao {
    @Query("SELECT json FROM reader_preferences WHERE score_id = :scoreId")
    fun load(scoreId: String): String?

    /** Every stored blob, score id included so the caller can filter to live scores. */
    @Query("SELECT * FROM reader_preferences")
    fun loadAll(): List<ReaderPreferencesEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsert(entity: ReaderPreferencesEntity)
}

@Database(
    entities = [
        ScoreRecordEntity::class,
        PlaylistEntity::class,
        PlaylistItemEntity::class,
        TagEntity::class,
        TagItemEntity::class,
        ReaderAbRepeatEntity::class,
        ReaderPreferencesEntity::class,
    ],
    // v1 was the pre-release canonical schema. From v2 on the app is SHIPPED, so schema changes
    // carry a real migration — a destructive reset would wipe a user's library. The
    // fallbackToDestructiveMigration on the builder stays only as the last resort for a device
    // whose version is not reachable by the registered path (e.g. a dev build's throwaway schema).
    version = 2,
    exportSchema = false,
)
abstract class LibraryDatabase : RoomDatabase() {
    abstract fun dao(): ScoreRecordDao
    abstract fun playlistDao(): PlaylistDao
    abstract fun tagDao(): TagDao
    abstract fun readerAbRepeatDao(): ReaderAbRepeatDao
    abstract fun readerPreferencesDao(): ReaderPreferencesDao
}

/**
 * v1 → v2: adds `score_records.added_at`, the import instant the default library sort ("date added,
 * newest first") orders by. v1 never recorded it.
 *
 * Existing rows are backfilled with their `rowid` rather than with `now`: `rowid` is Room's implicit
 * insertion counter, so the backfilled values preserve the order those scores were imported in (which
 * is also the order the library displayed them in before this column existed) instead of collapsing
 * every one of them to a single identical timestamp. They are tiny numbers next to a real Unix epoch,
 * so every subsequent import sorts above the whole pre-migration library — the correct reading of
 * "newest first" given v1 simply does not know when those scores were added.
 */
internal val MIGRATION_1_2 = object : Migration(1, 2) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL("ALTER TABLE score_records ADD COLUMN added_at REAL NOT NULL DEFAULT 0")
        db.execSQL("UPDATE score_records SET added_at = rowid")
    }
}

/**
 * Kotlin implementation of the generated `@WireletProvided` `LibraryStore`
 * interface, injected into the Swift `LibraryAndroidStore` over JNI.
 *
 * Rule-free backend: it persists whatever record the Swift store hands it
 * (including the `deletedAt` the store computed) and copies/removes files under
 * `filesDir/Scores`. All policy lives in Swift.
 *
 * Room queries run synchronously on the calling (JNI) thread. The pilot's list
 * is tiny, so `allowMainThreadQueries()` is acceptable here; the follow-up is a
 * Kotlin in-memory cache with background write-through (see spec §Risks).
 */
class RoomLibraryStore(context: Context) : LibraryStore, ReaderPreferencesStore {
    private val db = sharedDatabase(context)

    private companion object {
        @Volatile
        private var sharedDb: LibraryDatabase? = null

        /**
         * Process-wide singleton DB so multiple [RoomLibraryStore] instances (the JNI-injected store
         * and the per-score AB-repeat accessor constructed from composition) share one connection
         * pool + invalidation tracker — Room's recommended pattern, and avoids leaking a connection
         * per Reader entry. Pre-release: destructive reset on any schema change (no migrations).
         */
        fun sharedDatabase(context: Context): LibraryDatabase =
            sharedDb ?: synchronized(this) {
                sharedDb ?: Room.databaseBuilder(
                    context.applicationContext,
                    LibraryDatabase::class.java,
                    "folino-library.db",
                ).allowMainThreadQueries()
                    .addMigrations(MIGRATION_1_2)
                    .fallbackToDestructiveMigration()
                    .fallbackToDestructiveMigrationOnDowngrade()
                    .build()
                    .also { sharedDb = it }
            }
    }

    private val dao = db.dao()
    private val playlistDao = db.playlistDao()
    private val tagDao = db.tagDao()

    private val scoresDir: File =
        File(context.applicationContext.filesDir, "Scores").apply { mkdirs() }

    override fun scoresDirectoryPath(): String = scoresDir.absolutePath

    /**
     * Puts the two columns a note-edit save derives back on a score's row, leaving the rest of it alone.
     *
     * Not part of `LibraryStore` (the `@WireletProvided` seam the Swift library store is injected with): this one is
     * called by the EDITOR's file seam, through `ScoreRowRefreshing` in `:FolinoEditorAndroid`, which `:app` binds to
     * this method. Keeping it off the wire interface is what keeps the editor from acquiring a whole library store it
     * has no business holding.
     *
     * Runs on the calling thread, which for a save is the main thread — see this class's note on
     * `allowMainThreadQueries()`. One `UPDATE` by primary key, once per debounced save.
     */
    fun refreshRowAfterSave(id: String, localFileName: String, contentHash: String) =
        dao.refreshAfterSave(id, localFileName, contentHash)

    override fun loadAll(): List<ScoreRecordWire> =
        dao.loadAll().map {
            ScoreRecordWire(
                id = it.id,
                title = it.title,
                subtitle = it.subtitle,
                composer = it.composer,
                arranger = it.arranger,
                lyricist = it.lyricist,
                copyright = it.copyright,
                localFileName = it.localFileName,
                contentHash = it.contentHash,
                deletedAt = it.deletedAt,
                lastOpenedAt = it.lastOpenedAt,
                isFavorite = it.isFavorite,
                addedAt = it.addedAt,
            )
        }

    override fun upsert(record: ScoreRecordWire) {
        dao.upsert(
            ScoreRecordEntity(
                id = record.id,
                title = record.title,
                subtitle = record.subtitle,
                composer = record.composer,
                arranger = record.arranger,
                lyricist = record.lyricist,
                copyright = record.copyright,
                localFileName = record.localFileName,
                contentHash = record.contentHash,
                deletedAt = record.deletedAt,
                lastOpenedAt = record.lastOpenedAt,
                isFavorite = record.isFavorite,
                addedAt = record.addedAt,
            ),
        )
    }

    override fun deleteRecord(id: String) {
        dao.delete(id)
    }

    override fun copyImportedFile(fromPath: String, localFileName: String) {
        File(fromPath).copyTo(File(scoresDir, localFileName), overwrite = true)
    }

    override fun removeFile(localFileName: String) {
        File(scoresDir, localFileName).delete()
    }

    override fun sha256(path: String): String =
        try {
            val md = java.security.MessageDigest.getInstance("SHA-256")
            File(path).inputStream().use { input ->
                val buf = ByteArray(64 * 1024)
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    md.update(buf, 0, n)
                }
            }
            md.digest().joinToString("") { "%02x".format(it.toInt() and 0xFF) }
        } catch (e: Exception) {
            ""
        }

    override fun loadPlaylists(): List<PlaylistRecordWire> =
        playlistDao.loadPlaylists().map { PlaylistRecordWire(it.id, it.name, it.createdAt) }

    override fun loadPlaylistItems(): List<PlaylistItemWire> =
        playlistDao.loadItems().map { PlaylistItemWire(it.playlistId, it.scoreItemId, it.position) }

    override fun upsertPlaylist(record: PlaylistRecordWire) {
        playlistDao.upsertPlaylist(PlaylistEntity(record.id, record.name, record.createdAt))
    }

    override fun replacePlaylistItems(playlistId: String, items: List<PlaylistItemWire>) {
        playlistDao.replaceItems(
            playlistId,
            items.map { PlaylistItemEntity(it.playlistId, it.scoreItemId, it.position) },
        )
    }

    override fun deletePlaylist(id: String) {
        playlistDao.deletePlaylistCascade(id)
    }

    override fun loadTags(): List<TagRecordWire> =
        tagDao.loadTags().map { TagRecordWire(it.id, it.name, it.colorHex) }

    override fun upsertTag(record: TagRecordWire) {
        tagDao.upsertTag(TagEntity(record.id, record.name, record.colorHex))
    }

    override fun deleteTag(id: String) {
        tagDao.deleteTagCascade(id)
    }

    override fun loadTagItems(): List<TagItemWire> =
        tagDao.loadItems().map { TagItemWire(it.tagId, it.scoreItemId) }

    override fun replaceTagItems(tagId: String, items: List<TagItemWire>) {
        tagDao.replaceItems(tagId, items.map { TagItemEntity(it.tagId, it.scoreItemId) })
    }

    fun loadAbRepeat(scoreId: String): Pair<Int, Int>? =
        db.readerAbRepeatDao().load(scoreId)?.let { it.startMeasure to it.endMeasure }

    fun saveAbRepeat(scoreId: String, range: Pair<Int, Int>?) {
        val dao = db.readerAbRepeatDao()
        if (range == null) dao.delete(scoreId)
        else dao.upsert(ReaderAbRepeatEntity(scoreId, range.first, range.second))
    }

    override fun loadJSON(scoreId: String): String =
        db.readerPreferencesDao().load(scoreId) ?: ""

    override fun saveJSON(scoreId: String, json: String) {
        db.readerPreferencesDao().upsert(ReaderPreferencesEntity(scoreId, json))
    }

    /**
     * Stored preferences blobs for live (non-trashed) scores — the launch `score_prefs` snapshot's input.
     *
     * Live-ness is decided in Kotlin against the score rows, not in SQL: this schema carries no live predicate to
     * mirror (`ScoreRecordDao` loads every row and the callers filter), and `deleted_at` is a `Double` sentinel where
     * `0.0` means live rather than a NULL. The comparison is the same one [orderedLivePlaylistScoreIds] uses, so a
     * trashed score can never contribute a `score_prefs` event.
     */
    fun loadAllLiveReaderPreferencesJson(): List<String> {
        val live = dao.loadAll().filter { it.deletedAt == 0.0 }.map { it.id }.toSet()
        return db.readerPreferencesDao().loadAll().filter { it.scoreId in live }.map { it.json }
    }

    /** Live, position-ordered score ids for [playlistId] (or empty). Backs the Reader's auto-advance. */
    fun orderedLivePlaylistScoreIds(playlistId: String): List<String> =
        com.keynumber.folino.library.orderedLivePlaylistScoreIds(loadPlaylistItems(), loadAll(), playlistId)
}

/**
 * A playlist's score ids in `position` order, filtered to the requested playlist and to live scores.
 * "Live" = `deletedAt == 0.0` (the soft-delete sentinel; a non-zero `deletedAt` is a tombstone).
 * Pure so it is unit-tested without Room. Mirrors iOS `orderedLiveIDs()` — used by the Reader's
 * playlist auto-advance to skip scores deleted mid-session.
 */
internal fun orderedLivePlaylistScoreIds(
    items: List<PlaylistItemWire>,
    scores: List<ScoreRecordWire>,
    playlistId: String,
): List<String> {
    val live = scores.filter { it.deletedAt == 0.0 }.map { it.id }.toSet()
    return items.filter { it.playlistId == playlistId }
        .sortedBy { it.position }
        .map { it.scoreItemId }
        .filter { it in live }
}
