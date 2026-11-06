{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module RemoteTests where

import ChatClient
import ChatTests.DBUtils
import qualified ChatTests.DBUtils as DBU
import ChatTests.Utils
import Control.Concurrent.STM (check)
import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import qualified Data.Aeson as J
import qualified Data.ByteString as B
import Data.ByteString.Builder (toLazyByteString)
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Int (Int64)
import Data.List (find, isPrefixOf, sort)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.Map.Strict as M
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Word (Word32)
import Simplex.Chat.Badges.Types (BadgeIssueFailure (BIFServiceTimeout))
import Simplex.Chat.Controller (ChatCommand (..), ChatConfig (..), versionNumber)
import Simplex.Chat.Files (safeFileNameStr)
import Simplex.Chat.Library.Commands (execChatCommand, parseChatCommand)
import qualified Simplex.Chat.Controller as Controller
import Simplex.Chat.Controller.Concurrent (EventBufferClosed (..), closeEventBuffer, eventBufferClosed, newEventBuffer, writeEventBuffer)
import Simplex.Chat.Mobile.File
import Simplex.Chat.Messages (AChat (..), AChatItem (..), Chat (..), ChatItem (..), ChatRef (..), ChatStats (..), ChatType (..), CIMeta (..), GroupChatScope (..), aChatItemId, aChatItems, chatInfoToRef)
import Simplex.Chat.Options (ChatOpts (..))
import Simplex.Chat.Remote (cancelActiveRemoteCtrl, handleRecv, remoteFilesFolder, validRemoteFileName, withRemoteSession)
import Simplex.Chat.Remote.Protocol (RemoteResponse (..), encryptEncodeHTTP2Body, parseDecryptHTTP2Body, remoteStoreFile)
import Simplex.Chat.Remote.Types
import Simplex.Chat.Terminal.Output (markChatItemRead, remoteReadCommand)
import Simplex.Chat.Types (User (..))
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.File (CryptoFileArgs (..))
import Simplex.Messaging.Encoding (smpEncode)
import Simplex.Messaging.Encoding.String (strEncode)
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (TSbChainKeys (..))
import Simplex.Messaging.Transport.HTTP2 (HTTP2BodyChunk (..), getHTTP2Body)
import Simplex.Messaging.Util
import Simplex.RemoteControl.Types (RCCtrlAddress (..))
import System.Environment (lookupEnv)
import System.FilePath (takeFileName, (</>))
import qualified System.Timeout as Timeout
import Test.Hspec hiding (it)
import UnliftIO
import UnliftIO.Concurrent
import UnliftIO.Directory

remoteTests :: SpecWith TestParams
remoteTests = describe "Remote" $ do
  describe "event routes" $ do
    it "keeps suspension and pairing events local" $ \_ -> do
      Controller.allowRemoteEvent Controller.CEvtChatSuspended `shouldBe` False
      Controller.allowRemoteEvent (Controller.CEvtRemoteCtrlSessionCode Nothing "private code") `shouldBe` False
      Controller.allowRemoteEvent (Controller.CEvtRemoteHostSessionCode Nothing "private code") `shouldBe` False
    it "permits shared application events" $ \_ ->
      Controller.allowRemoteEvent (Controller.CEvtCustomChatEvent Nothing "event") `shouldBe` True
  describe "event receive lifecycle" $ do
    it "reports an empty open buffer as a long-poll timeout" $ \_ -> do
      events <- atomically $ newEventBuffer 1
      result <- handleRecv 1000 events
      result `shouldSatisfy` \case
        RRChatEvent Nothing -> True
        _ -> False
    it "reports a closed buffer as a protocol failure, not an empty poll" $ \_ -> do
      events <- atomically $ newEventBuffer 1
      atomically $ closeEventBuffer events EBDetached
      result <- handleRecv 1000000 events
      result `shouldSatisfy` \case
        RRProtocolError (RPEInvalidBody _) -> True
        _ -> False
    forM_ [EBDetached, EBOverflow] $ \reason ->
      it ("rejects command and file work after " <> show reason <> " before transport shutdown") $ \_ -> do
        events <- atomically $ newEventBuffer 1
        executed <- newIORef False
        atomically $ closeEventBuffer events reason
        result <- withRemoteSession events $ writeIORef executed True
        result `shouldSatisfy` \case
          Left (RRProtocolError (RPEInvalidBody _)) -> True
          _ -> False
        readIORef executed `shouldReturn` False
    it "does not serialize a long poll with command admission" $ \_ -> do
      events <- atomically $ newEventBuffer 1
      withAsync (handleRecv 5000000 events) $ \poller -> do
        result <- Timeout.timeout 1000000 $ withRemoteSession events $ pure True
        result `shouldSatisfy` \case
          Just (Right True) -> True
          _ -> False
        atomically $ closeEventBuffer events EBDetached
        result' <- Timeout.timeout 1000000 $ wait poller
        result' `shouldSatisfy` \case
          Just (RRProtocolError (RPEInvalidBody _)) -> True
          _ -> False
  describe "remote read routing" $
    forM_ [ChatRef CTDirect 2 Nothing, ChatRef CTGroup 3 Nothing, ChatRef CTGroup 3 (Just $ GCSMemberSupport Nothing), ChatRef CTGroup 3 (Just $ GCSMemberSupport $ Just 4)] $ \ref ->
      it ("preserves the chat and scope when encoding a read: " <> show ref) $ \_ ->
        parseChatCommand (remoteReadCommand ref 7) `shouldSatisfy` \case
          Right (APIChatItemsRead ref' ids) -> ref' == ref && ids == 7 :| []
          _ -> False
  describe "/start remote host parser" $ do
    it "parses iface name with a space followed by port=" $ \_ ->
      parseChatCommand "/start remote host new addr=192.168.1.5 iface=\"Ethernet 2\" port=12345"
        `shouldSatisfy` \case
          Right (StartRemoteHost Nothing (Just (RCCtrlAddress _ "Ethernet 2")) (Just 12345)) -> True
          _ -> False
  describe "stored file name" $ do
    it "rejects names with directory components" $ \_ ->
      filter validRemoteFileName ["../x", "../../etc/passwd", "/etc/cron.d/x", "a/b", "x/", "", ".", ".."]
        `shouldBe` []
    it "accepts bare file names" $ \_ ->
      filter (not . validRemoteFileName) ["test.pdf", "test_1.pdf", ".hidden", "a b.tar.gz"]
        `shouldBe` []
    it "sanitizes any name to a real file name" $ \_ ->
      filter (not . sanitized) fileNames `shouldBe` []
    it "sanitizes to a name with no directory components" $ \_ ->
      filter (not . bareName) fileNames `shouldBe` []
  describe "skipped keys" $ do
    it "keeps the most recent skipped keys" $ \_ -> do
      (_, pk) <- atomically . C.generateKeyPair =<< C.newRandom
      let (ck, _) = C.sbcInit "" ("secret" :: B.ByteString)
      sndCounter <- newTVarIO 0
      rcvCounter <- newTVarIO 0
      sndKey <- newTVarIO ck
      rcvKey <- newTVarIO ck
      skippedKeys <- newTVarIO M.empty
      let rc = RemoteCrypto {sessionCode = "", sndCounter, rcvCounter, chainKeys = TSbChainKeys {sndKey, rcvKey}, skippedKeys, signatures = RSSign pk pk, compression = False}
          receive corrId = eitherToMaybe <$> atomically (getRemoteRcvKeys rc corrId)
      sent <- replicateM 1280 $ atomically $ getRemoteSndKeys rc
      let sentKeys = M.fromList [(corrId, (cmdKN, fileKN)) | (corrId, cmdKN, fileKN) <- sent]
      forM_ [256, 512 .. 1280] $ \corrId -> receive corrId `shouldReturn` M.lookup corrId sentKeys
      M.size <$> readTVarIO skippedKeys `shouldReturn` 1024
      receive 251 `shouldReturn` Nothing
      receive 252 `shouldReturn` M.lookup 252 sentKeys
  describe "body size limit" $ do
    it "rejects encrypted body above limit without reading it" $ \_ -> do
      rc <- testRemoteCrypto
      chunks <- newIORef [smpEncode (1 :: Word32, 1025 :: Word32), "body"]
      r <- parseDecryptChunks 1024 rc chunks
      r `shouldSatisfy` \case
        Left RPEInvalidSize -> True
        _ -> False
      readIORef chunks `shouldReturn` ["body"]
    it "rejects decompressed body above limit" $ \_ -> do
      rc <- testRemoteCrypto
      (corrId, cmdKN, _) <- atomically $ getRemoteSndKeys rc
      Right encBody <- runExceptT $ encryptEncodeHTTP2Body corrId cmdKN rc $ LB.replicate 1025 'a'
      chunks <- newIORef $ LB.toChunks $ toLazyByteString encBody
      r <- parseDecryptChunks 1024 rc chunks
      r `shouldSatisfy` \case
        Left (RPEInvalidBody _) -> True
        _ -> False
  xdescribe "No compression" $ aroundWith (. ((False, False),)) runRemoteTests
  xdescribe "Mobile offers compression" $ aroundWith (. ((True, False),)) runRemoteTests
  xdescribe "Desktop offers compression" $ aroundWith (. ((False, True),)) runRemoteTests
  describe "With compression" $ aroundWith (. ((True, True),)) runRemoteTests
  where
    fileNames :: [FilePath]
    fileNames = ["", ".", "..", "...", "../x", "../../etc/passwd", "/etc/cron.d/x", "a/b", "x/", "test.pdf", ".hidden", "a b.tar.gz"]
    sanitized n = let n' = safeFileNameStr n in n' /= "" && n' /= "." && n' /= ".."
    bareName n = let n' = safeFileNameStr n in n' == takeFileName n'

runRemoteTests :: SpecWith ((Bool, Bool), TestParams)
runRemoteTests = do
  describe "protocol handshake" $ do
    it "connects with new pairing (stops mobile)" $ remoteHandshakeTest False
    it "connects with new pairing (stops desktop)" $ remoteHandshakeTest True
    it "connects with stored pairing" remoteHandshakeStoredTest
    xitMacCI "connects with multicast discovery" remoteHandshakeDiscoverTest
    it "refuses invalid client cert" remoteHandshakeRejectTest
    it "connects with stored server bindings" storedBindingsTest
  it "sends messages" remoteMessageTest
  describe "single owner concurrency" $ do
    it "runs phone and desktop sends concurrently against one store, including read and unread state" concurrentOwnerMessagesTest
    it "marks remote messages read on the phone without changing desktop-local unread items" remoteReadOwnershipTest
    it "serializes concurrent phone and desktop profile creation" concurrentOwnerCommandsTest
    it "stops a session whose event reader overflows" remoteEventOverflowTest
    it "recovers an overflow with a new session and an authoritative snapshot" remoteEventRecoveryTest
    it "keeps app-local events on the phone during a live remote session" remoteLocalEventsTest
    it "revokes an explicitly disconnected session before unlinking and ignores stale cleanup" remoteUnlinkTest
    it "revokes the hosted controller when the owner core stops" remoteOwnerStopTest
    it "stops a viewer core with an active remote session without recursive cancellation" remoteViewerStopTest
  describe "remote files" $ do
    it "store/get/send/receive files" remoteStoreFileTest
    it "should send files from CLI without /store" remoteCLIFileTest
  it "switches remote hosts" switchRemoteHostTest
  it "indicates remote hosts" indicateRemoteHostTest
  it "works with multiple profiles" multipleProfilesTest

-- * Chat commands

remoteEventOverflowTest :: HasCallStack => ((Bool, Bool), TestParams) -> IO ()
remoteEventOverflowTest = testRemote $ \compress mobile desktop -> do
  startRemote compress mobile desktop
  let cc = chatController mobile
      session = Controller.remoteCtrlSession cc
  Just (_, Controller.RCSessionConnected {Controller.remoteOutputQ = events}) <- readTVarIO session
  -- Publish the burst in one transaction so the live desktop reader cannot
  -- drain it halfway through and hide the overflow. The producer must return.
  Timeout.timeout 1000000 (atomically $ replicateM_ (fromIntegral (tbqSize $ Controller.config cc) + 1) $
    writeEventBuffer events $ Right $ Controller.CEvtCustomChatEvent Nothing "burst")
    `shouldReturn` Just ()
  Timeout.timeout 5000000 (atomically $ readTVar session >>= check . isNothing)
    `shouldReturn` Just ()
  mobile <## "remote controller stopped"
  eventually 3 $ desktop <## "remote host 1 stopped"

concurrentOwnerCommandsTest :: HasCallStack => ((Bool, Bool), TestParams) -> IO ()
concurrentOwnerCommandsTest = testRemote $ \compress mobile desktop -> do
  startRemote compress mobile desktop
  -- Both commands target the phone's store through the real local/remote
  -- dispatch paths. One creates the profile; the other must observe it before
  -- allocating an agent user or attempting a duplicate store insert.
  let command = "/create user concurrent_owner"
  (localResponse, remoteResponse) <- concurrently
    (runReaderT (execChatCommand Controller.CSLocal command 0) $ chatController mobile)
    (runReaderT (execChatCommand (Controller.CSRemoteHost 1) command 0) $ chatController desktop)
  let responses = [localResponse, remoteResponse]
      created (Right Controller.CRActiveUser {}) = True
      created _ = False
      alreadyExists (Left (Controller.ChatError (Controller.CEUserExists _))) = True
      alreadyExists _ = False
  length (filter created responses) `shouldBe` 1
  length (filter alreadyExists responses) `shouldBe` 1
  stopDesktop mobile desktop

-- These exercise actual local dispatch and encrypted XRCP dispatch, rather than
-- a simulated command gate. UI event fan-out is deliberately not enabled: the
-- snapshots below demonstrate store consistency, not automatic model updates.
concurrentOwnerMessagesTest :: HasCallStack => ((Bool, Bool), TestParams) -> IO ()
concurrentOwnerMessagesTest = testRemote3ManualRead $ \compress mobile desktop bob -> do
  startRemote compress mobile desktop
  contactBob desktop bob
  let local = ownerCommand mobile Controller.CSLocal
      remote = ownerCommand desktop (Controller.CSRemoteHost 1)
  results <- Timeout.timeout 10000000 $ concurrently
    (local "@bob from phone")
    (remote "@bob from desktop")
  (phoneId, desktopId) <- case results of
    Just (Right (Controller.CRNewChatItems _ [phoneItem]), Right (Controller.CRNewChatItems _ [desktopItem])) -> do
      ownerItemText phoneItem `shouldBe` "from phone"
      ownerItemText desktopItem `shouldBe` "from desktop"
      pure (aChatItemId phoneItem, aChatItemId desktopItem)
    _ -> fail $ "concurrent send failed or deadlocked: " <> show results
  phoneId `shouldNotBe` desktopId
  received <- replicateM 2 $ dropTime <$> getTermLine bob
  sort received `shouldBe` ["alice> from desktop", "alice> from phone"]
  (items, _, _) <- ownerSnapshot remote
  map snd (filter (\(i, _) -> i `elem` [phoneId, desktopId]) items)
    `shouldMatchList` ["from phone", "from desktop"]
  ownerSnapshot local `shouldReturn` (items, 0, False)

  -- Read state and manual unread state belong to the phone's store, regardless
  -- of which caller executes the mutation. Neither response is an event today.
  bob #> "@alice unread message"
  desktop <# "bob> unread message"
  (_, unread, _) <- ownerSnapshot local
  unread `shouldBe` 1
  remote "/_read chat @2" >>= expectOwnerOK
  (_, readCount, _) <- ownerSnapshot local
  readCount `shouldBe` 0
  local "/_unread chat @2 on" >>= expectOwnerOK
  (_, _, marked) <- ownerSnapshot remote
  marked `shouldBe` True
  remote "/_unread chat @2 off" >>= expectOwnerOK
  ownerSnapshot local >>= \(_, _, marked') -> marked' `shouldBe` False
  stopDesktop mobile desktop

remoteReadOwnershipTest :: HasCallStack => ((Bool, Bool), TestParams) -> IO ()
remoteReadOwnershipTest = testRemote3ManualRead $ \compress mobile desktop bob -> do
  connectUsers desktop bob
  bob #> "@alice_desktop local unread"
  desktop <# "bob> local unread"
  startRemote compress mobile desktop
  contactBob desktop bob
  bob #> "@alice remote unread"
  desktop <# "bob> remote unread"
  let localDesktop = ownerCommand desktop Controller.CSLocal
      phone = ownerCommand mobile Controller.CSLocal
      remote = ownerCommand desktop (Controller.CSRemoteHost 1)
  (_, localUnread, _) <- ownerSnapshot localDesktop
  localUnread `shouldBe` 1
  (_, phoneUnread, _) <- ownerSnapshot phone
  phoneUnread `shouldBe` 1
  remote "/_get chat @2 count=100" >>= \case
    Right (Controller.CRApiChat user remoteChat _) ->
      case find ((== "remote unread") . ownerItemText) $ aChatItems remoteChat of
        Just item -> markChatItemRead (chatController desktop) (Just 1) user item
        _ -> fail "missing remote item"
    r -> fail $ "remote snapshot failed: " <> show r
  (_, localUnread', _) <- ownerSnapshot localDesktop
  localUnread' `shouldBe` 1
  (_, phoneUnread', _) <- ownerSnapshot phone
  phoneUnread' `shouldBe` 0
  stopDesktop mobile desktop

remoteEventRecoveryTest :: HasCallStack => ((Bool, Bool), TestParams) -> IO ()
remoteEventRecoveryTest = testRemote3ManualRead $ \compress mobile desktop bob -> do
  startRemote compress mobile desktop
  contactBob desktop bob
  let cc = chatController mobile
  Just (_, Controller.RCSessionConnected {Controller.remoteOutputQ = oldEvents}) <- readTVarIO $ Controller.remoteCtrlSession cc
  atomically $ replicateM_ (fromIntegral (tbqSize $ Controller.config cc) + 1) $
    writeEventBuffer oldEvents $ Right $ Controller.CEvtCustomChatEvent Nothing "burst"
  eventually 3 $ mobile <## "remote controller stopped"
  eventually 3 $ desktop <## "remote host 1 stopped"
  bob #> "@alice while desktop was away"
  mobile <# "bob> while desktop was away"
  startRemoteStored compress mobile desktop
  oldRequest <- withRemoteSession oldEvents $ pure ()
  oldRequest `shouldSatisfy` \case
    Left (RRProtocolError (RPEInvalidBody _)) -> True
    _ -> False
  let local = ownerCommand mobile Controller.CSLocal
      remote = ownerCommand desktop (Controller.CSRemoteHost 1)
  snapshot@(items, unread, _) <- ownerSnapshot remote
  map snd items `shouldContain` ["while desktop was away"]
  unread `shouldBe` 1
  ownerSnapshot local `shouldReturn` snapshot
  -- A fresh stream must deliver new events as well as retain the missed data.
  bob #> "@alice after recovery"
  desktop <# "bob> after recovery"
  stopDesktop mobile desktop

ownerCommand :: TestCC -> Controller.CommandSource -> String -> IO (Either Controller.ChatError Controller.ChatResponse)
ownerCommand cc source command = do
  trace <- (== Just "1") <$> lookupEnv "SIMPLEX_OWNER_TEST_TRACE"
  when trace $ putStrLn $ "owner command: " <> command
  result <- Timeout.timeout 30000000 $ runReaderT (execChatCommand source (BC.pack command) 0) $ chatController cc
  when trace $ putStrLn $ "owner response: " <> command
  maybe (fail $ "owner command timed out: " <> command) pure result

ownerSnapshot :: (String -> IO (Either Controller.ChatError Controller.ChatResponse)) -> IO ([(Int64, Text)], Int, Bool)
ownerSnapshot command = command "/_get chat @2 count=100" >>= \case
  Right (Controller.CRApiChat User {userId} ownerChat _) -> do
    -- Paged chat responses deliberately use emptyChatStats. Unread counters
    -- and the manually-unread flag come from the chat-list snapshot instead.
    command ("/_get chats " <> show userId) >>= \case
      Right (Controller.CRApiChats _ previews) -> case find isOwnerChat previews of
        Just (AChat _ Chat {chatStats = ChatStats {unreadCount, unreadChat}}) ->
          pure ([(aChatItemId item, ownerItemText item) | item <- aChatItems ownerChat], unreadCount, unreadChat)
        _ -> fail "owner chat missing from chat list"
      result -> fail $ "owner chat-list snapshot failed: " <> show result
  result -> fail $ "owner snapshot failed: " <> show result
  where
    isOwnerChat (AChat _ Chat {chatInfo}) = chatInfoToRef chatInfo == Just (ChatRef CTDirect 2 Nothing)

ownerItemText :: AChatItem -> Text
ownerItemText (AChatItem _ _ _ ChatItem {meta = CIMeta {itemText}}) = itemText

expectOwnerOK :: HasCallStack => Either Controller.ChatError Controller.ChatResponse -> IO ()
expectOwnerOK result = result `shouldSatisfy` \case
  Right Controller.CRCmdOk {} -> True
  _ -> False

remoteLocalEventsTest :: HasCallStack => ((Bool, Bool), TestParams) -> IO ()
remoteLocalEventsTest = testRemote $ \compress mobile desktop -> do
  startRemote compress mobile desktop
  let cc = chatController mobile
  Just user <- readTVarIO $ Controller.currentUser cc
  let credited = Controller.CEvtStorePurchaseCredited user "local-invoice"
      refused = Controller.CEvtStorePurchaseRefused user "local-invoice" BIFServiceTimeout
  Controller.allowRemoteEvent credited `shouldBe` False
  Controller.allowRemoteEvent refused `shouldBe` False
  Controller.allowRemoteEvent (Controller.CEvtBadgeChanged user Nothing) `shouldBe` True
  runReaderT (Controller.toView' Controller.CEvtChatSuspended) cc
  runReaderT (Controller.toView' credited) cc
  runReaderT (Controller.toView' refused) cc
  runReaderT (Controller.toView' $ Controller.CEvtCustomChatEvent Nothing "shared marker") cc
  desktop <## "shared marker"
  mobile <## "chat suspended"
  mobile <## "store purchase credited: invoice local-invoice"
  mobile <## ("store purchase refused: invoice local-invoice, " <> BC.unpack (strEncode BIFServiceTimeout))
  stopDesktop mobile desktop

remoteUnlinkTest :: HasCallStack => ((Bool, Bool), TestParams) -> IO ()
remoteUnlinkTest = testRemote $ \compress mobile desktop -> do
  startRemote compress mobile desktop
  let cc = chatController mobile
      local = ownerCommand mobile Controller.CSLocal
  Just (sseq, Controller.RCSessionConnected {Controller.remoteOutputQ = oldEvents}) <- readTVarIO $ Controller.remoteCtrlSession cc
  -- A monitor left over from an earlier connection must not revoke this one.
  result <- runReaderT (runExceptT $ cancelActiveRemoteCtrl $ Just (sseq - 1, Controller.RCSRDisconnected)) cc
  result `shouldSatisfy` \case
    Right () -> True
    _ -> False
  atomically (eventBufferClosed oldEvents) `shouldReturn` Nothing
  local "/delete remote ctrl 1" >>= \r -> r `shouldSatisfy` \case
    Left (Controller.ChatErrorRemoteCtrl Controller.RCEBusy) -> True
    _ -> False
  stopMobile mobile desktop
  atomically (eventBufferClosed oldEvents) `shouldReturn` Just EBDetached
  -- Revocation also protects a command that would change the owning database.
  usersBefore <- local "/users"
  rejected <- withRemoteSession oldEvents $ ownerCommand mobile Controller.CSRemoteCtrl "/create user revoked_controller"
  rejected `shouldSatisfy` \case
    Left (RRProtocolError (RPEInvalidBody _)) -> True
    _ -> False
  usersAfter <- local "/users"
  show usersAfter `shouldBe` show usersBefore
  local "/delete remote ctrl 1" >>= expectOwnerOK
  local "/list remote ctrls" >>= \r -> r `shouldSatisfy` \case
    Right (Controller.CRRemoteCtrlList []) -> True
    _ -> False

remoteOwnerStopTest :: HasCallStack => ((Bool, Bool), TestParams) -> IO ()
remoteOwnerStopTest = testRemote $ \compress mobile desktop -> do
  startRemote compress mobile desktop
  let cc = chatController mobile
  Just (_, Controller.RCSessionConnected {Controller.remoteOutputQ = oldEvents}) <- readTVarIO $ Controller.remoteCtrlSession cc
  ownerCommand mobile Controller.CSLocal "/_stop" >>= \r -> r `shouldSatisfy` \case
    Right Controller.CRChatStopped -> True
    _ -> False
  isNothing <$> readTVarIO (Controller.remoteCtrlSession cc) `shouldReturn` True
  atomically (eventBufferClosed oldEvents) `shouldReturn` Just EBDetached
  eventually 3 $ desktop <## "remote host 1 stopped"

remoteViewerStopTest :: HasCallStack => ((Bool, Bool), TestParams) -> IO ()
remoteViewerStopTest = testRemote $ \compress mobile desktop -> do
  startRemote compress mobile desktop
  ownerCommand desktop Controller.CSLocal "/_stop" >>= \r -> r `shouldSatisfy` \case
    Right Controller.CRChatStopped -> True
    _ -> False
  let cc = chatController desktop
  M.null <$> readTVarIO (Controller.remoteHostSessions cc) `shouldReturn` True
  readTVarIO (Controller.currentRemoteHost cc) `shouldReturn` Nothing
  eventually 3 $ mobile <## "remote controller stopped"

remoteHandshakeTest :: HasCallStack => Bool -> ((Bool, Bool), TestParams) -> IO ()
remoteHandshakeTest viaDesktop = testRemote $ \compress mobile desktop -> do
  desktop ##> "/list remote hosts"
  desktop <## "No remote hosts"
  mobile ##> "/list remote ctrls"
  mobile <## "No remote controllers"

  startRemote compress mobile desktop

  desktop ##> "/list remote hosts"
  desktop <## "Remote hosts:"
  desktop <## "1. Mobile (connected)"

  mobile ##> "/list remote ctrls"
  mobile <## "Remote controllers:"
  mobile <## "1. My desktop (connected)"

  if viaDesktop then stopDesktop mobile desktop else stopMobile mobile desktop

  desktop ##> "/delete remote host 1"
  desktop <## "ok"
  desktop ##> "/list remote hosts"
  desktop <## "No remote hosts"

  mobile ##> "/delete remote ctrl 1"
  mobile <## "ok"
  mobile ##> "/list remote ctrls"
  mobile <## "No remote controllers"

remoteHandshakeStoredTest :: HasCallStack => ((Bool, Bool), TestParams) -> IO ()
remoteHandshakeStoredTest = testRemote $ \compress mobile desktop -> do
  logNote "Starting new session"
  startRemote compress mobile desktop
  stopMobile mobile desktop `catchAny` (logError . tshow)

  logNote "Starting stored session"
  startRemoteStored compress mobile desktop
  stopDesktop mobile desktop `catchAny` (logError . tshow)

  desktop ##> "/list remote hosts"
  desktop <## "Remote hosts:"
  desktop <## "1. Mobile"
  mobile ##> "/list remote ctrls"
  mobile <## "Remote controllers:"
  mobile <## "1. My desktop"

  logNote "Starting stored session again"
  startRemoteStored compress mobile desktop
  stopMobile mobile desktop `catchAny` (logError . tshow)

remoteHandshakeDiscoverTest :: HasCallStack => ((Bool, Bool), TestParams) -> IO ()
remoteHandshakeDiscoverTest = testRemote $ \compress mobile desktop -> do
  logNote "Preparing new session"
  startRemote compress mobile desktop
  stopMobile mobile desktop `catchAny` (logError . tshow)

  logNote "Starting stored session with multicast"
  startRemoteDiscover compress mobile desktop
  stopMobile mobile desktop `catchAny` (logError . tshow)

remoteHandshakeRejectTest :: HasCallStack => ((Bool, Bool), TestParams) -> IO ()
remoteHandshakeRejectTest = testRemote3 $ \compress mobile desktop mobileBob -> do
  logNote "Starting new session"
  startRemote compress mobile desktop
  stopMobile mobile desktop

  mobileBob ##> "/set device name MobileBob"
  mobileBob <## "ok"
  desktop ##> "/start remote host 1"
  desktop <##. "remote host 1 started on "
  desktop <##. "other addresses: "
  desktop <## "Remote session invitation:"
  inv <- getTermLine desktop
  mobileBob ##> ("/connect remote ctrl " <> inv)
  mobileBob <## ("connecting new remote controller: My desktop, v" <> versionNumber)
  mobileBob <## "remote controller stopped: this link was used with another controller, please create a new link on the host"

  -- the server remains active after rejecting invalid client
  mobile ##> ("/connect remote ctrl " <> inv)
  mobile <## ("connecting remote controller 1: My desktop, v" <> versionNumber)
  desktop <## "remote host 1 connecting"
  desktop <## "Compare session code with host:"
  sessId <- getTermLine desktop
  mobile <## "remote controller 1 connected"
  mobile <## "Compare session code with controller and use:"
  mobile <## ("/verify remote ctrl " <> sessId)
  mobile ##> ("/verify remote ctrl " <> sessId)
  mobile <## ("remote controller 1 session started with My desktop" <> compress)
  desktop <## ("remote host 1 connected" <> compress)
  stopMobile mobile desktop

storedBindingsTest :: HasCallStack => ((Bool, Bool), TestParams) -> IO ()
storedBindingsTest = testRemote $ \compress mobile desktop -> do
  desktop ##> "/set device name My desktop"
  desktop <## "ok"
  mobile ##> "/set device name Mobile"
  mobile <## "ok"

  desktop ##> "/start remote host new"
  desktop <##. "new remote host started on "
  addrs <- words . dropStrPrefix "other addresses: " <$> getTermLine desktop
  Just localAddress <- pure $ find ("127." `isPrefixOf`) addrs
  desktop <## "Remote session invitation:"
  void $ getTermLine desktop
  desktop ##> "/stop remote host new"
  desktop <## "ok"

  desktop ##> ("/start remote host new addr=" <> localAddress <> " iface=\"lo\" port=" <> remoteTestPort desktop)
  desktop <## ("new remote host started on " <> localAddress <> ":" <> remoteTestPort desktop)
  desktop <##. "other addresses: "
  desktop <## "Remote session invitation:"
  inv <- getTermLine desktop

  mobile ##> ("/connect remote ctrl " <> inv)
  mobile <## ("connecting new remote controller: My desktop, v" <> versionNumber)
  desktop <## "new remote host connecting"
  mobile <## "new remote controller connected"
  verifyRemoteCtrl mobile desktop
  mobile <## ("remote controller 1 session started with My desktop" <> compress)
  desktop <## "new remote host 1 added: Mobile"
  desktop <## ("remote host 1 connected" <> compress)

  desktop ##> "/list remote hosts"
  desktop <## "Remote hosts:"
  desktop <##. "1. Mobile (connected) ["
  stopDesktop mobile desktop
  desktop ##> "/list remote hosts"
  desktop <## "Remote hosts:"
  desktop <##. "1. Mobile ["

-- TODO: more parser tests

remoteMessageTest :: HasCallStack => ((Bool, Bool), TestParams) -> IO ()
remoteMessageTest = testRemote3 $ \compress mobile desktop bob -> do  
  startRemote compress mobile desktop
  contactBob desktop bob

  logNote "sending messages"
  desktop #> "@bob hello there 🙂"
  bob <# "alice> hello there 🙂"
  bob #> "@alice hi"
  desktop <# "bob> hi"

  logNote "post-remote checks"
  stopMobile mobile desktop

  mobile ##> "/contacts"
  mobile <## "bob (Bob)"

  bob ##> "/contacts"
  bob <## "alice (Alice)"

  desktop ##> "/contacts"
  -- empty contact list on desktop-local

  threadDelay 1000000
  logNote "done"

remoteStoreFileTest :: HasCallStack => ((Bool, Bool), TestParams) -> IO ()
remoteStoreFileTest =
  testRemote3 $ \compress mobile desktop bob ->
    withXFTPServer mobile $ do
      let mobileFiles = tmpFile mobile "mobile_files"
      mobile ##> ("/_files_folder " <> mobileFiles)
      mobile <## "ok"
      let desktopFiles = tmpFile desktop "desktop_files"
      desktop ##> ("/_files_folder " <> desktopFiles)
      desktop <## "ok"
      let desktopHostFiles = tmpFile desktop "remote_hosts_data"
      desktop ##> ("/remote_hosts_folder " <> desktopHostFiles)
      desktop <## "ok"
      let bobFiles = tmpFile bob "bob_files"
      bob ##> ("/_files_folder " <> bobFiles)
      bob <## "ok"

      startRemote compress mobile desktop
      contactBob desktop bob

      rhs <- readTVarIO (Controller.remoteHostSessions $ chatController desktop)
      (rhClient, desktopHostStore) <- case M.lookup (RHId 1) rhs of
        Just (_, RHSessionConnected {rhClient, storePath}) ->
          pure (rhClient, desktopHostFiles </> storePath </> remoteFilesFolder)
        _ -> fail "Host session 1 should be started"
      desktop ##> "/store remote file 1 tests/fixtures/test.pdf"
      desktop <## "file test.pdf stored on remote host 1"
      src <- B.readFile "tests/fixtures/test.pdf"
      B.readFile (mobileFiles </> "test.pdf") `shouldReturn` src
      B.readFile (desktopHostStore </> "test.pdf") `shouldReturn` src
      desktop ##> "/store remote file 1 tests/fixtures/test.pdf"
      desktop <## "file test_1.pdf stored on remote host 1"
      B.readFile (mobileFiles </> "test_1.pdf") `shouldReturn` src
      B.readFile (desktopHostStore </> "test_1.pdf") `shouldReturn` src
      desktop ##> "/store remote file 1 encrypt=on tests/fixtures/test.pdf"
      desktop <## "file test_2.pdf stored on remote host 1"
      Just cfArgs@(CFArgs key nonce) <- J.decode . LB.pack <$> getTermLine desktop
      chatReadFile (mobileFiles </> "test_2.pdf") (strEncode key) (strEncode nonce) `shouldReturn` Right (LB.fromStrict src)
      chatReadFile (desktopHostStore </> "test_2.pdf") (strEncode key) (strEncode nonce) `shouldReturn` Right (LB.fromStrict src)

      -- the host rejects a traversal name before draining the attachment; only calling the protocol
      -- directly can put such a name on the wire, as /store remote file sanitizes it controller-side
      runExceptT (remoteStoreFile rhClient "tests/fixtures/test.pdf" "../x") >>= \case
        Left (RPEInvalidBody _) -> pure ()
        r -> fail $ "expected RPEInvalidBody, got " <> show r
      doesFileExist (tmpFile mobile "x") `shouldReturn` False
      -- the undrained attachment did not break the session
      desktop ##> "/store remote file 1 tests/fixtures/test.pdf"
      desktop <## "file test_3.pdf stored on remote host 1"
      B.readFile (mobileFiles </> "test_3.pdf") `shouldReturn` src

      removeFile (desktopHostStore </> "test_1.pdf")
      removeFile (desktopHostStore </> "test_2.pdf")

      -- cannot get file before it is used
      desktop ##> "/get remote file 1 {\"userId\": 1, \"fileId\": 1, \"sent\": true, \"fileSource\": {\"filePath\": \"test_1.pdf\"}}"
      hostError desktop "SEFileNotFound"
      -- send file not encrypted locally on mobile host
      desktop ##> "/_send @2 json [{\"filePath\": \"test_1.pdf\", \"msgContent\": {\"type\": \"file\", \"text\": \"sending a file\"}}]"
      desktop <# "@bob sending a file"
      desktop <# "/f @bob test_1.pdf"
      desktop <## "use /fc 1 to cancel sending"
      bob <# "alice> sending a file"
      bob <# "alice> sends file test_1.pdf (266.0 KiB / 272376 bytes)"
      bob <## "use /fr 1 [<dir>/ | <path>] to receive it"
      bob ##> "/fr 1"
      concurrentlyN_
        [ do
            desktop <## "completed uploading file 1 (test_1.pdf) for bob",
          do
            bob
              <### [ "saving file 1 from alice to test_1.pdf",
                     "started receiving file 1 (test_1.pdf) from alice"
                   ]
            bob <## "completed receiving file 1 (test_1.pdf) from alice"
        ]
      B.readFile (bobFiles </> "test_1.pdf") `shouldReturn` src
      -- returns error for inactive user
      desktop ##> "/get remote file 1 {\"userId\": 2, \"fileId\": 1, \"sent\": true, \"fileSource\": {\"filePath\": \"test_1.pdf\"}}"
      hostError desktop "CEDifferentActiveUser"
      -- returns error with incorrect file ID
      desktop ##> "/get remote file 1 {\"userId\": 1, \"fileId\": 2, \"sent\": true, \"fileSource\": {\"filePath\": \"test_1.pdf\"}}"
      hostError desktop "SEFileNotFound"
      -- gets file
      doesFileExist (desktopHostStore </> "test_1.pdf") `shouldReturn` False
      desktop ##> "/get remote file 1 {\"userId\": 1, \"fileId\": 1, \"sent\": true, \"fileSource\": {\"filePath\": \"test_1.pdf\"}}"
      desktop <## "ok"
      B.readFile (desktopHostStore </> "test_1.pdf") `shouldReturn` src

      -- send file encrypted locally on mobile host
      desktop ##> ("/_send @2 json [{\"fileSource\": {\"filePath\":\"test_2.pdf\", \"cryptoArgs\": " <> LB.unpack (J.encode cfArgs) <> "}, \"msgContent\": {\"type\": \"file\", \"text\": \"\"}}]")
      desktop <# "/f @bob test_2.pdf"
      desktop <## "use /fc 2 to cancel sending"
      bob <# "alice> sends file test_2.pdf (266.0 KiB / 272376 bytes)"
      bob <## "use /fr 2 [<dir>/ | <path>] to receive it"
      bob ##> "/fr 2"
      concurrentlyN_
        [ do
            desktop <## "completed uploading file 2 (test_2.pdf) for bob",
          do
            bob
              <### [ "saving file 2 from alice to test_2.pdf",
                     "started receiving file 2 (test_2.pdf) from alice"
                   ]
            bob <## "completed receiving file 2 (test_2.pdf) from alice"
        ]
      B.readFile (bobFiles </> "test_2.pdf") `shouldReturn` src

      -- receive file via remote host
      copyFile "./tests/fixtures/test.jpg" (bobFiles </> "test.jpg")
      bob #> "/f @alice test.jpg"
      bob <## "use /fc 3 to cancel sending"
      desktop <# "bob> sends file test.jpg (136.5 KiB / 139737 bytes)"
      desktop <## "use /fr 3 [<dir>/ | <path>] to receive it"
      desktop ##> "/fr 3 encrypt=on"
      concurrentlyN_
        [ do
            bob <## "completed uploading file 3 (test.jpg) for alice",
          do
            desktop
              <### [ "saving file 3 from bob to test.jpg",
                     "started receiving file 3 (test.jpg) from bob"
                   ]
            desktop <## "completed receiving file 3 (test.jpg) from bob"
        ]
      Just cfArgs'@(CFArgs key' nonce') <- J.decode . LB.pack <$> getTermLine desktop
      desktop <## "File received to connected remote host 1"
      desktop <## "To download to this device use:"
      getCmd <- getTermLine desktop
      getCmd `shouldBe` ("/get remote file 1 {\"userId\":1,\"fileId\":3,\"sent\":false,\"fileSource\":{\"filePath\":\"test.jpg\",\"cryptoArgs\":" <> LB.unpack (J.encode cfArgs') <> "}}")
      src' <- B.readFile (bobFiles </> "test.jpg")
      chatReadFile (mobileFiles </> "test.jpg") (strEncode key') (strEncode nonce') `shouldReturn` Right (LB.fromStrict src')
      doesFileExist (desktopHostStore </> "test.jpg") `shouldReturn` False
      -- returns error with incorrect key
      desktop ##> "/get remote file 1 {\"userId\": 1, \"fileId\": 3, \"sent\": false, \"fileSource\": {\"filePath\": \"test.jpg\", \"cryptoArgs\": null}}"
      hostError desktop "SEFileNotFound"
      doesFileExist (desktopHostStore </> "test.jpg") `shouldReturn` False
      desktop ##> getCmd
      desktop <## "ok"
      chatReadFile (desktopHostStore </> "test.jpg") (strEncode key') (strEncode nonce') `shouldReturn` Right (LB.fromStrict src')

      stopMobile mobile desktop
  where
    hostError cc err = do
      r <- getTermLine cc
      r `shouldStartWith` "remote host 1 error"
      r `shouldContain` err

remoteCLIFileTest :: HasCallStack => ((Bool, Bool), TestParams) -> IO ()
remoteCLIFileTest = testRemote3 $ \compress mobile desktop bob -> withXFTPServer mobile $ do
  let mobileFiles = tmpFile mobile "mobile_files"
  mobile ##> ("/_files_folder " <> mobileFiles)
  mobile <## "ok"
  let bobFiles = tmpFile bob "bob_files/"
  createDirectoryIfMissing True bobFiles
  let desktopHostFiles = tmpFile desktop "remote_hosts_data"
  desktop ##> ("/remote_hosts_folder " <> desktopHostFiles)
  desktop <## "ok"

  startRemote compress mobile desktop
  contactBob desktop bob

  rhs <- readTVarIO (Controller.remoteHostSessions $ chatController desktop)
  desktopHostStore <- case M.lookup (RHId 1) rhs of
    Just (_, RHSessionConnected {storePath}) -> pure $ desktopHostFiles </> storePath </> remoteFilesFolder
    _ -> fail "Host session 1 should be started"

  mobileName <- userName mobile

  bob #> ("/f @" <> mobileName <> " " <> "tests/fixtures/test.pdf")
  bob <## "use /fc 1 to cancel sending"

  desktop <# "bob> sends file test.pdf (266.0 KiB / 272376 bytes)"
  desktop <## "use /fr 1 [<dir>/ | <path>] to receive it"
  desktop ##> "/fr 1"
  concurrentlyN_
    [ do
        bob <## "completed uploading file 1 (test.pdf) for alice",
      do
        desktop
          <### [ "saving file 1 from bob to test.pdf",
                 "started receiving file 1 (test.pdf) from bob"
               ]
        desktop <## "completed receiving file 1 (test.pdf) from bob"
    ]

  desktop <## "File received to connected remote host 1"
  desktop <## "To download to this device use:"
  getCmd <- getTermLine desktop
  src <- B.readFile "tests/fixtures/test.pdf"
  B.readFile (mobileFiles </> "test.pdf") `shouldReturn` src
  doesFileExist (desktopHostStore </> "test.pdf") `shouldReturn` False
  desktop ##> getCmd
  desktop <## "ok"
  B.readFile (desktopHostStore </> "test.pdf") `shouldReturn` src

  desktop `send` "/f @bob tests/fixtures/test.jpg"
  desktop <# "/f @bob test.jpg"
  desktop <## "use /fc 2 to cancel sending"

  bob <# "alice> sends file test.jpg (136.5 KiB / 139737 bytes)"
  bob <## "use /fr 2 [<dir>/ | <path>] to receive it"
  bob ##> ("/fr 2 " <> bobFiles)
  concurrentlyN_
    [ do
        desktop <## "completed uploading file 2 (test.jpg) for bob",
      do
        bob
          <### [ ConsoleString ("saving file 2 from alice to " <> bobFiles <> "test.jpg"),
                 "started receiving file 2 (test.jpg) from alice"
               ]
        bob <## "completed receiving file 2 (test.jpg) from alice"
    ]

  src' <- B.readFile "tests/fixtures/test.jpg"
  B.readFile (mobileFiles </> "test.jpg") `shouldReturn` src'
  B.readFile (desktopHostStore </> "test.jpg") `shouldReturn` src'
  B.readFile (bobFiles </> "test.jpg") `shouldReturn` src'

  stopMobile mobile desktop

switchRemoteHostTest :: HasCallStack => ((Bool, Bool), TestParams) -> IO ()
switchRemoteHostTest = testRemote3 $ \compress mobile desktop bob -> do
  startRemote compress mobile desktop
  contactBob desktop bob

  desktop ##> "/contacts"
  desktop <## "bob (Bob)"

  desktop ##> "/switch remote host local"
  desktop <## "Using local profile"
  desktop ##> "/contacts"

  desktop ##> "/switch remote host 1"
  desktop <## "Using remote host 1 (Mobile)"
  desktop ##> "/contacts"
  desktop <## "bob (Bob)"

  desktop ##> "/switch remote host 123"
  desktop <## "no remote host 123"

  stopDesktop mobile desktop
  desktop ##> "/contacts"
  desktop ##> "/switch remote host 1"
  desktop <## "remote host 1 error: RHEInactive"
  desktop ##> "/contacts"

indicateRemoteHostTest :: HasCallStack => ((Bool, Bool), TestParams) -> IO ()
indicateRemoteHostTest = testRemote4 $ \compress mobile desktop bob cath -> do
  connectUsers desktop cath
  startRemote compress mobile desktop
  contactBob desktop bob
  -- remote contact -> remote host
  bob #> "@alice hi"
  desktop <#. "bob> hi"
  -- local -> remote
  cath #> "@alice_desktop hello"
  (desktop, "[local] ") ^<# "cath> hello"
  -- local -> local
  desktop ##> "/switch remote host local"
  desktop <## "Using local profile"
  desktop <##> cath
  -- local -> remote
  bob #> "@alice what's up?"
  (desktop, "[remote: 1] ") ^<# "bob> what's up?"

  -- local -> local after disconnect
  stopDesktop mobile desktop
  desktop <##> cath
  cath <##> desktop

multipleProfilesTest :: HasCallStack => ((Bool, Bool), TestParams) -> IO ()
multipleProfilesTest = testRemote4 $ \compress mobile desktop bob cath -> do
  connectUsers desktop cath

  desktop ##> "/create user desk_bottom"
  desktop <## "user profile: desk_bottom"
  desktop <## "use /p <name> [<bio>] to change it"
  desktop ##> "/users"
  desktop <## "alice_desktop (Alice Desktop)"
  desktop <## "desk_bottom (active)"

  startRemote compress mobile desktop
  contactBob desktop bob
  desktop ##> "/users"
  desktop <## "alice (Alice) (active)"

  desktop ##> "/create user alt_alice"
  desktop <## "user profile: alt_alice"
  desktop <## "use /p <name> [<bio>] to change it"

  desktop ##> "/users"
  desktop <## "alice (Alice)"
  desktop <## "alt_alice (active)"

  desktop ##> "/user"
  desktop <## "user profile: alt_alice"
  desktop <## "use /p <name> [<bio>] to change it"

  bob #> "@alice hi"
  (desktop, "[user: alice] ") ^<# "bob> hi"

  cath #> "@alice_desktop hello"
  (desktop, "[local, user: alice_desktop] ") ^<# "cath> hello"

  desktop ##> "/switch remote host local"
  desktop <## "Using local profile"
  desktop ##> "/user"
  desktop <## "user profile: desk_bottom"
  desktop <## "use /p <name> [<bio>] to change it"

  bob #> "@alice hey"
  (desktop, "[remote: 1, user: alice] ") ^<# "bob> hey"

  stopDesktop mobile desktop

-- * Utils

testRemote :: HasCallStack => (String -> TestCC -> TestCC -> IO()) -> ((Bool, Bool), TestParams) -> IO ()
testRemote = testRemoteWithOpts testOpts

testRemoteWithOpts :: HasCallStack => ChatOpts -> (String -> TestCC -> TestCC -> IO ()) -> ((Bool, Bool), TestParams) -> IO ()
testRemoteWithOpts opts test ((mobileCompression, desktopCompression), ps) = do
  trace <- (== Just "1") <$> lookupEnv "SIMPLEX_OWNER_TEST_TRACE"
  let ps' = if trace then ps {DBU.printOutput = True} else ps
  withNewTestChatCfgOpts ps' testCfg {remoteCompression = mobileCompression} opts "mobile" aliceProfile $ \mobile ->
    withNewTestChatCfgOpts ps' testCfg {remoteCompression = desktopCompression} opts "desktop" aliceDesktopProfile $ \desktop ->
      let compress = " (" <> (if mobileCompression && desktopCompression then "with" else "no") <> " compression)"
       in test compress mobile desktop

-- Keep terminal rendering from marking incoming messages read before the test
-- can check the authoritative read counters and explicitly issue the read.
testRemote3ManualRead :: HasCallStack => (String -> TestCC -> TestCC -> TestCC -> IO ()) -> ((Bool, Bool), TestParams) -> IO ()
testRemote3ManualRead test ps =
  testRemoteWithOpts testOpts {markRead = False}
    (\compress mobile desktop -> withNewTestChat (snd ps) "bob" bobProfile $ test compress mobile desktop)
    ps

testRemote3 :: HasCallStack => (String -> TestCC -> TestCC -> TestCC -> IO()) -> ((Bool, Bool), TestParams) -> IO ()
testRemote3 test ps =
  testRemote
    (\compress mobile desktop -> withNewTestChat (snd ps) "bob" bobProfile $ test compress mobile desktop)
    ps

testRemote4 :: HasCallStack => (String -> TestCC -> TestCC -> TestCC -> TestCC -> IO()) -> ((Bool, Bool), TestParams) -> IO ()
testRemote4 test ps =
  testRemote3
    (\compress mobile desktop bob -> withNewTestChat (snd ps) "cath" cathProfile $ test compress mobile desktop bob)
    ps

startRemote :: String -> TestCC -> TestCC -> IO ()
startRemote compress mobile desktop = do
  desktop ##> "/set device name My desktop"
  desktop <## "ok"
  mobile ##> "/set device name Mobile"
  mobile <## "ok"
  desktop ##> "/start remote host new"
  desktop <##. "new remote host started on "
  desktop <##. "other addresses: "
  desktop <## "Remote session invitation:"
  inv <- getTermLine desktop
  mobile ##> ("/connect remote ctrl " <> inv)
  mobile <## ("connecting new remote controller: My desktop, v" <> versionNumber)
  desktop <## "new remote host connecting"
  mobile <## "new remote controller connected"
  verifyRemoteCtrl mobile desktop
  mobile <## ("remote controller 1 session started with My desktop" <> compress)
  desktop <## "new remote host 1 added: Mobile"
  desktop <## ("remote host 1 connected" <> compress)

startRemoteStored :: String -> TestCC -> TestCC -> IO ()
startRemoteStored compress mobile desktop = do
  desktop ##> "/start remote host 1"
  desktop <##. "remote host 1 started on "
  desktop <##. "other addresses: "
  desktop <## "Remote session invitation:"
  inv <- getTermLine desktop
  mobile ##> ("/connect remote ctrl " <> inv)
  mobile <## ("connecting remote controller 1: My desktop, v" <> versionNumber)
  desktop <## "remote host 1 connecting"
  mobile <## "remote controller 1 connected"
  verifyRemoteCtrl mobile desktop
  mobile <## ("remote controller 1 session started with My desktop" <> compress)
  desktop <## ("remote host 1 connected" <> compress)

startRemoteDiscover :: String -> TestCC -> TestCC -> IO ()
startRemoteDiscover compress mobile desktop = do
  desktop ##> "/start remote host 1 multicast=on"
  desktop <##. "remote host 1 started on "
  desktop <##. "other addresses: "
  desktop <## "Remote session invitation:"
  _inv <- getTermLine desktop -- will use multicast instead
  mobile ##> "/find remote ctrl"
  mobile <## "ok"
  mobile <## ("remote controller 1 found: My desktop, v" <> versionNumber)
  mobile <## "use /confirm remote ctrl 1 to connect"
  mobile ##> "/confirm remote ctrl 1"

  mobile <## ("connecting remote controller 1: My desktop, v" <> versionNumber)
  desktop <## "remote host 1 connecting"
  mobile <## "remote controller 1 connected"
  verifyRemoteCtrl mobile desktop
  mobile <## ("remote controller 1 session started with My desktop" <> compress)
  desktop <## ("remote host 1 connected" <> compress)

verifyRemoteCtrl :: TestCC -> TestCC -> IO ()
verifyRemoteCtrl mobile desktop = do
  desktop <## "Compare session code with host:"
  sessId <- getTermLine desktop
  mobile <## "Compare session code with controller and use:"
  mobile <## ("/verify remote ctrl " <> sessId)
  mobile ##> ("/verify remote ctrl " <> sessId)

contactBob :: TestCC -> TestCC -> IO ()
contactBob desktop bob = do
  logNote "exchanging contacts"
  bob ##> "/c"
  inv' <- getInvitation bob
  desktop ##> ("/c " <> inv')
  desktop <## "confirmation sent!"
  concurrently_
    (desktop <## "bob (Bob): contact is connected")
    (bob <## "alice (Alice): contact is connected")

stopDesktop :: HasCallStack => TestCC -> TestCC -> IO ()
stopDesktop mobile desktop = do
  logWarn "stopping via desktop"
  desktop ##> "/stop remote host 1"
  desktop <## "ok"
  eventually 3 $ mobile <## "remote controller stopped"

stopMobile :: HasCallStack => TestCC -> TestCC -> IO ()
stopMobile mobile desktop = do
  logWarn "stopping via mobile"
  mobile ##> "/stop remote ctrl"
  mobile <## "ok"
  eventually 3 $ desktop <## "remote host 1 stopped"

-- | Run action with extended timeout
eventually :: Int -> IO a -> IO a
eventually retries action =
  tryAny action >>= \case
    -- TODO: only catch timeouts
    Left err | retries == 0 -> throwIO err
    Left _ -> eventually (retries - 1) action
    Right r -> pure r

newtype TestBody = TestBody (IORef [B.ByteString])

instance HTTP2BodyChunk TestBody where
  getBodyChunk (TestBody chunks) = atomicModifyIORef' chunks $ \case
    c : cs -> (cs, c)
    [] -> ([], "")
  getBodySize _ = Nothing

testRemoteCrypto :: IO RemoteCrypto
testRemoteCrypto = do
  drg <- C.newRandom
  (_, idPrivKey) <- atomically $ C.generateKeyPair drg
  (_, sessPrivKey) <- atomically $ C.generateKeyPair drg
  let (chainKey, _) = C.sbcInit "" ("secret" :: B.ByteString)
  chainKeys <- TSbChainKeys <$> newTVarIO chainKey <*> newTVarIO chainKey
  sndCounter <- newTVarIO 0
  rcvCounter <- newTVarIO 0
  skippedKeys <- TM.emptyIO
  pure RemoteCrypto {sessionCode = "", sndCounter, rcvCounter, chainKeys, skippedKeys, signatures = RSSign {idPrivKey, sessPrivKey}, compression = True}

parseDecryptChunks :: Int -> RemoteCrypto -> IORef [B.ByteString] -> IO (Either RemoteProtocolError ())
parseDecryptChunks maxSize rc chunks = do
  body <- getHTTP2Body (TestBody chunks) 0
  runExceptT . void $ parseDecryptHTTP2Body maxSize rc (TestBody chunks) body
