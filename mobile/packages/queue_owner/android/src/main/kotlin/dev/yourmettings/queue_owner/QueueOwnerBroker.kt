package dev.yourmettings.queue_owner

import java.io.File
import java.io.RandomAccessFile
import java.io.IOException
import java.nio.channels.FileLock
import java.nio.channels.OverlappingFileLockException
import java.util.UUID

/** Shared registry across Flutter engines, plus advisory kernel lock across processes. */
internal object QueueOwnerBroker {
    private data class Held(val engine: String, val token: String,
                            val file: RandomAccessFile, val lock: FileLock)
    private val held = mutableMapOf<String, Held>()

    private fun lockFile(root: File, scope: String): File {
        require(scope.matches(Regex("[a-f0-9]{64}")))
        val base = root.canonicalFile
        val directory = File(base, "scopes/$scope").canonicalFile
        require(directory.path.startsWith(base.path + File.separator))
        check(directory.isDirectory || directory.mkdirs())
        // Stable inode: never delete/rename this lock alongside manifests.
        return File(directory, "queue-owner.lock")
    }

    @Synchronized
    fun acquire(root: File, scope: String, engine: String): String? {
        val path = lockFile(root, scope)
        val key = path.canonicalPath
        if (held.containsKey(key)) return null
        val file = RandomAccessFile(path, "rw")
        val lock = try {
            file.channel.tryLock()
        } catch (_: OverlappingFileLockException) {
            file.close()
            return null
        } catch (error: Throwable) {
            file.close()
            throw error
        }
        if (lock == null) { file.close(); return null }
        val token = UUID.randomUUID().toString()
        held[key] = Held(engine, token, file, lock)
        return token
    }

    @Synchronized
    fun valid(root: File, scope: String, engine: String, token: String): Boolean {
        val entry = held[lockFile(root, scope).canonicalPath] ?: return false
        return entry.engine == engine && entry.token == token && entry.lock.isValid
    }

    @Synchronized
    fun release(root: File, scope: String, engine: String, token: String): Boolean {
        val key = lockFile(root, scope).canonicalPath
        val entry = held[key] ?: return false
        if (entry.engine != engine || entry.token != token) return false
        try { entry.lock.release() } finally {
            try { entry.file.close() } finally { held.remove(key) }
        }
        return true
    }

    private fun ownedPath(root: File, scope: String, engine: String, token: String, path: String): File {
        check(valid(root, scope, engine, token)) { "Queue ownership lost" }
        val base = File(root, "scopes/$scope").canonicalFile
        val target = File(path).canonicalFile
        require(target.path.startsWith(base.path + File.separator))
        require(target.name != "queue-owner.lock")
        return target
    }

    /** Validate+mutate under the SAME mutex used by release/detach/acquire. */
    @Synchronized
    fun publish(root: File, scope: String, engine: String, token: String, path: String, temporary: String) {
        val target = ownedPath(root, scope, engine, token, path)
        val tmp = ownedPath(root, scope, engine, token, temporary)
        val wire = target.name.matches(Regex("wire-[a-f0-9]{64}-[0-9]{6}\\.wav")) &&
            target.parentFile?.parentFile == File(root, "scopes/$scope/drafts").canonicalFile &&
            target.parentFile!!.name.matches(Regex("[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}"))
        require((target.name.endsWith(".json") || wire) && tmp.parentFile == target.parentFile)
        require(tmp.name.startsWith(target.name + "." + token + ".") && tmp.name.endsWith(".tmp"))
        check(tmp.isFile)
        if (wire && target.exists()) throw IOException("Immutable audio already exists")
        // The old engine can finish ONLY its uniquely named tmp. Publishing is
        // atomic with checking its token and with releasing/acquiring ownership.
        if (!tmp.renameTo(target)) throw IOException("Atomic manifest replacement failed")
    }

    /** PCM16 mono/16kHz source, append-only, under the ownership mutex.
     * An ACK means bytes were fsynced. Detach cannot release the lease midway.
     */
    @Synchronized
    fun appendPcm(root: File, scope: String, engine: String, token: String,
                  path: String, expectedOffset: Long, bytes: ByteArray): Long {
        val target = ownedPath(root, scope, engine, token, path)
        val drafts = File(root, "scopes/$scope/drafts").canonicalFile
        require(target.name == "source.pcm" && target.parentFile?.parentFile == drafts)
        require(target.parentFile!!.name.matches(Regex("[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}")))
        require(target.parentFile!!.isDirectory && File(target.parentFile, "draft.json").isFile)
        require(expectedOffset >= 0 && expectedOffset % 2L == 0L)
        require(bytes.isNotEmpty() && bytes.size <= 65536 && bytes.size % 2 == 0)
        RandomAccessFile(target, "rw").use { file ->
            check(file.length() == expectedOffset) { "PCM offset conflict" }
            file.seek(expectedOffset)
            file.write(bytes)
            file.fd.sync()
            return file.length()
        }
    }

    @Synchronized
    fun eraseFile(root: File, scope: String, engine: String, token: String, path: String) {
        val target = ownedPath(root, scope, engine, token, path)
        require(!target.isDirectory)
        if (!target.delete() && target.exists()) throw IOException("Cleanup failed")
    }

    @Synchronized
    fun eraseDraft(root: File, scope: String, engine: String, token: String, path: String) {
        val target = ownedPath(root, scope, engine, token, path)
        val base = File(root, "scopes/$scope/drafts").canonicalFile
        require(target.parentFile == base && target.name.matches(Regex("[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}")))
        fun erase(file: File) {
            // Never follow a symlink child while recursively cleaning our UUID.
            if (file.canonicalPath == file.absolutePath && file.isDirectory) {
                val children = file.listFiles() ?: throw IOException("Cannot list draft")
                for (child in children) erase(child)
            }
            if (!file.delete() && file.exists()) throw IOException("Draft cleanup incomplete")
        }
        erase(target)
    }

    @Synchronized
    fun releaseEngine(engine: String) {
        val owned = held.filterValues { it.engine == engine }.keys.toList()
        for (key in owned) {
            val entry = held[key] ?: continue
            try { entry.lock.release() } finally {
                try { entry.file.close() } finally { held.remove(key) }
            }
        }
    }
}
