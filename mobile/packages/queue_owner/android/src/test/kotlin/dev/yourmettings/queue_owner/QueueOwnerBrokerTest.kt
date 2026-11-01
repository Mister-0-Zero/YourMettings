package dev.yourmettings.queue_owner

import org.junit.Assert.*
import org.junit.Test
import java.io.RandomAccessFile
import java.nio.file.Files

class QueueOwnerBrokerTest {
    private val scope = "a".repeat(64)
    @Test fun enginesExcludeEachOtherAndStaleTokensCannotReleaseNewOwner() {
        val root = Files.createTempDirectory("ym-owner-").toFile()
        try {
            val first = QueueOwnerBroker.acquire(root, scope, "ui")!!
            assertNull(QueueOwnerBroker.acquire(root, scope, "worker"))
            assertFalse(QueueOwnerBroker.release(root, scope, "worker", first))
            assertTrue(QueueOwnerBroker.valid(root, scope, "ui", first))
            assertTrue(QueueOwnerBroker.release(root, scope, "ui", first))
            val second = QueueOwnerBroker.acquire(root, scope, "worker")!!
            assertNotEquals(first, second)
            assertFalse(QueueOwnerBroker.release(root, scope, "ui", first))
            assertTrue(QueueOwnerBroker.valid(root, scope, "worker", second))
        } finally { QueueOwnerBroker.releaseEngine("ui"); QueueOwnerBroker.releaseEngine("worker"); root.deleteRecursively() }
    }
    @Test fun detachedEngineReleasesOnlyItsOwnScope() {
        val root = Files.createTempDirectory("ym-owner-").toFile()
        val otherScope = "b".repeat(64)
        try {
            QueueOwnerBroker.acquire(root, scope, "capture")!!
            val other = QueueOwnerBroker.acquire(root, otherScope, "other")!!
            QueueOwnerBroker.releaseEngine("capture")
            assertNotNull(QueueOwnerBroker.acquire(root, scope, "worker"))
            assertTrue(QueueOwnerBroker.valid(root, otherScope, "other", other))
        } finally { QueueOwnerBroker.releaseEngine("capture"); QueueOwnerBroker.releaseEngine("other"); QueueOwnerBroker.releaseEngine("worker"); root.deleteRecursively() }
    }
    @Test fun kernelLockIsCheckedEvenWhenRegistryDoesNotKnowOwner() {
        val root = Files.createTempDirectory("ym-owner-").toFile()
        val directory = java.io.File(root, "scopes/$scope"); directory.mkdirs()
        try {
            RandomAccessFile(java.io.File(directory, "queue-owner.lock"), "rw").use { file ->
                file.channel.lock().use {
                    assertNull(QueueOwnerBroker.acquire(root, scope, "worker"))
                }
            }
            assertNotNull(QueueOwnerBroker.acquire(root, scope, "worker"))
        } finally { QueueOwnerBroker.releaseEngine("worker"); root.deleteRecursively() }
    }
    @Test fun malformedScopeDoesNotCreateDirectories() {
        val root = Files.createTempDirectory("ym-owner-").toFile()
        try {
            assertThrows(IllegalArgumentException::class.java) { QueueOwnerBroker.acquire(root, "../bad", "ui") }
            assertTrue(root.listFiles()!!.isEmpty())
        } finally { root.deleteRecursively() }
    }    @Test fun stalePublishCannotReplaceCommittedManifest() {
        val root = Files.createTempDirectory("ym-publish-").toFile()
        try {
            val token = QueueOwnerBroker.acquire(root, scope, "old")!!
            val directory = java.io.File(root, "scopes/$scope"); directory.mkdirs()
            val target = java.io.File(directory, "draft.json")
            val tmp = java.io.File(directory, "draft.json.$token.first.tmp"); tmp.writeText("stable")
            QueueOwnerBroker.publish(root, scope, "old", token, target.path, tmp.path)
            assertEquals("stable", target.readText())
            QueueOwnerBroker.release(root, scope, "old", token)
            QueueOwnerBroker.acquire(root, scope, "new")!!
            val stale = java.io.File(directory, "draft.json.$token.late.tmp"); stale.writeText("stale")
            assertThrows(IllegalStateException::class.java) { QueueOwnerBroker.publish(root, scope, "old", token, target.path, stale.path) }
            assertEquals("stable", target.readText())
            assertTrue(stale.exists())
        } finally { QueueOwnerBroker.releaseEngine("old"); QueueOwnerBroker.releaseEngine("new"); root.deleteRecursively() }
    }
    @Test fun nativeMutationsCannotEscapeScopeOrReplaceOwnerLock() {
        val root = Files.createTempDirectory("ym-scope-").toFile()
        try {
            val token = QueueOwnerBroker.acquire(root, scope, "ui")!!
            val outside = java.io.File(root, "outside.json"); outside.writeText("keep")
            assertThrows(IllegalArgumentException::class.java) { QueueOwnerBroker.eraseFile(root, scope, "ui", token, outside.path) }
            val lock = java.io.File(root, "scopes/$scope/queue-owner.lock")
            assertThrows(IllegalArgumentException::class.java) { QueueOwnerBroker.eraseFile(root, scope, "ui", token, lock.path) }
            assertEquals("keep", outside.readText())
        } finally { QueueOwnerBroker.releaseEngine("ui"); root.deleteRecursively() }
    }
    @Test fun pcmAppendIsDurableOffsetCheckedAndRejectsDetachedOwner() {
        val root = Files.createTempDirectory("ym-pcm-").toFile()
        val id = "12345678-1234-1234-1234-123456789abc"
        try {
            val token = QueueOwnerBroker.acquire(root, scope, "capture")!!
            val directory = java.io.File(root, "scopes/$scope/drafts/$id"); directory.mkdirs()
            java.io.File(directory, "draft.json").writeText("{}")
            val source = java.io.File(directory, "source.pcm")
            assertEquals(4L, QueueOwnerBroker.appendPcm(root, scope, "capture", token, source.path, 0, byteArrayOf(1, 2, 3, 4)))
            assertArrayEquals(byteArrayOf(1, 2, 3, 4), source.readBytes())
            assertThrows(IllegalStateException::class.java) { QueueOwnerBroker.appendPcm(root, scope, "capture", token, source.path, 0, byteArrayOf(5, 6)) }
            QueueOwnerBroker.releaseEngine("capture")
            val next = QueueOwnerBroker.acquire(root, scope, "worker")!!
            assertThrows(IllegalStateException::class.java) { QueueOwnerBroker.appendPcm(root, scope, "capture", token, source.path, 4, byteArrayOf(5, 6)) }
            assertEquals(6L, QueueOwnerBroker.appendPcm(root, scope, "worker", next, source.path, 4, byteArrayOf(7, 8)))
            assertArrayEquals(byteArrayOf(1, 2, 3, 4, 7, 8), source.readBytes())
        } finally { QueueOwnerBroker.releaseEngine("capture"); QueueOwnerBroker.releaseEngine("worker"); root.deleteRecursively() }
    }
    @Test fun pcmCannotOverwriteManifestOrEscapeDraft() {
        val root = Files.createTempDirectory("ym-pcm-scope-").toFile()
        try {
            val token = QueueOwnerBroker.acquire(root, scope, "capture")!!
            val manifest = java.io.File(root, "scopes/$scope/catalog-folders.json"); manifest.writeText("keep")
            assertThrows(IllegalArgumentException::class.java) { QueueOwnerBroker.appendPcm(root, scope, "capture", token, manifest.path, 0, byteArrayOf(1, 2)) }
            assertEquals("keep", manifest.readText())
        } finally { QueueOwnerBroker.releaseEngine("capture"); root.deleteRecursively() }
    }
    @Test fun publishedWireCannotBeReplacedEvenByCurrentOwner() {
        val root = Files.createTempDirectory("ym-wire-").toFile()
        val id = "12345678-1234-1234-1234-123456789abc"
        try {
            val token = QueueOwnerBroker.acquire(root, scope, "planner")!!
            val directory = java.io.File(root, "scopes/$scope/drafts/$id"); directory.mkdirs()
            val target = java.io.File(directory, "wire-${"c".repeat(64)}-000000.wav")
            val first = java.io.File(directory, "${target.name}.$token.first.tmp"); first.writeBytes(byteArrayOf(1, 2, 3, 4))
            QueueOwnerBroker.publish(root, scope, "planner", token, target.path, first.path)
            val second = java.io.File(directory, "${target.name}.$token.second.tmp"); second.writeBytes(byteArrayOf(9, 8))
            assertThrows(java.io.IOException::class.java) { QueueOwnerBroker.publish(root, scope, "planner", token, target.path, second.path) }
            assertArrayEquals(byteArrayOf(1, 2, 3, 4), target.readBytes())
        } finally { QueueOwnerBroker.releaseEngine("planner"); root.deleteRecursively() }
    }

}
