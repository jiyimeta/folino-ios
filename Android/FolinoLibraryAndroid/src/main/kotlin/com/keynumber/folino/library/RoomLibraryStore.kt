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
    @ColumnInfo(name = "local_file_name") val localFileName: String,
    @ColumnInfo(name = "deleted_at") val deletedAt: Double,
)

@Dao
interface ScoreRecordDao {
    @Query("SELECT * FROM score_records")
    fun loadAll(): List<ScoreRecordEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsert(record: ScoreRecordEntity)
}

@Database(entities = [ScoreRecordEntity::class], version = 1, exportSchema = false)
abstract class LibraryDatabase : RoomDatabase() {
    abstract fun dao(): ScoreRecordDao
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
    private val db = Room.databaseBuilder(
        context.applicationContext,
        LibraryDatabase::class.java,
        "folino-library.db",
    ).allowMainThreadQueries().build()

    private val dao = db.dao()

    private val scoresDir: File =
        File(context.applicationContext.filesDir, "Scores").apply { mkdirs() }

    override fun loadAll(): List<ScoreRecordWire> =
        dao.loadAll().map {
            ScoreRecordWire(it.id, it.title, it.subtitle, it.composer, it.localFileName, it.deletedAt)
        }

    override fun upsert(record: ScoreRecordWire) {
        dao.upsert(
            ScoreRecordEntity(
                id = record.id,
                title = record.title,
                subtitle = record.subtitle,
                composer = record.composer,
                localFileName = record.localFileName,
                deletedAt = record.deletedAt,
            ),
        )
    }

    override fun copyImportedFile(fromPath: String, localFileName: String) {
        File(fromPath).copyTo(File(scoresDir, localFileName), overwrite = true)
    }

    override fun removeFile(localFileName: String) {
        File(scoresDir, localFileName).delete()
    }
}
