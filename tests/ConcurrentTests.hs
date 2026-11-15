module ConcurrentTests (concurrentTests) where

import Control.Concurrent (yield)
import Control.Concurrent.Async
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (IOException, try)
import Control.Monad (replicateM)
import Data.IORef
import Data.List (sort)
import Simplex.Chat.Controller.Concurrent
import System.Timeout (timeout)
import Test.Hspec

concurrentTests :: Spec
concurrentTests = describe "Single owner UI concurrency" $ do
  describe "command gate" $ do
    it "serializes concurrent local and remote mutations and returns each response to its caller" $ do
      gate <- newCommandGate
      state <- newIORef (0 :: Int)
      let command source = withCommandGate gate $ do
            n <- readIORef state
            yield
            writeIORef state $ n + 1
            pure (source, n + 1)
      results <- mapConcurrently command $ take 200 $ cycle ["local", "remote"]
      readIORef state `shouldReturn` 200
      map fst results `shouldBe` take 200 (cycle ["local", "remote"])
      sort (map snd results) `shouldBe` [1 .. 200]
    it "releases the gate after a command fails" $ do
      gate <- newCommandGate
      result <- try $ withCommandGate gate $ ioError $ userError "command failed"
      (result :: Either IOException ()) `shouldSatisfy` either (const True) (const False)
      timeout 1000000 (withCommandGate gate $ pure True) `shouldReturn` Just True
    it "releases the gate when an executing command is cancelled" $ do
      gate <- newCommandGate
      entered <- newEmptyMVar
      blocked <- newEmptyMVar
      withAsync (withCommandGate gate $ putMVar entered () >> takeMVar blocked) $ \worker -> do
        takeMVar entered
        cancel worker
      timeout 1000000 (withCommandGate gate $ pure True) `shouldReturn` Just True
    it "cancels a waiting command without releasing the executing command's gate" $ do
      gate <- newCommandGate
      entered <- newEmptyMVar
      release <- newEmptyMVar
      withAsync (withCommandGate gate $ putMVar entered () >> takeMVar release) $ \owner -> do
        takeMVar entered
        withAsync (withCommandGate gate $ pure ()) cancel
        timeout 10000 (withCommandGate gate $ pure ()) `shouldReturn` Nothing
        putMVar release ()
        wait owner
      timeout 1000000 (withCommandGate gate $ pure True) `shouldReturn` Just True
  describe "bounded event fan-out" $ do
    it "delivers every event once and in the same order to two independent readers" $ do
      local <- atomically $ newEventBuffer 200
      remote <- atomically $ newEventBuffer 200
      concurrently_
        (mapM_ (atomically . writeEventBuffers [local, remote]) [1 .. 100 :: Int])
        (mapM_ (atomically . writeEventBuffers [local, remote]) [101 .. 200])
      localEvents <- atomically $ replicateM 200 $ readEventBuffer local
      remoteEvents <- atomically $ replicateM 200 $ readEventBuffer remote
      localEvents `shouldBe` remoteEvents
      fmap sort (sequence localEvents) `shouldBe` Right [1 .. 200]
      atomically (tryReadEvent local) `shouldReturn` Nothing
      atomically (tryReadEvent remote) `shouldReturn` Nothing
    it "a paused phone reader cannot block the desktop or event producer" $ do
      pausedReaderTest True
    it "a paused desktop reader cannot block the phone or event producer" $ do
      pausedReaderTest False
    it "invalidates the whole backlog on overflow instead of silently skipping an event" $ do
      buffer <- atomically $ newEventBuffer 1
      atomically $ writeEventBuffer buffer (1 :: Int)
      atomically $ writeEventBuffer buffer 2
      atomically (readEventBuffer buffer) `shouldReturn` Left EBOverflow
      atomically (waitEventBufferClosed buffer) `shouldReturn` EBOverflow
      atomically $ writeEventBuffer buffer 3
      atomically (readEventBuffer buffer) `shouldReturn` Left EBOverflow
    it "detaching wakes a waiting reader and ignores late producers" $ do
      buffer <- atomically $ newEventBuffer 1
      withAsync (atomically $ readEventBuffer buffer) $ \reader -> do
        atomically $ closeEventBuffer buffer EBDetached
        atomically $ writeEventBuffer buffer (1 :: Int)
        timeout 1000000 (wait reader) `shouldReturn` Just (Left EBDetached)
    it "keeps a fresh session isolated from a detached session" $ do
      old <- atomically $ newEventBuffer 1
      new <- atomically $ newEventBuffer 1
      atomically $ do
        closeEventBuffer old EBDetached
        writeEventBuffers [old, new] (1 :: Int)
      atomically (readEventBuffer old) `shouldReturn` Left EBDetached
      atomically (readEventBuffer new) `shouldReturn` Right 1
    it "does not overwrite an overflow with a later detach" $ do
      buffer <- atomically $ newEventBuffer 1
      atomically $ do
        writeEventBuffer buffer (1 :: Int)
        writeEventBuffer buffer 2
        closeEventBuffer buffer EBDetached
      atomically (readEventBuffer buffer) `shouldReturn` Left EBOverflow
    it "permits a producer with no subscribers" $
      timeout 1000000 (atomically $ writeEventBuffers [] ()) `shouldReturn` Just ()

tryReadEvent :: EventBuffer a -> STM (Maybe (Either EventBufferClosed a))
tryReadEvent buffer = (Just <$> readEventBuffer buffer) `orElse` pure Nothing

pausedReaderTest :: Bool -> IO ()
pausedReaderTest pauseLocal = do
  local <- atomically $ newEventBuffer 1
  remote <- atomically $ newEventBuffer 1
  let (paused, active) = if pauseLocal then (local, remote) else (remote, local)
  result <- timeout 1000000 $ mapM (publishAndRead local remote active) [1 .. 100 :: Int]
  result `shouldBe` Just (map Right [1 .. 100])
  atomically (readEventBuffer paused) `shouldReturn` Left EBOverflow
  where
    publishAndRead local remote active event = do
      atomically $ writeEventBuffers [local, remote] event
      atomically $ readEventBuffer active
