package chat.simplex.common.model

import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.random.Random

/** Owns retries for one explicitly verified direct link. Invitations are memory-only. */
internal class DirectLinkReconnect(
  private val scope: CoroutineScope,
  private val connect: suspend (String) -> Attempt?,
  private val verify: suspend (String) -> Boolean,
  private val abort: suspend (Int) -> Unit,
  private val connected: (String) -> Unit,
  private val waitMillis: (Int) -> Long = { retryDelay(it) },
  private val confirmationTimeout: Long = 20_000
) {
  data class Attempt(val sequence: Int, val remoteId: Long?)
  class Rejected: Exception()
  private data class Target(val invitation: String, val sequence: Int, val remoteId: Long?, val trusted: Boolean)
  private data class Event(val sequence: Int, val code: String?)
  private val state = Any()
  private val commands = Mutex()
  private val events = Channel<Event>(32, BufferOverflow.DROP_OLDEST)
  private var generation = 0L
  private var target: Target? = null
  private var worker: Job? = null
  private var pendingDisconnect: Int? = null

  // Replacement and stop invalidate the old owner before waiting for native commands.
  suspend fun <T> replace(action: suspend () -> T): T {
    clear()
    return commands.withLock { action() }
  }

  suspend fun <T> command(action: suspend () -> T): T = commands.withLock { action() }

  fun remember(invitation: String, attempt: Attempt) = synchronized(state) {
    target = Target(invitation, attempt.sequence, attempt.remoteId, false)
  }

  fun trust(remoteId: Long) = synchronized(state) {
    target = target?.let { if (it.remoteId == null || it.remoteId == remoteId) it.copy(remoteId = remoteId, trusted = true) else null }
  }

  fun clear() = synchronized(state) {
    generation++
    target = null
    pendingDisconnect = null
    worker?.cancel()
    worker = null
    while (events.tryReceive().isSuccess) { /* discard events from the previous owner */ }
  }

  fun staleEvent(sequence: Int): Boolean = synchronized(state) { target?.let { sequence < it.sequence } == true }

  fun sessionCode(sequence: Int, code: String): Boolean = synchronized(state) {
    if (worker?.isActive != true) false else {
      events.trySend(Event(sequence, code))
      true
    }
  }

  /** True keeps the existing UI session while the owned retry is in progress. */
  fun stopped(sequence: Int, retryable: Boolean): Boolean = synchronized(state) {
    val t = target ?: return false
    if (worker?.isActive == true) {
      if (retryable) pendingDisconnect = sequence
      events.trySend(Event(sequence, null))
      // A terminal event can precede the native connect response. Sequences
      // increase within this controller; reset/replacement clears this owner.
      if (!retryable && sequence >= t.sequence) clear()
      return retryable
    }
    if (!retryable || !t.trusted || t.sequence != sequence) {
      if (t.sequence == sequence) clear()
      return false
    }
    val owner = generation
    val job = scope.launch(start = CoroutineStart.LAZY) { retry(owner, t) }
    worker = job
    job.start()
    true
  }

  private fun current(owner: Long): Boolean = synchronized(state) { generation == owner && target != null }

  private suspend fun retry(owner: Long, original: Target) {
    try {
      var failures = 0
      while (current(owner)) {
        delay(waitMillis(failures++))
        commands.withLock {
          if (!current(owner)) return
          var attempt: Attempt? = null
          var success = false
          try {
            // Native commands can finish after coroutine cancellation. Own their result
            // and abort exactly that sequence before allowing a replacement command.
            attempt = withContext(NonCancellable) { connect(original.invitation) }
            val a = attempt ?: return@withLock
            if (!current(owner)) return
            if (a.remoteId != original.remoteId) throw Rejected()
            synchronized(state) { if (current(owner)) target = original.copy(sequence = a.sequence) }
            val code = withTimeoutOrNull(confirmationTimeout) {
              var event: Event
              do { event = events.receive() } while (event.sequence != a.sequence)
              event.code
            } ?: return@withLock
            if (!current(owner)) return
            success = withContext(NonCancellable) { verify(code) }
            if (success) {
              val accepted = synchronized(state) {
                if (current(owner) && pendingDisconnect != a.sequence) { connected(code); true } else false
              }
              if (accepted) return
              success = false
            }
            if (!current(owner)) return
          } finally {
            if (!success) attempt?.let { a -> withContext(NonCancellable) { abort(a.sequence) } }
          }
        }
      }
    } catch (_: Rejected) {
      synchronized(state) { if (generation == owner) target = null }
    } finally {
      synchronized(state) {
        if (generation == owner) {
          worker = null
          val retrySequence = pendingDisconnect?.takeIf { target?.sequence == it && target?.trusted == true }
          pendingDisconnect = null
          retrySequence?.let { stopped(it, true) }
        }
      }
    }
  }

  companion object {
    // Saturation avoids overflow during long outages; jitter avoids synchronized retries.
    fun retryDelay(failures: Int, jitter: Double = Random.nextDouble(0.8, 1.2)): Long =
      ((1_000L shl failures.coerceIn(0, 5)).coerceAtMost(30_000) * jitter).toLong().coerceIn(800, 36_000)
  }
}
