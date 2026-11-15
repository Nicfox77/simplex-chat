-- | Concurrency primitives for the single database-owning controller.
-- These do not create another store, agent, or cryptographic session.
module Simplex.Chat.Controller.Concurrent
  ( CommandGate,
    newCommandGate,
    withCommandGate,
    EventBuffer,
    EventBufferClosed (..),
    newEventBuffer,
    writeEventBuffer,
    writeEventBuffers,
    readEventBuffer,
    closeEventBuffer,
    eventBufferClosed,
    waitEventBufferClosed,
  )
where

import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Monad (void)
import Numeric.Natural (Natural)

-- Separate from chatLock: commands already acquire chat/entity locks internally.
newtype CommandGate = CommandGate (MVar ())

newCommandGate :: IO CommandGate
newCommandGate = CommandGate <$> newMVar ()

-- | Serialize complete commands, releasing the gate on failure or cancellation.
-- Must not be acquired recursively; internal command dispatch stays inside it.
withCommandGate :: CommandGate -> IO a -> IO a
withCommandGate (CommandGate gate) action = withMVar gate $ const action

data EventBufferClosed = EBOverflow | EBDetached
  deriving (Eq, Show)

-- A reader owns one buffer. Sharing it between UIs would distribute events
-- between competing consumers instead of broadcasting them.
data EventBuffer a = EventBuffer (TBQueue a) (TVar (Maybe EventBufferClosed))

newEventBuffer :: Natural -> STM (EventBuffer a)
newEventBuffer capacity = EventBuffer <$> newTBQueue (max 1 capacity) <*> newTVar Nothing

-- | Never retry because a reader paused. On overflow invalidate the entire
-- stream: the consumer must stop and obtain a fresh snapshot before subscribing
-- again. Dropping an arbitrary event and continuing would corrupt UI state.
writeEventBuffer :: EventBuffer a -> a -> STM ()
writeEventBuffer buffer@(EventBuffer queue closed) event = do
  state <- readTVar closed
  case state of
    Just _ -> pure ()
    Nothing -> do
      full <- isFullTBQueue queue
      if full
        then closeEventBuffer buffer EBOverflow
        else writeTBQueue queue event

-- | Each subscriber has an independent bounded buffer. A stalled subscriber
-- cannot block delivery to the others. The caller selects authorized routes;
-- command responses must remain on their request's response channel.
writeEventBuffers :: [EventBuffer a] -> a -> STM ()
writeEventBuffers buffers event = mapM_ (`writeEventBuffer` event) buffers

readEventBuffer :: EventBuffer a -> STM (Either EventBufferClosed a)
readEventBuffer (EventBuffer queue closed) = do
  state <- readTVar closed
  case state of
    Just reason -> pure $ Left reason
    Nothing -> Right <$> readTBQueue queue

-- | Wake pending readers and release retained event data. Closure is terminal;
-- a late producer cannot resurrect a detached reader or replace its reason.
closeEventBuffer :: EventBuffer a -> EventBufferClosed -> STM ()
closeEventBuffer (EventBuffer queue closed) reason = do
  state <- readTVar closed
  case state of
    Just _ -> pure ()
    Nothing -> do
      void $ flushTBQueue queue
      writeTVar closed $ Just reason

waitEventBufferClosed :: EventBuffer a -> STM EventBufferClosed
waitEventBufferClosed buffer = eventBufferClosed buffer >>= maybe retry pure

-- | Inspect revocation without consuming an event or waiting for a producer.
-- Request admission must also check this flag: waking a monitor does not mean
-- that its asynchronous transport cancellation has completed yet.
eventBufferClosed :: EventBuffer a -> STM (Maybe EventBufferClosed)
eventBufferClosed (EventBuffer _ closed) = readTVar closed
