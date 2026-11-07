{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}

module Simplex.Chat.Remote where

import Control.Applicative ((<|>))
import Control.Concurrent.STM (retry)
import Control.Logger.Simple
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Class
import Control.Monad.Reader
import Crypto.Random (getRandomBytes)
import qualified Data.Aeson as J
import qualified Data.Aeson.Types as JT
import Data.ByteString (ByteString)
import qualified Data.ByteString.Base64.URL as B64U
import Data.ByteString.Builder (Builder)
import qualified Data.ByteString.Char8 as B
import Data.Functor (($>))
import Data.List.NonEmpty (NonEmpty, nonEmpty)
import qualified Data.List.NonEmpty as L
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1, encodeUtf8)
import Data.Word (Word16, Word32)
import qualified Network.HTTP.Types as N
import qualified Network.TLS as NT
import Network.HTTP2.Server (responseStreaming)
import qualified Paths_simplex_chat as SC
import Simplex.Chat.Controller
import Simplex.Chat.Files
import Simplex.Chat.Messages (chatNameStr)
import Simplex.Chat.Remote.AppVersion
import Simplex.Chat.Remote.Protocol
import Simplex.Chat.Remote.RevHTTP (attachHTTP2Server, attachRevHTTP2Client)
import Simplex.Chat.Remote.Transport
import Simplex.Chat.Remote.Types
import Simplex.Chat.Store.Files
import Simplex.Chat.Store.Remote
import Simplex.Chat.Store.Shared
import Simplex.Chat.Types
import Simplex.Chat.Util (encryptFile, liftIOEither)
import Simplex.FileTransfer.Description (FileDigest (..))
import Simplex.Messaging.Agent
import Simplex.Messaging.Agent.Protocol (AgentErrorType (RCP))
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.File (CryptoFile (..), CryptoFileArgs (..))
import qualified Simplex.Messaging.Crypto.File as CF
import Simplex.Messaging.Encoding.String (StrEncoding (..))
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport.Client (TransportHost (..))
import Simplex.Messaging.Transport (TLS (..), TransportPeer (..), closeConnection, tlsUniq)
import Simplex.Messaging.Transport.HTTP2.Client (HTTP2ClientError)
import qualified Simplex.Messaging.Transport.HTTP2.Client as H2
import Simplex.Messaging.Transport.HTTP2.Server (HTTP2Request (..))
import Simplex.Messaging.Util
import Simplex.RemoteControl.Client
import Simplex.RemoteControl.Invitation (RCInvitation (..), RCSignedInvitation (..), RCVerifiedInvitation (..), verifySignedInvitation)
import Simplex.RemoteControl.Types
import System.FilePath (takeDirectory, takeFileName, (</>))
import UnliftIO
import UnliftIO.Concurrent (forkIO)
import UnliftIO.Directory (canonicalizePath, copyFile, createDirectoryIfMissing, doesDirectoryExist, removeDirectoryRecursive, renameFile)

remoteFilesFolder :: String
remoteFilesFolder = "simplex_v1_files"

-- when acting as host
minRemoteCtrlVersion :: AppVersion
minRemoteCtrlVersion = AppVersion [7, 1, 0, 16]

-- when acting as controller
minRemoteHostVersion :: AppVersion
minRemoteHostVersion = AppVersion [7, 1, 0, 16]

currentAppVersion :: AppVersion
currentAppVersion = AppVersion SC.version

ctrlAppVersionRange :: AppVersionRange
ctrlAppVersionRange = mkAppVersionRange minRemoteHostVersion currentAppVersion

hostAppVersionRange :: AppVersionRange
hostAppVersionRange = mkAppVersionRange minRemoteCtrlVersion currentAppVersion

networkIOTimeout :: Int
networkIOTimeout = 15000000

discoveryTimeout :: Int
discoveryTimeout = 60000000

-- A retained listener is opt-in only for an explicitly selected IPv4 tailnet address.
-- IPv6 selection is not provided by simplexmq's interface enumeration yet.
tailnetAddress :: Maybe RCCtrlAddress -> Bool
tailnetAddress (Just RCCtrlAddress {address = THIPv4 (100, b, _, _)}) = b >= 64 && b <= 127
tailnetAddress _ = False

remoteHostPollWait, remoteHostPollTimeout :: Int
remoteHostPollWait = 5000000
remoteHostPollTimeout = 15000000

-- Phone-side liveness: a silent TCP blackhole must not retain the old session
-- indefinitely after the desktop has already timed out its event poll.
remoteCtrlIdleTimeout :: Int
remoteCtrlIdleTimeout = 30000000

remoteCtrlWatchdog :: Int -> TMVar () -> IO () -> IO ()
remoteCtrlWatchdog idleLimit activity closeTransport =
  timeout idleLimit (atomically $ takeTMVar activity) >>= \case
    Nothing -> closeTransport
    Just () -> remoteCtrlWatchdog idleLimit activity closeTransport

data RemoteHostDisconnect = RHTransportLost | RHControllerStopped

-- * Desktop side

getRemoteHostClient :: RemoteHostId -> CM RemoteHostClient
getRemoteHostClient rhId = do
  sessions <- asks remoteHostSessions
  liftIOEither . atomically $
    TM.lookup rhKey sessions >>= \case
      Just (_, RHSessionConnected {rhClient}) -> pure $ Right rhClient
      Just _ -> pure . Left $ ChatErrorRemoteHost rhKey RHEBadState
      Nothing -> pure . Left $ ChatErrorRemoteHost rhKey RHEMissing
  where
    rhKey = RHId rhId

withRemoteHostSession :: RHKey -> SessionSeq -> (RemoteHostSession -> Either ChatError (a, RemoteHostSession)) -> CM a
withRemoteHostSession rhKey sseq f = do
  sessions <- asks remoteHostSessions
  r <-
    atomically $
      TM.lookup rhKey sessions >>= \case
        Nothing -> pure . Left $ ChatErrorRemoteHost rhKey RHEMissing
        Just (stateSeq, state)
          | stateSeq /= sseq -> pure . Left $ ChatErrorRemoteHost rhKey RHEBadState
          | otherwise -> case f state of
              Right (r, newState) -> Right r <$ TM.insert rhKey (sseq, newState) sessions
              Left ce -> pure $ Left ce
  liftEither r

-- | Transition session state with a 'RHNew' ID to an assigned 'RemoteHostId'
setNewRemoteHostId :: SessionSeq -> RemoteHostId -> CM ()
setNewRemoteHostId sseq rhId = do
  sessions <- asks remoteHostSessions
  liftIOEither . atomically $ do
    TM.lookup RHNew sessions >>= \case
      Nothing -> err RHEMissing
      Just sess@(stateSeq, _)
        | stateSeq /= sseq -> err RHEBadState
        | otherwise -> do
            TM.delete RHNew sessions
            TM.insert (RHId rhId) sess sessions
            pure $ Right ()
  where
    err = pure . Left . ChatErrorRemoteHost RHNew

startRemoteHost :: Maybe (RemoteHostId, Bool) -> Maybe RCCtrlAddress -> Maybe Word16 -> CM (NonEmpty RCCtrlAddress, Maybe RemoteHostInfo, RCSignedInvitation)
startRemoteHost rh_ rcAddrPrefs_ port_ =
  startRemoteHostWith (localEncoding == PEKotlin && tailnetAddress rcAddrPrefs_) rh_ rcAddrPrefs_ port_

-- Kept separate so lifecycle tests can exercise the same transport on loopback.
startRemoteHostWith :: Bool -> Maybe (RemoteHostId, Bool) -> Maybe RCCtrlAddress -> Maybe Word16 -> CM (NonEmpty RCCtrlAddress, Maybe RemoteHostInfo, RCSignedInvitation)
startRemoteHostWith persistent = startRemoteHostWith_ persistent False

