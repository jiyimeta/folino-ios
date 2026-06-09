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
    @ColumnInfo(name = "deleted_at") val deletedAt: Double,
    @ColumnInfo(name = "last_opened_at") val lastOpenedAt: Double = 0.0, // 0 == never opened
    @ColumnInfo(name = "is_favorite") val isFavorite: Boolean = false,
)

@Dao
interface ScoreRecordDao {
    @Query("SELECT * FROM score_records")
    fun loadAll(): List<ScoreRecordEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsert(record: ScoreRecordEntity)

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

val MIGRATION_1_2 = object : androidx.room.migration.Migration(1, 2) {
    override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
        db.execSQL(
            "CREATE TABLE IF NOT EXISTS `reader_ab_repeat` (" +
                "`score_id` TEXT NOT NULL, `start_measure` INTEGER NOT NULL, " +
                "`end_measure` INTEGER NOT NULL, PRIMARY KEY(`score_id`))",
        )
    }
}

@Database(
    entities = [
        ScoreRecordEntity::class,
        PlaylistEntity::class,
        PlaylistItemEntity::class,
        TagEntity::class,
        TagItemEntity::class,
        ReaderAbRepeatEntity::class,
    ],
    version = 2,
    exportSchema = false,
)
abstract class LibraryDatabase : RoomDatabase() {
    abstract fun dao(): ScoreRecordDao
    abstract fun playlistDao(): PlaylistDao
    abstract fun tagDao(): TagDao
    abstract fun readerAbRepeatDao(): ReaderAbRepeatDao
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
class RoomLibraryStore(context: Context) : LibraryStore {
    private val db = sharedDatabase(context)

    private companion object {
        @Volatile
        private var sharedDb: LibraryDatabase? = null

        /**
         * Process-wide singleton DB so multiple [RoomLibraryStore] instances (the JNI-injected store
         * and the per-score AB-repeat accessor constructed from composition) share one connection
         * pool + invalidation tracker — Room's recommended pattern, and avoids leaking a connection
         * per Reader entry.
         */
        fun sharedDatabase(context: Context): LibraryDatabase =
            sharedDb ?: synchronized(this) {
                sharedDb ?: Room.databaseBuilder(
                    context.applicationContext,
                    LibraryDatabase::class.java,
                    "folino-library.db",
                ).allowMainThreadQueries().addMigrations(MIGRATION_1_2).fallbackToDestructiveMigration().build()
                    .also { sharedDb = it }
            }
    }

    private val dao = db.dao()
    private val playlistDao = db.playlistDao()
    private val tagDao = db.tagDao()

    private val scoresDir: File =
        File(context.applicationContext.filesDir, "Scores").apply { mkdirs() }

    override fun scoresDirectoryPath(): String = scoresDir.absolutePath

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
                deletedAt = it.deletedAt,
                lastOpenedAt = it.lastOpenedAt,
                isFavorite = it.isFavorite,
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
                deletedAt = record.deletedAt,
                lastOpenedAt = record.lastOpenedAt,
                isFavorite = record.isFavorite,
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
}
