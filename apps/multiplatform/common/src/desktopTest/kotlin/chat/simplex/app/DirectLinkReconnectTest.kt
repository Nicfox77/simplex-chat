package chat.simplex.app

import chat.simplex.common.model.DirectLinkReconnect
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

class DirectLinkReconnectTest {
  @Test fun unverifiedInvitationNeverRetries() = runBlocking {
    val calls = AtomicInteger()
    val r = DirectLinkReconnect(this, { calls.incrementAndGet(); null }, { true }, {}, {}, { 1 })
    r.remember("inv", DirectLinkReconnect.Attempt(1, null))
    assertFalse(r.stopped(1, true)); assertEquals(0, calls.get())
  }

  @Test fun trustedPairingAcceptsEarlyMatchingCodeAndIgnoresStaleCode() = runBlocking {
    val done = CompletableDeferred<Unit>()
    lateinit var r: DirectLinkReconnect
    r = DirectLinkReconnect(this, {
      repeat(128) { r.sessionCode(1, "old") }; r.sessionCode(2, "fresh")
      DirectLinkReconnect.Attempt(2, 7)
    }, { code -> assertEquals("fresh", code); true }, { fail("successful attempt aborted") }, { done.complete(Unit); Unit }, { 1 })
    r.remember("inv", DirectLinkReconnect.Attempt(1, 7)); r.trust(7)
    assertTrue(r.stopped(1, true))
    withTimeout(1_000) { done.await() }; r.clear()
  }

  @Test fun stopCancelsBackoff() = runBlocking {
    val calls = AtomicInteger()
    val r = DirectLinkReconnect(this, { calls.incrementAndGet(); null }, { true }, {}, {}, { 10_000 })
    r.remember("inv", DirectLinkReconnect.Attempt(1, 7)); r.trust(7); r.stopped(1, true)
    r.replace {}; assertFalse(r.stopped(1, true)); assertEquals(0, calls.get())
  }

  @Test fun stopOwnsLateNativeResultAndAbortsBeforeReplacement() = runBlocking {
    val entered = CompletableDeferred<Unit>(); val finish = CompletableDeferred<Unit>()
    val order = mutableListOf<String>()
    val r = DirectLinkReconnect(this, {
      entered.complete(Unit); finish.await(); DirectLinkReconnect.Attempt(2, 7)
    }, { fail("verification after stop"); false }, { order.add("abort:$it"); Unit }, {}, { 1 })
    r.remember("inv", DirectLinkReconnect.Attempt(1, 7)); r.trust(7); r.stopped(1, true)
    withTimeout(1_000) { entered.await() }
    val stop = launch { r.replace { order.add("replacement") } }
    yield(); finish.complete(Unit); withTimeout(1_000) { stop.join() }
    assertEquals(listOf("abort:2", "replacement"), order)
  }

  @Test fun deletedPairingCannotBeAutomaticallyTrustedAgain() = runBlocking {
    val aborted = CompletableDeferred<Int>()
    val r = DirectLinkReconnect(this, { DirectLinkReconnect.Attempt(2, null) }, { fail("retrusted deleted pairing"); false }, { aborted.complete(it); Unit }, {}, { 1 })
    r.remember("inv", DirectLinkReconnect.Attempt(1, 7)); r.trust(7); r.stopped(1, true)
    assertEquals(2, withTimeout(1_000) { aborted.await() }); r.clear()
  }

  @Test fun transientFailuresBackOffAndRecover() = runBlocking {
    val calls = AtomicInteger(); val delays = mutableListOf<Int>(); val done = CompletableDeferred<Unit>()
    lateinit var r: DirectLinkReconnect
    r = DirectLinkReconnect(this, {
      if (calls.incrementAndGet() < 3) null else { r.sessionCode(2, "fresh"); DirectLinkReconnect.Attempt(2, 7) }
    }, { true }, {}, { done.complete(Unit); Unit }, { delays.add(it); 1 })
    r.remember("inv", DirectLinkReconnect.Attempt(1, 7)); r.trust(7); r.stopped(1, true)
    withTimeout(1_000) { done.await() }; assertEquals(listOf(0, 1, 2), delays); r.clear()
  }

  @Test fun authenticatedStopDisablesRetries() = runBlocking {
    val r = DirectLinkReconnect(this, { fail("reconnect after desktop stop"); null }, { true }, {}, {}, { 1 })
    r.remember("inv", DirectLinkReconnect.Attempt(1, 7)); r.trust(7)
    assertFalse(r.stopped(1, false)); assertFalse(r.stopped(1, true))
  }

  @Test fun lossDuringSuccessfulVerificationStartsAnotherAttempt() = runBlocking {
    val attempts = AtomicInteger(); val done = CompletableDeferred<Unit>()
    lateinit var r: DirectLinkReconnect
    r = DirectLinkReconnect(this, {
      val sequence = 1 + attempts.incrementAndGet()
      r.sessionCode(sequence, "code:$sequence"); DirectLinkReconnect.Attempt(sequence, 7)
    }, { code -> if (code == "code:2") r.stopped(2, true); true }, {}, { done.complete(Unit); Unit }, { 1 })
    r.remember("inv", DirectLinkReconnect.Attempt(1, 7)); r.trust(7); r.stopped(1, true)
    withTimeout(1_000) { done.await() }; assertEquals(2, attempts.get()); r.clear()
  }

  @Test fun earlyAuthenticationFailureCannotRestartOrVerify() = runBlocking {
    val aborted = CompletableDeferred<Int>()
    lateinit var r: DirectLinkReconnect
    r = DirectLinkReconnect(this, {
      r.stopped(2, false); DirectLinkReconnect.Attempt(2, 7)
    }, { fail("verification after authentication failure"); false }, { aborted.complete(it); Unit }, {}, { 1 })
    r.remember("inv", DirectLinkReconnect.Attempt(1, 7)); r.trust(7); r.stopped(1, true)
    assertEquals(2, withTimeout(1_000) { aborted.await() }); assertFalse(r.stopped(2, true))
  }

  @Test fun oldTerminalEventCannotCancelTheCurrentAttempt() = runBlocking {
    val done = CompletableDeferred<Unit>()
    lateinit var r: DirectLinkReconnect
    r = DirectLinkReconnect(this, {
      assertTrue(r.staleEvent(0)); assertFalse(r.staleEvent(2))
      r.stopped(0, false); r.sessionCode(2, "fresh"); DirectLinkReconnect.Attempt(2, 7)
    }, { true }, { fail("stale stop aborted current attempt") }, { done.complete(Unit); Unit }, { 1 })
    r.remember("inv", DirectLinkReconnect.Attempt(1, 7)); r.trust(7); r.stopped(1, true)
    withTimeout(1_000) { done.await() }; r.clear()
  }

  @Test fun backoffSaturatesWithoutOverflow() {
    assertEquals(1_000L, DirectLinkReconnect.retryDelay(0, 1.0))
    assertEquals(30_000L, DirectLinkReconnect.retryDelay(Int.MAX_VALUE, 1.0))
    assertEquals(36_000L, DirectLinkReconnect.retryDelay(100, 1.2))
    assertEquals(800L, DirectLinkReconnect.retryDelay(-1, 0.8))
  }
}