startRemoteHostWith_ :: Bool -> Bool -> Maybe (RemoteHostId, Bool) -> Maybe RCCtrlAddress -> Maybe Word16 -> CM (NonEmpty RCCtrlAddress, Maybe RemoteHostInfo, RCSignedInvitation)
startRemoteHostWith_ persistent restoring rh_ rcAddrPrefs_ port_ = do
  let rhKey = maybe RHNew (RHId . fst) rh_
  -- Reserve before re-reading authorization: stop can invalidate this owner,
  -- and an old startup snapshot must never reopen an already revoked listener.
  sseq <- startRemoteHostSession rhKey
  (multicast, remoteHost_, pairing) <- handleConnectError rhKey sseq $ case rh_ of
    Just (rhId, multicast) -> do
      rh@RemoteHost {hostPairing, recoveryEnabled} <- withStore $ \db -> getRemoteHost db rhId
      when (restoring && not recoveryEnabled) $ throwError $ ChatErrorRemoteHost rhKey RHEInactive
      pure (multicast, Just $ remoteHostInfo rh $ Just RHSStarting, hostPairing) -- get from the database, start multicast if requested
    Nothing -> lift . withAgent' $ \a -> (False,Nothing,) <$> rcNewHostPairing a
  ctrlAppInfo <- mkCtrlAppInfo
  (localAddrs, invitation, rchClient, vars) <- handleConnectError rhKey sseq $
    if persistent
      then do
        drg <- asks random
        liftError (chatErrorAgent . RCP) $ connectRCHostPersistent drg pairing (J.toJSON ctrlAppInfo) multicast rcAddrPrefs_ port_
      else withAgent $ \a -> rcConnectHost a pairing (J.toJSON ctrlAppInfo) multicast rcAddrPrefs_ port_
  let inv = decodeLatin1 $ strEncode invitation
  let rcAddr_ = L.head localAddrs <$ rcAddrPrefs_
  cmdOk <- newEmptyTMVarIO
  rhsWaitSession <- async $ do
    rhKeyVar <- newTVarIO rhKey
    activateOnConnect <- newTVarIO True
    atomically $ takeTMVar cmdOk
    handleHostError sseq rhKeyVar $ waitForHostSession remoteHost_ rhKey sseq rcAddr_ rhKeyVar activateOnConnect inv (knownHost pairing) restoring vars
  let rhs = RHPendingSession {rhKey, rchClient, rhsWaitSession, remoteHost_}
  (withRemoteHostSession rhKey sseq $ \case
    RHSessionStarting -> Right ((), RHSessionConnecting inv rhs)
    _ -> Left $ ChatErrorRemoteHost rhKey RHEBadState) `catchAllErrors` \e -> do
      liftIO $ cancelHostClient rchClient >> cancel rhsWaitSession
      throwError e
  (localAddrs, remoteHost_, invitation) <$ atomically (putTMVar cmdOk ())
  where
    mkCtrlAppInfo = do
      deviceName <- chatReadVar localDeviceName
      useCompression <- asks $ remoteCompression . config
      pure CtrlAppInfo {appVersionRange = ctrlAppVersionRange, deviceName, compression = BoolDef useCompression, restart = BoolDef persistent, reconnect = BoolDef persistent}
    parseHostAppInfo :: RCHostHello -> ExceptT RemoteHostError IO HostAppInfo
    parseHostAppInfo RCHostHello {app = hostAppInfo} = do
      hostInfo@HostAppInfo {appVersion, encoding} <-
        liftEitherWith (RHEProtocolError . RPEInvalidJSON) $ JT.parseEither J.parseJSON hostAppInfo
      unless (isAppCompatible appVersion ctrlAppVersionRange) $ throwError $ RHEBadVersion appVersion
      when (encoding == PEKotlin && localEncoding == PESwift) $ throwError $ RHEProtocolError RPEIncompatibleEncoding
      pure hostInfo
    handleConnectError :: RHKey -> SessionSeq -> CM a -> CM a
    handleConnectError rhKey sessSeq action =
      action `catchAllErrors` \err -> do
        logError $ "startRemoteHost.rcConnectHost crashed: " <> tshow err
        cancelRemoteHostSession (Just (sessSeq, RHSRConnectionFailed err)) rhKey
        throwError err
    handleHostError :: SessionSeq -> TVar RHKey -> CM () -> CM ()
    handleHostError sessSeq rhKeyVar action =
      action `catchAllErrors` \err -> do
        logError $ "startRemoteHost.waitForHostSession crashed: " <> tshow err
        readTVarIO rhKeyVar >>= cancelRemoteHostSession (Just (sessSeq, RHSRCrashed err))
    waitForHostSession :: Maybe RemoteHostInfo -> RHKey -> SessionSeq -> Maybe RCCtrlAddress -> TVar RHKey -> TVar Bool -> Text -> Maybe KnownHostPairing -> Bool -> RCStepTMVar (ByteString, TLS 'TServer, RCStepTMVar (RCHostSession, RCHostHello, RCHostPairing)) -> CM ()
    waitForHostSession remoteHost_ rhKey sseq rcAddr_ rhKeyVar activateOnConnect inv knownHost_ reconnecting vars = do
      result <- (Right <$> connectHost) `catchAllErrors` (pure . Left)
      case result of
        Right Nothing -> pure ()
        Right (Just (remoteHost', rhKey', knownHost')) ->
          waitForHostSession (Just remoteHost') rhKey' sseq rcAddr_ rhKeyVar activateOnConnect inv (Just knownHost') True vars
        Left err
          | reconnecting -> do
              logError $ "waitForHostSession reconnect failed: " <> tshow err
              recoverHostSession rhKey sseq inv
              toView CEvtRemoteHostStopped {remoteHostId_ = rhKeyId rhKey, rhsState = RHSConnecting inv, rhStopReason = RHSRDisconnected}
              waitForHostSession remoteHost_ rhKey sseq rcAddr_ rhKeyVar activateOnConnect inv knownHost_ True vars
          | otherwise -> throwError err
      where
        connectHost = do
          (sessId, tls, vars') <-
            if reconnecting
              then takeRCStep vars
              else timeoutThrow (ChatErrorRemoteHost rhKey RHETimeout) 60000000 $ takeRCStep vars
          connectTransport sessId tls vars'
        connectTransport sessId tls vars' = do
          let sessionCode = verificationCode sessId
          withRemoteHostSession rhKey sseq $ \case
            RHSessionConnecting _inv rhs' -> Right ((), RHSessionPendingConfirmation sessionCode tls rhs')
            _ -> Left $ ChatErrorRemoteHost rhKey RHEBadState
          let rh_' = (\rh -> (rh :: RemoteHostInfo) {sessionState = Just RHSPendingConfirmation {sessionCode}}) <$> remoteHost_
          toView CEvtRemoteHostSessionCode {remoteHost_ = rh_', sessionCode}
          (RCHostSession {sessionKeys}, rhHello, pairing') <- timeoutThrow (ChatErrorRemoteHost rhKey RHETimeout) 60000000 $ takeRCStep vars'
          knownHost' <- validateKnownHost pairing'
          hostInfo@HostAppInfo {deviceName = hostDeviceName, reconnect = BoolDef hostCanReconnect, restart = BoolDef hostCanRestart} <-
            liftError (ChatErrorRemoteHost rhKey) $ parseHostAppInfo rhHello
          pending <- withRemoteHostSession rhKey sseq $ \case
            RHSessionPendingConfirmation _ tls' rhs -> Right (rhs, RHSessionConfirmed tls' rhs)
            _ -> Left $ ChatErrorRemoteHost rhKey RHEBadState
          rhi@RemoteHostInfo {remoteHostId, storePath} <- upsertRemoteHost pairing' rh_' rcAddr_ hostDeviceName sseq RHSConfirmed {sessionCode}
          when (persistent && hostCanRestart) $ do
            -- The actual assigned port, including a random first-pair port, must
            -- survive restart. Never persist any invitation/session private key.
            RCSignedInvitation {invitation = RCInvitation {port = actualPort}} <-
              either (throwChatError . CEInternalError) pure $ strDecode $ encodeUtf8 inv
            withStore' $ \db -> enableRemoteHostRecovery db remoteHostId actualPort
          let rhKey' = RHId remoteHostId -- rhKey may be invalid after upserting on RHNew
          when (rhKey' /= rhKey) $ do
            atomically $ writeTVar rhKeyVar rhKey'
            toView $ CEvtNewRemoteHost rhi
          disconnected <- newEmptyTMVarIO
          let signalDisconnected reason = void $ tryPutTMVar disconnected reason
          httpClient <- liftError' (httpError remoteHostId) $ attachRevHTTP2Client (atomically $ signalDisconnected RHTransportLost) tls
          rhClient <- mkRemoteHostClient httpClient sessionKeys sessId storePath hostInfo
          pollAction <- async $ pollEvents remoteHostId rhClient signalDisconnected
          hostStopRequested <- newTVarIO False
          withRemoteHostSession rhKey' sseq $ \case
            RHSessionConfirmed {} -> Right ((), RHSessionConnected {rhPendingSession = pending, tls, rhClient, pollAction, hostStopRequested, canReconnect = hostCanReconnect && persistent, storePath})
            _ -> Left $ ChatErrorRemoteHost rhKey RHEBadState
          whenM (atomically $ swapTVar activateOnConnect False) $ chatWriteVar currentRemoteHost $ Just remoteHostId -- this is required for commands to be passed to remote host
          let RemoteHostClient {encryption = RemoteCrypto {compression}} = rhClient
              remoteHost = rhi {sessionState = Just RHSConnected {sessionCode}} :: RemoteHostInfo
          toView $ CEvtRemoteHostConnected {remoteHost, compression}
          atomically (takeTMVar disconnected) >>= \case
            RHControllerStopped -> do
              withStore' $ \db -> setRemoteHostRecovery db remoteHostId False
              Nothing <$ cancelRemoteHostSession (Just (sseq, RHSRDisconnected)) rhKey'
            RHTransportLost -> do
              readTVarIO hostStopRequested >>= \case
                True -> pure Nothing
                False | not (hostCanReconnect && persistent) -> Nothing <$ cancelRemoteHostSession (Just (sseq, RHSRDisconnected)) rhKey'
                False -> do
                  logDebug $ "HTTP2 client disconnected: " <> tshow (rhKey', sseq)
                  withRemoteHostSession rhKey' sseq $ \case
                    RHSessionConnected {} -> Right ((), RHSessionDisconnecting {invitation = inv, rhPendingSession = pending, tls, rhClient, pollAction, storePath})
                    _ -> Left $ ChatErrorRemoteHost rhKey' RHEBadState
                  toView CEvtRemoteHostStopped {remoteHostId_ = Just remoteHostId, rhsState = RHSConnecting inv, rhStopReason = RHSRDisconnected}
                  liftIO $ do
                    releaseHostSession (rchClient pending) sessId
                    closeRemoteHostTransport tls
                    concurrently_ (cancel pollAction) (forM_ (H2.action httpClient) cancel)
                  withRemoteHostSession rhKey' sseq $ \case
                    RHSessionDisconnecting {rhPendingSession} -> Right ((), RHSessionConnecting inv rhPendingSession)
                    _ -> Left $ ChatErrorRemoteHost rhKey' RHEBadState
                  pure $ Just (rhi, rhKey', knownHost')
        validateKnownHost pairing' =
          case knownHost pairing' of
            Nothing -> throwChatError $ CEInternalError "KnownHost is known after verification"
            Just knownHost'
              | maybe False ((hostFingerprint knownHost' /=) . hostFingerprint) knownHost_ ->
                  throwError $ ChatErrorRemoteHost rhKey $ RHEProtocolError $ PRERemoteControl RCEIdentity
              | otherwise -> pure knownHost'
    recoverHostSession :: RHKey -> SessionSeq -> Text -> CM ()
    recoverHostSession rhKey sseq inv = do
      tls_ <- withRemoteHostSession rhKey sseq $ \case
        session@RHSessionConnecting {} -> Right (Nothing, session)
        RHSessionPendingConfirmation _ tls rhs -> Right (Just (tls, rchClient rhs), RHSessionConnecting inv rhs)
        RHSessionConfirmed tls rhs -> Right (Just (tls, rchClient rhs), RHSessionConnecting inv rhs)
        _ -> Left $ ChatErrorRemoteHost rhKey RHEBadState
      forM_ tls_ $ \(tls, client) -> liftIO $ releaseHostSession client (tlsUniq tls) >> closeRemoteHostTransport tls
    upsertRemoteHost :: RCHostPairing -> Maybe RemoteHostInfo -> Maybe RCCtrlAddress -> Text -> SessionSeq -> RemoteHostSessionState -> CM RemoteHostInfo
    upsertRemoteHost pairing'@RCHostPairing {knownHost = kh_} rhi_ rcAddr_ hostDeviceName sseq state = do
      KnownHostPairing {hostDhPubKey = hostDhPubKey'} <- maybe (throwError . ChatError $ CEInternalError "KnownHost is known after verification") pure kh_
      case rhi_ of
        Nothing -> do
          storePath <- liftIO randomStorePath
          rh@RemoteHost {remoteHostId} <- withStore $ \db -> insertRemoteHost db hostDeviceName storePath rcAddr_ port_ pairing' >>= getRemoteHost db
          setNewRemoteHostId sseq remoteHostId
          pure $ remoteHostInfo rh $ Just state
        Just rhi@RemoteHostInfo {remoteHostId} -> do
          withStore' $ \db -> updateHostPairing db remoteHostId hostDeviceName hostDhPubKey' rcAddr_ port_
          pure (rhi :: RemoteHostInfo) {sessionState = Just state}
    rhKeyId = \case
      RHNew -> Nothing
      RHId rhId -> Just rhId
    pollEvents :: RemoteHostId -> RemoteHostClient -> (RemoteHostDisconnect -> STM ()) -> CM ()
    pollEvents rhId rhClient signalDisconnected = do
      oq <- asks outputQ
      recvLoop oq
      where
        receiveEvent = liftRH rhId $ remoteRecv rhClient (if persistent then remoteHostPollWait else 10000000)
        receiveWithTimeout = if persistent then timeoutThrow (ChatErrorRemoteHost (RHId rhId) RHETimeout) remoteHostPollTimeout receiveEvent else receiveEvent
        recvLoop oq =
          tryAllErrors receiveWithTimeout >>= \case
            Left e@(ChatErrorRemoteHost _ RHETimeout) -> do
              logDebug $ "Remote host poll stopped: " <> tshow e
              atomically $ signalDisconnected RHTransportLost
            Left e@(ChatErrorRemoteHost _ (RHEProtocolError RPEHTTP2 {})) -> do
              logDebug $ "Remote host poll stopped: " <> tshow e
              atomically $ signalDisconnected RHTransportLost
            Left e -> atomically (writeTBQueue oq (Just rhId, Left e)) >> recvLoop oq
            Right Nothing -> recvLoop oq
            Right (Just (Right CEvtRemoteCtrlStopped {})) -> atomically $ signalDisconnected RHControllerStopped
            Right (Just r) -> atomically (writeTBQueue oq (Just rhId, r)) >> recvLoop oq
    httpError :: RemoteHostId -> HTTP2ClientError -> ChatError
    httpError rhId = ChatErrorRemoteHost (RHId rhId) . RHEProtocolError . RPEHTTP2 . tshow

closeRemoteHostTransport :: TLS p -> IO ()
closeRemoteHostTransport TLS {tlsContext} = NT.contextClose tlsContext `catchAny` (logError . tshow)

startRemoteHostSession :: RHKey -> CM SessionSeq
startRemoteHostSession rhKey = do
  sessions <- asks remoteHostSessions
  nextSessionSeq <- asks remoteSessionSeq
  liftIOEither . atomically $
    TM.lookup rhKey sessions >>= \case
      Just _ -> pure . Left $ ChatErrorRemoteHost rhKey RHEBusy
      Nothing -> do
        sessionSeq <- stateTVar nextSessionSeq $ \s -> (s, s + 1)
        Right sessionSeq <$ TM.insert rhKey (sessionSeq, RHSessionStarting) sessions

closeRemoteHost :: RHKey -> CM ()
closeRemoteHost rhKey = do
  logNote $ "Closing remote host session for " <> tshow rhKey
  forM_ (case rhKey of RHId rhId -> Just rhId; RHNew -> Nothing) $ \rhId ->
    withStore' $ \db -> setRemoteHostRecovery db rhId False
  sessions <- asks remoteHostSessions
  client <- atomically $ TM.lookup rhKey sessions >>= \case
    Just (_, RHSessionConnected {hostStopRequested, rhClient, canReconnect}) -> (if canReconnect then Just rhClient else Nothing) <$ writeTVar hostStopRequested True
    _ -> pure Nothing
  forM_ client $ \c -> liftIO . void . timeout 2000000 . runExceptT $ remoteSend c "/_stop remote ctrl" 0
  cancelRemoteHostSession Nothing rhKey
  forM_ (case rhKey of RHId rhId -> Just rhId; RHNew -> Nothing) $ \rhId ->
    withStore' $ \db -> setRemoteHostRecovery db rhId False

cancelRemoteHostSession :: Maybe (SessionSeq, RemoteHostStopReason) -> RHKey -> CM ()
cancelRemoteHostSession handlerInfo_ rhKey = do
  sessions <- asks remoteHostSessions
  crh <- asks currentRemoteHost
  deregistered <-
    atomically $
      TM.lookup rhKey sessions >>= \case
        Nothing -> pure Nothing
        Just (sessSeq, _) | maybe False ((sessSeq /=) . fst) handlerInfo_ -> pure Nothing -- ignore cancel from a ghost session handler
        Just (_, rhs) -> do
          TM.delete rhKey sessions
          modifyTVar' crh $ \cur -> if (RHId <$> cur) == Just rhKey then Nothing else cur -- only wipe the closing RH
          pure $ Just rhs
  forM_ deregistered $ \session -> do
    liftIO $ cancelRemoteHost handlingError session `catchAny` (logError . tshow)
    forM_ (snd <$> handlerInfo_) $ \rhStopReason ->
      toView CEvtRemoteHostStopped {remoteHostId_, rhsState = rhsSessionState session, rhStopReason}
  where
    handlingError = isJust handlerInfo_
    remoteHostId_ = case rhKey of
      RHNew -> Nothing
      RHId rhId -> Just rhId

cancelRemoteHost :: Bool -> RemoteHostSession -> IO ()
cancelRemoteHost handlingError = \case
  RHSessionStarting -> pure ()
  RHSessionConnecting _inv rhs -> cancelPendingSession rhs
  RHSessionPendingConfirmation _sessCode tls rhs -> do
    cancelPendingSession rhs
    closeConnection tls
  RHSessionConfirmed tls rhs -> do
    cancelPendingSession rhs
    closeConnection tls
  RHSessionConnected {rhPendingSession, tls, rhClient = RemoteHostClient {httpClient}, pollAction} ->
    cancelConnected rhPendingSession tls httpClient pollAction
  RHSessionDisconnecting {rhPendingSession, tls, rhClient = RemoteHostClient {httpClient}, pollAction} ->
    cancelConnected rhPendingSession tls httpClient pollAction
  where
    cancelConnected rhs tls httpClient pollAction = do
      closeRemoteHostTransport tls
      concurrently_ (cancel pollAction) (forM_ (H2.action httpClient) cancel)
      cancelPendingSession rhs
    cancelPendingSession RHPendingSession {rchClient, rhsWaitSession} = do
      unless handlingError $ uninterruptibleCancel rhsWaitSession `catchAny` (logError . tshow)
      cancelHostClient rchClient `catchAny` (logError . tshow)

-- | Generate a random 16-char filepath without / in it by using base64url encoding.
randomStorePath :: IO FilePath
randomStorePath = B.unpack . B64U.encode <$> getRandomBytes 12

-- Each restored listener gets fresh signing/DH keys through connectRCHostPersistent.
-- Only previously negotiated direct links are eligible. A failed bind leaves the
-- authorization intact for an explicit later retry, and never falls back to LAN.
restoreRemoteHosts :: CM ()
restoreRemoteHosts = restoreRemoteHostsWith tailnetAddress

-- Tests supply loopback; production always requires the explicitly selected tailnet.
restoreRemoteHostsWith :: (Maybe RCCtrlAddress -> Bool) -> CM ()
restoreRemoteHostsWith allowedAddress = do
  hosts <- withStore' getRemoteHosts
  sessions <- chatReadVar remoteHostSessions
  forM_ hosts $ \RemoteHost {remoteHostId, recoveryEnabled, bindAddress_, bindPort_} ->
    when (localEncoding == PEKotlin && recoveryEnabled && allowedAddress bindAddress_ && isJust bindPort_ && M.notMember (RHId remoteHostId) sessions) $
      void (startRemoteHostWith_ True True (Just (remoteHostId, False)) bindAddress_ bindPort_)
        `catchAllErrors` (logError . ("restoreRemoteHosts: " <>) . tshow)

listRemoteHosts :: CM [RemoteHostInfo]
listRemoteHosts = do
  sessions <- chatReadVar remoteHostSessions
  map (rhInfo sessions) <$> withStore' getRemoteHosts
  where
    rhInfo sessions rh@RemoteHost {remoteHostId} =
      remoteHostInfo rh $ rhsSessionState . snd <$> M.lookup (RHId remoteHostId) sessions

switchRemoteHost :: Maybe RemoteHostId -> CM (Maybe RemoteHostInfo)
switchRemoteHost rhId_ = do
  rhi_ <- forM rhId_ $ \rhId -> do
    let rhKey = RHId rhId
    rh <- withStore (`getRemoteHost` rhId)
    sessions <- chatReadVar remoteHostSessions
    case M.lookup rhKey sessions of
      Just (_, RHSessionConnected {tls}) -> pure $ remoteHostInfo rh $ Just RHSConnected {sessionCode = tlsSessionCode tls}
      _ -> throwError $ ChatErrorRemoteHost rhKey RHEInactive
  rhi_ <$ chatWriteVar currentRemoteHost rhId_

remoteHostInfo :: RemoteHost -> Maybe RemoteHostSessionState -> RemoteHostInfo
remoteHostInfo RemoteHost {remoteHostId, storePath, hostDeviceName, bindAddress_, bindPort_} sessionState =
  RemoteHostInfo {remoteHostId, storePath, hostDeviceName, bindAddress_, bindPort_, sessionState}

deleteRemoteHost :: RemoteHostId -> CM ()
deleteRemoteHost rhId = do
  closeRemoteHost $ RHId rhId
  RemoteHost {storePath} <- withStore (`getRemoteHost` rhId)
  chatReadVar remoteHostsFolder >>= \case
    Just baseDir -> do
      let hostStore = baseDir </> storePath
      logInfo $ "removing host store at " <> tshow hostStore
      whenM (doesDirectoryExist hostStore) $ removeDirectoryRecursive hostStore
    Nothing -> logWarn "Local file store not available while deleting remote host"
  withStore' (`deleteRemoteHostRecord` rhId)

storeRemoteFile :: RemoteHostId -> Maybe Bool -> FilePath -> CM CryptoFile
storeRemoteFile rhId encrypted_ localPath = do
  c@RemoteHostClient {encryptHostFiles, storePath} <- getRemoteHostClient rhId
  let encrypt = fromMaybe encryptHostFiles encrypted_
  cf@CryptoFile {filePath} <- if encrypt then encryptLocalFile else pure $ CF.plain localPath
  filePath' <- liftRH rhId $ remoteStoreFile c filePath (takeFileName localPath)
  hf_ <- chatReadVar remoteHostsFolder
  forM_ hf_ $ \hf -> do
    let rhf = hf </> storePath </> remoteFilesFolder
        hPath = rhf </> takeFileName filePath'
    createDirectoryIfMissing True rhf
    (if encrypt then renameFile else copyFile) filePath hPath
  pure (cf :: CryptoFile) {filePath = filePath'}
  where
    encryptLocalFile :: CM CryptoFile
    encryptLocalFile = do
      tmpDir <- lift getChatTempDirectory
      createDirectoryIfMissing True tmpDir
      tmpFile <- liftIO $ tmpDir `uniqueCombine` takeFileName localPath
      cfArgs <- atomically . CF.randomArgs =<< asks random
      liftError (ChatError . CEFileWrite tmpFile) $ encryptFile localPath tmpFile cfArgs
      pure $ CryptoFile tmpFile $ Just cfArgs

getRemoteFile :: RemoteHostId -> RemoteFile -> CM ()
getRemoteFile rhId rf = do
  c@RemoteHostClient {storePath} <- getRemoteHostClient rhId
  dir <- lift $ (</> storePath </> remoteFilesFolder) <$> (maybe getDefaultFilesFolder pure =<< chatReadVar' remoteHostsFolder)
  createDirectoryIfMissing True dir
  liftRH rhId $ remoteGetFile c dir rf

processRemoteCommand :: RemoteHostId -> RemoteHostClient -> ChatCommand -> ByteString -> Int -> CM ChatResponse
processRemoteCommand remoteHostId c cmd s retryNum = case cmd of
  SendFile chatName f -> sendFile "/f" chatName f
  SendImage chatName f -> sendFile "/img" chatName f
  _ -> chatRemoteSend s
  where
    sendFile cmdName chatName (CryptoFile path cfArgs) = do
      -- don't encrypt in host if already encrypted locally
      CryptoFile path' cfArgs' <- storeRemoteFile remoteHostId (cfArgs $> False) path
      let f = CryptoFile path' (cfArgs <|> cfArgs') -- use local or host encryption
      chatRemoteSend $ B.unwords [cmdName, B.pack (chatNameStr chatName), cryptoFileStr f]
    cryptoFileStr CryptoFile {filePath, cryptoArgs} =
      maybe "" (\(CFArgs key nonce) -> "key=" <> strEncode key <> " nonce=" <> strEncode nonce <> " ") cryptoArgs
        <> encodeUtf8 (T.pack filePath)
    chatRemoteSend cmd' = either throwError pure =<< liftRH remoteHostId (remoteSend c cmd' retryNum)

liftRH :: RemoteHostId -> ExceptT RemoteProtocolError IO a -> CM a
liftRH rhId = liftError (ChatErrorRemoteHost (RHId rhId) . RHEProtocolError)

-- * Mobile side

-- ** QR/link

-- | Use provided OOB link as an annouce
connectRemoteCtrlURI :: RCSignedInvitation -> CM (Maybe RemoteCtrlInfo, CtrlAppInfo, SessionSeq)
connectRemoteCtrlURI signedInv = do
  verifiedInv <- maybe (throwError $ ChatErrorRemoteCtrl RCEBadInvitation) pure $ verifySignedInvitation signedInv
  sseq <- startRemoteCtrlSession
  (rc, info) <- connectRemoteCtrl verifiedInv sseq
  pure (rc, info, sseq)

-- Resolve only an enabled stored pairing. No invitation or ephemeral key is
-- restored. The dependency fetches the current invitation over mutual TLS and
-- checks both saved desktop identity pins before any session can be confirmed.
resumeRemoteCtrl :: RemoteCtrlId -> CM (Maybe RemoteCtrlInfo, CtrlAppInfo, SessionSeq)
resumeRemoteCtrl = resumeRemoteCtrlWith $ \pairing host port -> do
  drg <- asks random
  liftError (chatErrorAgent . RCP) $ requestRCCtrlInvitation drg pairing host port

-- Reserve the sequence BEFORE reading authorization or doing network IO. Stop
-- can then invalidate the owner while a successful invitation fetch is delayed.
-- The fetch boundary is injectable for deterministic stop/revocation tests.
resumeRemoteCtrlWith :: (RCCtrlPairing -> TransportHost -> Word16 -> CM RCVerifiedInvitation) -> RemoteCtrlId -> CM (Maybe RemoteCtrlInfo, CtrlAppInfo, SessionSeq)
resumeRemoteCtrlWith fetchInvitation rcId = do
  sseq <- startRemoteCtrlSession
  handleCtrlError sseq RCSRConnectionFailed "resumeRemoteCtrl" $ do
    RemoteCtrl {ctrlPairing, recoveryEndpoint} <- withStore (`getRemoteCtrl` rcId)
    endpoint@RCEndpoint {host, port} <- maybe (throwError $ ChatErrorRemoteCtrl RCEBadController) pure recoveryEndpoint
    inv <- fetchInvitation ctrlPairing host port
    updateRemoteCtrlSession sseq $ \case
      RCSessionStarting -> Right RCSessionStarting
      _ -> Left $ ChatErrorRemoteCtrl RCEBadState
    (rc_, info) <- connectRemoteCtrl inv sseq
    unless (maybe False (\RemoteCtrlInfo {remoteCtrlId = rid} -> rid == rcId) rc_) $ do
      abortRemoteCtrl sseq
      throwError $ ChatErrorRemoteCtrl RCEBadController
    updateRemoteCtrlSession sseq $ \session -> case session of
      RCSessionConnecting {} -> Right (session :: RemoteCtrlSession) {recoveryEndpoint = Just endpoint}
      RCSessionPendingConfirmation {} -> Right (session :: RemoteCtrlSession) {recoveryEndpoint = Just endpoint}
      _ -> Left $ ChatErrorRemoteCtrl RCEBadState
    pure (rc_, info, sseq)

-- Change routing metadata of an already enabled pairing, never its trust pins or
-- authorization. DNS resolution cannot substitute for mutual authentication.
setRemoteCtrlAddress :: RemoteCtrlId -> TransportHost -> CM ()
setRemoteCtrlAddress rcId host = do
  unless (validRecoveryHost host) $ throwError $ ChatErrorRemoteCtrl RCEBadInvitation
  enabled <- withStore $ \db -> do
    RemoteCtrl {recoveryEndpoint} <- getRemoteCtrl db rcId
    case recoveryEndpoint of
      Nothing -> pure False
      Just _ -> True <$ liftIO (updateRemoteCtrlAddress db rcId host)
  unless enabled $ throwError $ ChatErrorRemoteCtrl RCEBadController

validRecoveryHost :: TransportHost -> Bool
validRecoveryHost (THIPv4 (100, b, _, _)) = b >= 64 && b <= 127
validRecoveryHost (THDomainName name) =
  not (null name) && length name <= 253 && not (all (\c -> c >= '0' && c <= '9' || c == '.') name) && all validLabel (T.splitOn "." $ T.pack $ if last name == '.' then init name else name)
  where
    validLabel label = not (T.null label) && T.length label <= 63 && T.head label /= '-' && T.last label /= '-' && T.all (\c -> asciiAlphaNum c || c == '-') label
    asciiAlphaNum c = c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'
validRecoveryHost _ = False

-- ** Multicast

findKnownRemoteCtrl :: CM ()
findKnownRemoteCtrl = do
  knownCtrls <- withStore' getRemoteCtrls
  pairings <- case nonEmpty knownCtrls of
    Nothing -> throwError $ ChatErrorRemoteCtrl RCENoKnownControllers
    Just ne -> pure $ fmap (\RemoteCtrl {ctrlPairing} -> ctrlPairing) ne
  sseq <- startRemoteCtrlSession
  foundCtrl <- newEmptyTMVarIO
  cmdOk <- newEmptyTMVarIO
  action <- async $ handleCtrlError sseq RCSRDiscoveryFailed "findKnownRemoteCtrl.discover" $ do
    atomically $ takeTMVar cmdOk
    (RCCtrlPairing {ctrlFingerprint}, inv@(RCVerifiedInvitation RCInvitation {app})) <-
      timeoutThrow (ChatErrorRemoteCtrl RCETimeout) discoveryTimeout . withAgent $ \a -> rcDiscoverCtrl a pairings
    ctrlAppInfo_ <- (Just <$> parseCtrlAppInfo app) `catchAllErrors` const (pure Nothing)
    rc <-
      withStore' (`getRemoteCtrlByFingerprint` ctrlFingerprint) >>= \case
        Nothing -> throwChatError $ CEInternalError "connecting with a stored ctrl"
        Just rc -> pure rc
    atomically $ putTMVar foundCtrl (rc, inv)
    let compatible = isJust $ compatibleAppVersion hostAppVersionRange . appVersionRange =<< ctrlAppInfo_
    toView CEvtRemoteCtrlFound {remoteCtrl = remoteCtrlInfo rc (Just RCSSearching), ctrlAppInfo_, appVersion = currentAppVersion, compatible}
  updateRemoteCtrlSession sseq $ \case
    RCSessionStarting -> Right RCSessionSearching {action, foundCtrl}
    _ -> Left $ ChatErrorRemoteCtrl RCEBadState
  atomically $ putTMVar cmdOk ()

confirmRemoteCtrl :: RemoteCtrlId -> CM (RemoteCtrlInfo, CtrlAppInfo, SessionSeq)
confirmRemoteCtrl rcId = do
  session <- asks remoteCtrlSession
  (sseq, listener, found) <- liftIOEither $ atomically $ do
    readTVar session >>= \case
      Just (sseq, RCSessionSearching {action, foundCtrl}) -> do
        writeTVar session $ Just (sseq, RCSessionStarting) -- drop intermediate "Searching" state so connectRemoteCtrl can proceed
        pure $ Right (sseq, action, foundCtrl)
      _ -> pure . Left $ ChatErrorRemoteCtrl RCEBadState
  uninterruptibleCancel listener
  (RemoteCtrl {remoteCtrlId = foundRcId}, verifiedInv) <- atomically $ takeTMVar found
  unless (rcId == foundRcId) $ throwError $ ChatErrorRemoteCtrl RCEBadController
  connectRemoteCtrl verifiedInv sseq >>= \case
    (Nothing, _) -> throwChatError $ CEInternalError "connecting with a stored ctrl"
    (Just rci, appInfo) -> pure (rci, appInfo, sseq)

-- ** Common

startRemoteCtrlSession :: CM SessionSeq
startRemoteCtrlSession = do
  session <- asks remoteCtrlSession
  nextSessionSeq <- asks remoteSessionSeq
  liftIOEither . atomically $
    readTVar session >>= \case
      Just _ -> pure . Left $ ChatErrorRemoteCtrl RCEBusy
      Nothing -> do
        sseq <- stateTVar nextSessionSeq $ \s -> (s, s + 1)
        Right sseq <$ writeTVar session (Just (sseq, RCSessionStarting))

connectRemoteCtrl :: RCVerifiedInvitation -> SessionSeq -> CM (Maybe RemoteCtrlInfo, CtrlAppInfo)
connectRemoteCtrl verifiedInv@(RCVerifiedInvitation inv@RCInvitation {ca, app}) sseq = handleCtrlError sseq RCSRConnectionFailed "connectRemoteCtrl" $ do
  ctrlInfo <- parseCtrlAppInfo app
  v <- checkAppVersion ctrlInfo
  rc_ <- withStore' $ \db -> getRemoteCtrlByFingerprint db ca
  mapM_ (validateRemoteCtrl inv) rc_
  let CtrlAppInfo {reconnect = BoolDef canReconnect, restart = BoolDef canRestart} = ctrlInfo
      RCInvitation {host, port} = inv
      recoveryEndpoint = if canRestart && canReconnect && localEncoding == PEKotlin then Just RCEndpoint {host, port} else Nothing
  hostAppInfo <- getHostAppInfo v canReconnect
  (rcsClient, vars) <- timeoutThrow (ChatErrorRemoteCtrl RCETimeout) networkIOTimeout . withAgent $ \a ->
    rcConnectCtrl a verifiedInv (ctrlPairing <$> rc_) (J.toJSON hostAppInfo)
  cmdOk <- newEmptyTMVarIO
  rcsWaitSession <- async $ do
    atomically $ takeTMVar cmdOk
    handleCtrlError sseq RCSRConnectionFailed "waitForCtrlSession" $ waitForCtrlSession rc_ ctrlInfo rcsClient vars
  (updateRemoteCtrlSession sseq $ \case
    RCSessionStarting -> Right RCSessionConnecting {remoteCtrlId_ = remoteCtrlId' <$> rc_, rcsClient, rcsWaitSession, recoveryEndpoint, ctrlAppInfo = ctrlInfo}
    _ -> Left $ ChatErrorRemoteCtrl RCEBadState) `catchAllErrors` \e -> do
      liftIO $ cancelCtrlClient rcsClient >> cancel rcsWaitSession
      throwError e
  atomically $ putTMVar cmdOk ()
  pure ((`remoteCtrlInfo` Just RCSConnecting) <$> rc_, ctrlInfo)
  where
    validateRemoteCtrl RCInvitation {idkey} RemoteCtrl {ctrlPairing = RCCtrlPairing {idPubKey}} =
      unless (idkey == idPubKey) $ throwError $ ChatErrorRemoteCtrl $ RCEProtocolError $ PRERemoteControl RCEIdentity
    waitForCtrlSession :: Maybe RemoteCtrl -> CtrlAppInfo -> RCCtrlClient -> RCStepTMVar (ByteString, TLS 'TClient, RCStepTMVar (RCCtrlSession, RCCtrlPairing)) -> CM ()
    waitForCtrlSession rc_ ctrlAppInfo@CtrlAppInfo {deviceName = ctrlName} rcsClient vars = do
      (uniq, tls, rcsWaitConfirmation) <- timeoutThrow (ChatErrorRemoteCtrl RCETimeout) networkIOTimeout $ takeRCStep vars
      let sessionCode = verificationCode uniq
      updateRemoteCtrlSession sseq $ \case
        RCSessionConnecting {rcsWaitSession, recoveryEndpoint} ->
          let remoteCtrlId_ = remoteCtrlId' <$> rc_
           in Right RCSessionPendingConfirmation {remoteCtrlId_, ctrlDeviceName = ctrlName, rcsClient, tls, sessionCode, rcsWaitSession, rcsWaitConfirmation, recoveryEndpoint, ctrlAppInfo}
        _ -> Left $ ChatErrorRemoteCtrl RCEBadState
      toView CEvtRemoteCtrlSessionCode {remoteCtrl_ = (`remoteCtrlInfo` Just RCSPendingConfirmation {sessionCode}) <$> rc_, sessionCode, sessionSeq = sseq}
    checkAppVersion CtrlAppInfo {appVersionRange} =
      case compatibleAppVersion hostAppVersionRange appVersionRange of
        Just (AppCompatible v) -> pure v
        Nothing -> throwError $ ChatErrorRemoteCtrl $ RCEBadVersion $ maxVersion appVersionRange
    getHostAppInfo appVersion canReconnect = do
      hostDeviceName <- chatReadVar localDeviceName
      encryptFiles <- chatReadVar encryptLocalFiles
      useCompression <- asks $ remoteCompression . config
      pure HostAppInfo {appVersion, deviceName = hostDeviceName, encoding = localEncoding, encryptFiles, compression = BoolDef useCompression, restart = BoolDef (canReconnect && localEncoding == PEKotlin), reconnect = BoolDef (canReconnect && localEncoding == PEKotlin)}

parseCtrlAppInfo :: JT.Value -> CM CtrlAppInfo
parseCtrlAppInfo ctrlAppInfo = do
  liftEitherWith (const $ ChatErrorRemoteCtrl RCEBadInvitation) $ JT.parseEither J.parseJSON ctrlAppInfo

handleRemoteCommand :: (ByteString -> Int -> CM' (Either ChatError ChatResponse)) -> CM () -> RemoteCrypto -> TBQueue (Either ChatError ChatEvent) -> TMVar (Either ChatError ChatEvent) -> HTTP2Request -> CM' ()
handleRemoteCommand execCC stopAction encryption remoteOutputQ remoteStopEvent HTTP2Request {request, reqBody, sendResponse} = do
  logDebug "handleRemoteCommand"
  liftIO (tryAllErrors' parseRequest) >>= \case
    Right (_, _, RCSend {command = "/_stop remote ctrl"}) -> do
      reply $ RRChatResponse $ RRResult (CRCmdOk Nothing)
      void $ runExceptT stopAction
    Right (rfKN, getNext, rc) -> do
      chatReadVar' currentUser >>= \case
        Nothing -> replyError $ ChatError CENoActiveUser
        Just user -> processCommand user rfKN getNext rc `catchAllErrors'` replyError
    Left e -> reply $ RRProtocolError e
  where
    parseRequest :: ExceptT RemoteProtocolError IO (C.SbKeyNonce, GetChunk, RemoteCommand)
    parseRequest = do
      (rfKN, header, getNext) <- parseDecryptHTTP2Body maxCommandBodySize encryption request reqBody
      (rfKN,getNext,) <$> liftEitherWith RPEInvalidJSON (J.eitherDecodeStrict header)
    replyError = reply . RRChatResponse . RRError
    processCommand :: User -> C.SbKeyNonce -> GetChunk -> RemoteCommand -> CM ()
    processCommand user rfKN getNext = \case
      RCSend {command, retryNumber} -> lift $ handleSend execCC command retryNumber >>= reply
      RCRecv {wait = time} -> lift $ liftIO (handleRecv time remoteOutputQ remoteStopEvent) >>= reply
      RCStoreFile {fileName, fileSize, fileDigest} -> lift $ handleStoreFile rfKN fileName fileSize fileDigest getNext >>= reply
      RCGetFile {file} -> handleGetFile user file replyWith
    reply :: RemoteResponse -> CM' ()
    reply = (`replyWith` \_ _ -> pure ())
    replyWith :: Respond
    replyWith rr attach = do
      (corrId, cmdKN, sfKN) <- atomically $ getRemoteSndKeys encryption
      liftIO (tryAllErrors' . encryptEncodeHTTP2Body corrId cmdKN encryption $ J.encode rr) >>= \case
        Right resp -> liftIO . sendResponse . responseStreaming N.status200 [] $ \send flush -> do
          send resp
          attach sfKN send
          flush
        Left e -> eToView' $ ChatErrorRemoteCtrl $ RCEProtocolError e

takeRCStep :: RCStepTMVar a -> CM a
takeRCStep = liftError' (chatErrorAgent . RCP) . atomically . takeTMVar

type GetChunk = Int -> IO ByteString

type SendChunk = Builder -> IO ()

type Respond = RemoteResponse -> (C.SbKeyNonce -> SendChunk -> IO ()) -> CM' ()

liftRC :: ExceptT RemoteProtocolError IO a -> CM a
liftRC = liftError (ChatErrorRemoteCtrl . RCEProtocolError)

handleSend :: (ByteString -> Int -> CM' (Either ChatError ChatResponse)) -> Text -> Int -> CM' RemoteResponse
handleSend execCC command retryNum = do
  logDebug $ "Send: " <> tshow command
  -- execCC is execChatCommand CSRemoteCtrl, which checks allowRemoteCommand
  -- convert errors thrown in execCC into error responses to prevent aborting the protocol wrapper
  RRChatResponse . eitherToResult <$> execCC (encodeUtf8 command) retryNum

handleRecv :: Int -> TBQueue (Either ChatError ChatEvent) -> TMVar (Either ChatError ChatEvent) -> IO RemoteResponse
handleRecv time events remoteStopEvent = do
  logDebug $ "Recv: " <> tshow time
  RRChatEvent . fmap eitherToResult <$> (timeout time . atomically $ takeTMVar remoteStopEvent `orElse` readTBQueue events)

-- TODO this command could remember stored files and return IDs to allow removing files that are not needed.
-- Also, there should be some process removing unused files uploaded to remote host (possibly, all unused files).
handleStoreFile :: C.SbKeyNonce -> FilePath -> Word32 -> FileDigest -> GetChunk -> CM' RemoteResponse
handleStoreFile rfKN fileName fileSize fileDigest getChunk =
  either RRProtocolError RRFileStored <$> (chatReadVar' filesFolder >>= storeFile)
  where
    storeFile :: Maybe FilePath -> CM' (Either RemoteProtocolError FilePath)
    storeFile = \case
      Just ff -> takeFileName <$$> storeFileTo ff
      Nothing -> storeFileTo =<< getDefaultFilesFolder
    storeFileTo :: FilePath -> CM' (Either RemoteProtocolError FilePath)
    storeFileTo dir = liftIO . tryAllErrors' $ do
      unless (validRemoteFileName fileName) $ throwError $ RPEInvalidBody "invalid file name"
      filePath <- liftIO $ dir `uniqueCombine` fileName
      -- resolves symlinks, so it also catches a final component linking outside the folder
      canonPath <- liftIO $ canonicalizePath filePath
      inDir <- liftIO $ (takeDirectory canonPath ==) <$> canonicalizePath dir
      unless inDir $ throwError $ RPEInvalidBody "file path outside of files folder"
      receiveEncryptedFile rfKN getChunk fileSize fileDigest filePath
      pure filePath

-- The controller only ever sends a bare file name (see storeRemoteFile), so a path is a protocol violation.
validRemoteFileName :: FilePath -> Bool
validRemoteFileName fName = fName == takeFileName fName && fName `notElem` (["", ".", ".."] :: [FilePath])

handleGetFile :: User -> RemoteFile -> Respond -> CM ()
handleGetFile User {userId} RemoteFile {userId = commandUserId, fileId, sent, fileSource = cf'@CryptoFile {filePath}} reply = do
  logDebug $ "GetFile: " <> tshow filePath
  unless (userId == commandUserId) $ throwChatError $ CEDifferentActiveUser {commandUserId, activeUserId = userId}
  path <- maybe filePath (</> filePath) <$> chatReadVar filesFolder
  withStore $ \db -> do
    cf <- getLocalCryptoFile db commandUserId fileId sent
    unless (cf == cf') $ throwError $ SEFileNotFound fileId
  liftRC (tryAllErrors $ getFileInfo path) >>= \case
    Left e -> lift $ reply (RRProtocolError e) $ \_ _ -> pure ()
    Right (fileSize, fileDigest) ->
      lift . withFile path ReadMode $ \h -> do
        reply RRFile {fileSize, fileDigest} $ \sfKN send -> void . runExceptT $ do
          encFile <- prepareEncryptedFile sfKN (h, fileSize)
          liftIO $ sendEncryptedFile encFile send

listRemoteCtrls :: CM [RemoteCtrlInfo]
listRemoteCtrls = do
  session <- snd <$$> chatReadVar remoteCtrlSession
  let rcId = sessionRcId =<< session
      sessState = rcsSessionState <$> session
  map (rcInfo rcId sessState) <$> withStore' getRemoteCtrls
  where
    rcInfo :: Maybe RemoteCtrlId -> Maybe RemoteCtrlSessionState -> RemoteCtrl -> RemoteCtrlInfo
    rcInfo rcId sessState rc@RemoteCtrl {remoteCtrlId} =
      remoteCtrlInfo rc $ if rcId == Just remoteCtrlId then sessState else Nothing
    sessionRcId = \case
      RCSessionConnecting {remoteCtrlId_} -> remoteCtrlId_
      RCSessionPendingConfirmation {remoteCtrlId_} -> remoteCtrlId_
      RCSessionConnected {remoteCtrlId} -> Just remoteCtrlId
      _ -> Nothing

remoteCtrlInfo :: RemoteCtrl -> Maybe RemoteCtrlSessionState -> RemoteCtrlInfo
remoteCtrlInfo RemoteCtrl {remoteCtrlId, ctrlDeviceName, recoveryEndpoint} sessionState =
  RemoteCtrlInfo {remoteCtrlId, ctrlDeviceName, recoveryEnabled = isJust recoveryEndpoint, sessionState}

-- | Take a look at emoji of tlsunique, commit pairing, and start session server
verifyRemoteCtrlSession :: (ByteString -> Int -> CM' (Either ChatError ChatResponse)) -> Text -> CM ChatResponse
verifyRemoteCtrlSession execCC sessCode' = do
  (sseq, client, ctrlName, sessionCode, vars, recoveryEndpoint) <-
    chatReadVar remoteCtrlSession >>= \case
      Nothing -> throwError $ ChatErrorRemoteCtrl RCEInactive
      Just (sseq, RCSessionPendingConfirmation {rcsClient, ctrlDeviceName = ctrlName, sessionCode, rcsWaitConfirmation, recoveryEndpoint}) -> pure (sseq, rcsClient, ctrlName, sessionCode, rcsWaitConfirmation, recoveryEndpoint)
      _ -> throwError $ ChatErrorRemoteCtrl RCEBadState
  handleCtrlError sseq RCSRSetupFailed "verifyRemoteCtrlSession" $ do
    let verified = sameVerificationCode sessCode' sessionCode
    timeoutThrow (ChatErrorRemoteCtrl RCETimeout) networkIOTimeout . liftIO $ confirmCtrlSession client verified -- signal verification result before crashing
    unless verified $ throwError $ ChatErrorRemoteCtrl $ RCEProtocolError PRESessionCode
    (rcsSession@RCCtrlSession {tls, sessionKeys}, rcCtrlPairing) <- timeoutThrow (ChatErrorRemoteCtrl RCETimeout) networkIOTimeout $ takeRCStep vars
    rc@RemoteCtrl {remoteCtrlId} <- commitRemoteCtrlPairing sseq ctrlName rcCtrlPairing recoveryEndpoint
    remoteOutputQ <- asks (tbqSize . config) >>= newTBQueueIO
    remoteStopEvent <- newEmptyTMVarIO
    appInfo <- getRemoteCtrlAppInfo sseq
    encryption@RemoteCrypto {compression} <- mkCtrlRemoteCrypto sessionKeys (tlsUniq tls) appInfo
    let retainLink = maybe False (\CtrlAppInfo {reconnect = BoolDef enabled} -> enabled && localEncoding == PEKotlin) appInfo
    cc <- ask
    serverReady <- newEmptyTMVarIO
    activity <- newEmptyTMVarIO
    desktopStop <- newEmptyTMVarIO
    http2Server <- liftIO . async $ do
      atomically $ takeTMVar serverReady
      let server = attachHTTP2Server tls $ \req -> do
            atomically $ void $ tryPutTMVar activity ()
            -- Signal the connection owner after replying. Never cancel the TLS
            -- client from its own HTTP/2 request handler.
            handleRemoteCommand execCC (atomically $ void $ tryPutTMVar desktopStop ()) encryption remoteOutputQ remoteStopEvent req `runReaderT` cc
          stopped = atomically (readTMVar desktopStop) >> closeRemoteHostTransport tls
          idle = remoteCtrlWatchdog remoteCtrlIdleTimeout activity (closeRemoteHostTransport tls)
      race_ server $ if retainLink then race_ stopped idle else stopped
    (updateRemoteCtrlSession sseq $ \case
      RCSessionPendingConfirmation {ctrlAppInfo} -> Right RCSessionConnected {remoteCtrlId, rcsClient = client, rcsSession, tls, http2Server, remoteOutputQ, remoteStopEvent, recoveryEndpoint, ctrlAppInfo}
      _ -> Left $ ChatErrorRemoteCtrl RCEBadState) `catchAllErrors` \e -> liftIO (cancel http2Server) >> throwError e
    atomically $ putTMVar serverReady ()
    void . forkIO $ monitor sseq http2Server desktopStop
    let remoteCtrl = remoteCtrlInfo rc $ Just RCSConnected {sessionCode = tlsSessionCode tls}
    pure CRRemoteCtrlConnected {remoteCtrl, compression}
  where
    monitor :: SessionSeq -> Async () -> TMVar () -> CM ()
    monitor sseq server desktopStop = do
      res <- waitCatch server
      logInfo $ "HTTP2 server stopped: " <> tshow res
      intentional <- atomically $ not <$> isEmptyTMVar desktopStop
      when intentional $ do
        sessionVar <- asks remoteCtrlSession
        withStore' $ \db -> readTVarIO sessionVar >>= \case
          Just (currentSeq, RCSessionConnected {remoteCtrlId}) | currentSeq == sseq -> setRemoteCtrlRecovery db remoteCtrlId Nothing
          _ -> pure ()
      cancelActiveRemoteCtrl $ Just (sseq, if intentional then RCSRStopped else RCSRDisconnected)

-- Check ownership INSIDE the database transaction that commits trust and enable
-- state. A stop clears the owner before its final revocation transaction. If it
-- races this transaction, revocation therefore serializes after the commit; a
-- late verification after stop/unlink cannot insert or re-enable a pairing.
commitRemoteCtrlPairing :: SessionSeq -> Text -> RCCtrlPairing -> Maybe RCEndpoint -> CM RemoteCtrl
commitRemoteCtrlPairing sseq ctrlName rcCtrlPairing endpoint = do
  sessionVar <- asks remoteCtrlSession
  committed <- withStore $ \db -> do
    owns <- liftIO $ readTVarIO sessionVar >>= \case
      Just (currentSeq, RCSessionPendingConfirmation {}) -> pure $ currentSeq == sseq
      _ -> pure False
    if not owns then pure Nothing else do
      existing <- liftIO $ getRemoteCtrlByFingerprint db (ctrlFingerprint rcCtrlPairing)
      rc@RemoteCtrl {remoteCtrlId} <- case existing of
        Nothing -> insertRemoteCtrl db ctrlName rcCtrlPairing >>= getRemoteCtrl db
        Just rc@RemoteCtrl {ctrlPairing} -> do
          let dhPrivKey' = dhPrivKey rcCtrlPairing
          liftIO $ updateRemoteCtrl db rc ctrlName dhPrivKey'
          pure rc {ctrlDeviceName = ctrlName, ctrlPairing = ctrlPairing {dhPrivKey = dhPrivKey'}}
      liftIO $ disableRemoteCtrlRecovery db >> setRemoteCtrlRecovery db remoteCtrlId endpoint
      pure $ Just (rc :: RemoteCtrl) {recoveryEndpoint = endpoint}
  maybe (throwError $ ChatErrorRemoteCtrl RCEInactive) pure committed

stopRemoteCtrl :: CM ()
stopRemoteCtrl = do
  -- Revoke even if the Android retry owner is between connection attempts.
  withStore' disableRemoteCtrlRecovery
  var <- asks remoteCtrlSession
  -- Claim the closing session before signalling the desktop. The monitor must
  -- neither report this explicit stop as loss nor cancel a replacement session.
  closing <- atomically $ readTVar var >>= \case
    Just (sseq, session@RCSessionConnected {ctrlAppInfo = CtrlAppInfo {reconnect = BoolDef True}}) ->
      Just (sseq, session) <$ writeTVar var Nothing
    _ -> pure Nothing
  case closing of
    Just (sseq, session@RCSessionConnected {remoteStopEvent, http2Server}) -> do
      let event = Right CEvtRemoteCtrlStopped {rcsState = rcsSessionState session, rcStopReason = RCSRStopped, sessionSeq = sseq}
      atomically $ void $ tryPutTMVar remoteStopEvent event
      -- The desktop consumes this event and closes its retained listener first.
      void $ timeout 2000000 $ waitCatch http2Server
      liftIO $ cancelRemoteCtrl False session
    _ -> cancelActiveRemoteCtrl Nothing
  withStore' disableRemoteCtrlRecovery

-- Authentication/protocol failures terminate persisted automatic authorization.
-- Network exceptions and timeouts retain it so ordinary outages remain retryable.
terminalRecoveryError :: ChatError -> Bool
terminalRecoveryError = \case
  ChatErrorAgent {agentError = RCP rcError} -> case rcError of
    RCEException {} -> False
    RCENotDiscovered -> False
    RCENoLocalAddress -> False
    _ -> True
  ChatErrorRemoteCtrl RCETimeout -> False
  ChatErrorRemoteCtrl RCEBusy -> False
  ChatErrorRemoteCtrl _ -> True
  _ -> False

handleCtrlError :: SessionSeq -> (ChatError -> RemoteCtrlStopReason) -> Text -> CM a -> CM a
handleCtrlError sseq mkReason name action =
  action `catchAllErrors` \e -> do
    sessionVar <- asks remoteCtrlSession
    when (terminalRecoveryError e) $ withStore' $ \db -> do
      active <- readTVarIO sessionVar
      when (maybe False ((== sseq) . fst) active) $ disableRemoteCtrlRecovery db
    logError $ name <> " remote ctrl error: " <> tshow e
    cancelActiveRemoteCtrl $ Just (sseq, mkReason e)
    throwError e

-- | Stop session controller, unless session update key is present but stale
cancelActiveRemoteCtrl :: Maybe (SessionSeq, RemoteCtrlStopReason) -> CM ()
cancelActiveRemoteCtrl handlerInfo = cancelActiveRemoteCtrl_ True (isJust handlerInfo) handlerInfo

abortRemoteCtrl :: SessionSeq -> CM ()
abortRemoteCtrl sseq = cancelActiveRemoteCtrl_ False False $ Just (sseq, RCSRStopped)

cancelActiveRemoteCtrl_ :: Bool -> Bool -> Maybe (SessionSeq, RemoteCtrlStopReason) -> CM ()
cancelActiveRemoteCtrl_ emitEvent handlingError handlerInfo_ = handleAny (logError . tshow) $ do
  var <- asks remoteCtrlSession
  session_ <-
    atomically $
      readTVar var >>= \case
        Nothing -> pure Nothing
        Just (oldSeq, _) | (maybe False ((oldSeq /=) . fst) handlerInfo_) -> pure Nothing
        Just (_, s) -> Just s <$ writeTVar var Nothing
  forM_ session_ $ \session -> do
    liftIO $ cancelRemoteCtrl handlingError session
    when emitEvent $ forM_ (snd <$> handlerInfo_) $ \rcStopReason ->
      toView CEvtRemoteCtrlStopped {rcsState = rcsSessionState session, rcStopReason, sessionSeq = maybe 0 fst handlerInfo_}

cancelRemoteCtrl :: Bool -> RemoteCtrlSession -> IO ()
cancelRemoteCtrl handlingError = \case
  RCSessionStarting -> pure ()
  RCSessionSearching {action} ->
    unless handlingError $ uninterruptibleCancel action
  RCSessionConnecting {rcsClient, rcsWaitSession} -> do
    unless handlingError $ uninterruptibleCancel rcsWaitSession
    cancelCtrlClient rcsClient
  RCSessionPendingConfirmation {rcsClient, tls, rcsWaitSession} -> do
    unless handlingError $ uninterruptibleCancel rcsWaitSession
    cancelCtrlClient rcsClient
    closeConnection tls
  RCSessionConnected {rcsClient, tls, http2Server} -> do
    -- Unblock HTTP/2 network IO before joining its workers, including during
    -- controller shutdown with file streams or event polls still in flight.
    closeRemoteHostTransport tls
    unless handlingError $ uninterruptibleCancel http2Server
    cancelCtrlClient rcsClient

deleteRemoteCtrl :: RemoteCtrlId -> CM ()
deleteRemoteCtrl rcId = do
  checkNoRemoteCtrlSession
  -- TODO check it exists
  withStore' (`deleteRemoteCtrlRecord` rcId)

checkNoRemoteCtrlSession :: CM ()
checkNoRemoteCtrlSession =
  chatReadVar remoteCtrlSession >>= maybe (pure ()) (\_ -> throwError $ ChatErrorRemoteCtrl RCEBusy)

-- | Transition controller to a new state, unless session update key is stale
updateRemoteCtrlSession :: SessionSeq -> (RemoteCtrlSession -> Either ChatError RemoteCtrlSession) -> CM ()
updateRemoteCtrlSession sseq state = do
  session <- asks remoteCtrlSession
  r <- atomically $ do
    readTVar session >>= \case
      Nothing -> pure . Left $ ChatErrorRemoteCtrl RCEInactive
      Just (oldSeq, st)
        | oldSeq /= sseq -> pure . Left $ ChatErrorRemoteCtrl RCEBadState
        | otherwise -> case state st of
            Left ce -> pure $ Left ce
            Right st' -> Right () <$ writeTVar session (Just (sseq, st'))
  liftEither r

getRemoteCtrlAppInfo :: SessionSeq -> CM (Maybe CtrlAppInfo)
getRemoteCtrlAppInfo sseq = chatReadVar remoteCtrlSession $>>= pure . appInfo
  where
    appInfo (currSseq, sess)
      | sseq == currSseq = case sess of
          RCSessionStarting -> Nothing
          RCSessionSearching {} -> Nothing
          RCSessionConnecting {ctrlAppInfo} -> Just ctrlAppInfo
          RCSessionPendingConfirmation {ctrlAppInfo} -> Just ctrlAppInfo
          RCSessionConnected {ctrlAppInfo} -> Just ctrlAppInfo
      | otherwise = Nothing

utf8String :: [Char] -> ByteString
utf8String = encodeUtf8 . T.pack
{-# INLINE utf8String #-}
