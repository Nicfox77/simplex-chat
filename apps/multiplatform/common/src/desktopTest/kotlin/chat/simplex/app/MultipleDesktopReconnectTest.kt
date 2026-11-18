package chat.simplex.app

import chat.simplex.common.model.DirectLinkReconnect
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

class MultipleDesktopReconnectTest {
  @Test fun stoppingOneDesktopDoesNotCancelAnotherPendingReconnect() = runBlocking {
    val firstConnected = CompletableDeferred<Unit>()
    val secondEntered = CompletableDeferred<Unit>()
    val releaseSecond = CompletableDeferred<Unit>()
    val secondConnected = CompletableDeferred<Unit>()
    val firstAttempts = AtomicInteger()
    lateinit var first: DirectLinkReconnect
    lateinit var second: DirectLinkReconnect
    first = DirectLinkReconnect(this, {
      val sequence = firstAttempts.incrementAndGet()
      first.sessionCode(sequence, "first")
      DirectLinkReconnect.Attempt(sequence, 1)
    }, { true }, {}, { firstConnected.complete(Unit); Unit }, { 1 })
    second = DirectLinkReconnect(this, {
      secondEntered.complete(Unit)
      releaseSecond.await()
      second.sessionCode(20, "second")
      DirectLinkReconnect.Attempt(20, 2)
    }, { code -> assertEquals("second", code); true }, {}, { secondConnected.complete(Unit); Unit }, { 1 })
    try {
      first.restore(1)
      second.restore(2)
      withTimeout(2_000) { firstConnected.await(); secondEntered.await() }
      first.clear()
      releaseSecond.complete(Unit)
      withTimeout(2_000) { secondConnected.await() }
      assertEquals(1, firstAttempts.get())
      assertFalse(first.stopped(1, true))
    } finally {
      releaseSecond.complete(Unit)
      first.clear()
      second.clear()
    }
  }
}
