package chat.simplex.app

import chat.simplex.common.model.API
import chat.simplex.common.model.ChatError
import chat.simplex.common.model.RemoteHostError
import chat.simplex.common.model.json
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.JsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class RemoteHostErrorTest {
  private fun response(protocolError: String): API = json.decodeFromString(
    """{
      "remoteHostId": 1,
      "error": {
        "type": "errorRemoteHost",
        "rhKey": {"type": "id", "remoteHostId": 1},
        "remoteHostError": {"type": "protocolError", "data": $protocolError}
      }
    }"""
  )

  @Test
  fun closedSessionDecodesAsRemoteErrorInsteadOfInvalidJSON() {
    val r = assertIs<API.Error>(response("""{"type":"sessionClosed"}"""))
    assertEquals(1L, r.remoteHostId)
    val error = assertIs<ChatError.ChatErrorRemoteHost>(r.err).remoteHostError
    assertIs<RemoteHostError.ProtocolError>(error)
    assertTrue(error.connectionUnavailable)
  }

  @Test
  fun unavailableConnectionStatesUseInterruptedSendHandling() {
    for (error in listOf(RemoteHostError.Missing, RemoteHostError.Inactive, RemoteHostError.Timeout,
      RemoteHostError.BadState, RemoteHostError.Disconnected("network lost"))) {
      assertTrue(error.connectionUnavailable, error.string)
    }
    assertFalse(RemoteHostError.Busy.connectionUnavailable)
    assertFalse(RemoteHostError.BadVersion.connectionUnavailable)
  }

  @Test
  fun unexpectedProtocolErrorsStayStructuredAndAreNotTreatedAsNetworkLoss() {
    val payload = """{"type":"remoteControl","rcError":{"type":"identity"},"futureField":true}"""
    val error = assertIs<ChatError.ChatErrorRemoteHost>(assertIs<API.Error>(response(payload)).err).remoteHostError
    val protocol = assertIs<RemoteHostError.ProtocolError>(error)
    assertEquals(json.decodeFromString<JsonObject>(payload), protocol.data)
    assertFalse(protocol.connectionUnavailable)
  }

  @Test
  fun malformedProtocolDiscriminatorDoesNotTriggerInterruptedSendHandling() {
    val error = assertIs<ChatError.ChatErrorRemoteHost>(assertIs<API.Error>(response("""{"type":{}}""")).err).remoteHostError
    assertFalse(error.connectionUnavailable)
  }
}
