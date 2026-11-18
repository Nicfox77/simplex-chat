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
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1, encodeUtf8)
import Data.Word (Word16, Word32)
import qualified Network.HTTP.Types as N
import Network.HTTP2.Server (responseStreaming)
import qualified Network.TLS as NT
import qualified Paths_simplex_chat as SC
import Simplex.Chat.Controller
import Simplex.Chat.Controller.Concurrent
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
import qualified Simplex.Messaging.Agent.Store.DB as DB
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.File (CryptoFile (..), CryptoFileArgs (..))
import qualified Simplex.Messaging.Crypto.File as CF
import Simplex.Messaging.Encoding.String (StrEncoding (..))
import qualified Simplex.Messaging.TMap as TM
import Simplex.Messaging.Transport (TLS (..), TransportPeer (..), closeConnection, tlsUniq)
import Simplex.Messaging.Transport.Client (TransportHost (..))
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
import UnliftIO.Directory (canonicalizePath, copyFile, createDirectoryIfMissing, doesDirectoryExist, removeDirectoryRecursive, removeFile, renameFile)

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

data RemoteHostDisconnect = RHTransportLost | RHControllerStopped | RHReceiveFailed ChatError

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
  (localAddrs, invitation, rchClient, vars) <-
    handleConnectError rhKey sseq $
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
  ( withRemoteHostSession rhKey sseq $ \case
      RHSessionStarting -> Right ((), RHSessionConnecting inv rhs)
      _ -> Left $ ChatErrorRemoteHost rhKey RHEBadState
    )
    `catchAllErrors` \e -> do
      liftIO $ cancelHostClient rchClient >> cancel rhsWaitSession
      throwError e
  (localAddrs, remoteHost_, invitation) <$ atomically (putTMVar cmdOk ())
  where
    mkCtrlAppInfo = do
      deviceName <- chatReadVar localDeviceName
      useCompression <- asks $ remoteCompression . config
      uiProtocol <- uiProtocolVersion
      pure CtrlAppInfo {uiProtocol, appVersionRange = ctrlAppVersionRange, deviceName, compression = BoolDef useCompression, restart = BoolDef persistent, reconnect = BoolDef persistent}
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
          expectedUI <- uiProtocolVersion
          let HostAppInfo {uiProtocol} = hostInfo
          unless (uiProtocol == expectedUI) $ throwError $ ChatErrorRemoteHost rhKey $ RHEProtocolError $ RPEInvalidBody "simultaneous UI protocol mismatch; update both devices"
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
          startPoll <- newEmptyTMVarIO
          pollAction <- async $ atomically (readTMVar startPoll) >> pollEvents remoteHostId rhClient signalDisconnected
          hostStopRequested <- newTVarIO False
          withRemoteHostSession rhKey' sseq $ \case
            RHSessionConfirmed {} -> Right ((), RHSessionConnected {rhPendingSession = pending, tls, rhClient, pollAction, hostStopRequested, canReconnect = hostCanReconnect && persistent, storePath})
            _ -> Left $ ChatErrorRemoteHost rhKey RHEBadState
          whenM (atomically $ swapTVar activateOnConnect False) $ chatWriteVar currentRemoteHost $ Just remoteHostId -- this is required for commands to be passed to remote host
          let RemoteHostClient {encryption = RemoteCrypto {compression}} = rhClient
              remoteHost = rhi {sessionState = Just RHSConnected {sessionCode}} :: RemoteHostInfo
          toView $ CEvtRemoteHostConnected {remoteHost, compression}
          atomically $ putTMVar startPoll ()
          disconnectReason <- atomically $ takeTMVar disconnected <* invalidateRemoteHostClient rhClient
          case disconnectReason of
            RHReceiveFailed err -> Nothing <$ cancelRemoteHostSession (Just (sseq, RHSRCrashed err)) rhKey'
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
      cc <- ask
      let receiveEvent = liftRH rhId $ remoteRecv rhClient (if persistent then remoteHostPollWait else 10000000)
          receiveWithTimeout = if persistent then timeoutThrow (ChatErrorRemoteHost (RHId rhId) RHETimeout) remoteHostPollTimeout receiveEvent else receiveEvent
          loop =
            tryAllErrors receiveWithTimeout >>= \case
              Left e -> do
                logDebug $ "Remote host poll stopped: " <> tshow e
                -- Every receive failure ends this poller once. Only outages and
                -- revoked buffers may recover through a fresh authenticated session.
                atomically $ signalDisconnected $ case e of
                  ChatErrorRemoteHost _ RHETimeout -> RHTransportLost
                  ChatErrorRemoteHost _ (RHEProtocolError RPEHTTP2 {}) -> RHTransportLost
                  ChatErrorRemoteHost _ (RHEProtocolError RPESessionClosed) -> RHTransportLost
                  _ -> RHReceiveFailed e
              Right Nothing -> loop
              Right (Just (Right CEvtRemoteCtrlStopped {})) -> atomically $ signalDisconnected RHControllerStopped
              Right (Just r) -> atomically (writeUIOutput cc (Just rhId, r)) >> loop
      loop
    httpError :: RemoteHostId -> HTTP2ClientError -> ChatError
    httpError rhId = ChatErrorRemoteHost (RHId rhId) . RHEProtocolError . RPEHTTP2 . tshow

-- Sequence-bound terminal cleanup used by callers outside the retained owner.
remoteHostPollFailed :: RemoteHostId -> SessionSeq -> ChatError -> CM ()
remoteHostPollFailed rhId sseq err =
  cancelRemoteHostSession (Just (sseq, reason)) (RHId rhId)
  where
    reason = case err of
      ChatErrorRemoteHost _ (RHEProtocolError RPESessionClosed) -> RHSRDisconnected
      _ -> RHSRCrashed err

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
        sessionSeq <- stateTVar' nextSessionSeq $ \s -> (s, s + 1)
        Right sessionSeq <$ TM.insert rhKey (sessionSeq, RHSessionStarting) sessions

closeRemoteHost :: RHKey -> CM ()
closeRemoteHost rhKey = do
  logNote $ "Closing remote host session for " <> tshow rhKey
  forM_ (case rhKey of RHId rhId -> Just rhId; RHNew -> Nothing) $ \rhId ->
    withStore' $ \db -> setRemoteHostRecovery db rhId False
  sessions <- asks remoteHostSessions
  client <-
    atomically $
      TM.lookup rhKey sessions >>= \case
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
          case rhs of
            RHSessionConnected {rhClient} -> invalidateRemoteHostClient rhClient
            RHSessionDisconnecting {rhClient} -> invalidateRemoteHostClient rhClient
            _ -> pure ()
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
  RHSessionConnected {rhPendingSession, tls, rhClient, pollAction} ->
    cancelConnected rhPendingSession tls rhClient pollAction
  RHSessionDisconnecting {rhPendingSession, tls, rhClient, pollAction} ->
    cancelConnected rhPendingSession tls rhClient pollAction
  where
    cancelConnected rhs tls rhClient@RemoteHostClient {httpClient} pollAction = do
      atomically $ invalidateRemoteHostClient rhClient
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
  sseq <- startRemoteCtrlSessionFor (Just rcId)
  handleCtrlError sseq RCSRConnectionFailed "resumeRemoteCtrl" $ do
    RemoteCtrl {ctrlPairing, recoveryEndpoint} <- withStore (`getRemoteCtrl` rcId)
    endpoint@RCEndpoint {host, port} <- maybe (throwError $ ChatErrorRemoteCtrl RCEBadController) pure recoveryEndpoint
    inv <- fetchInvitation ctrlPairing host port
    updateRemoteCtrlSession sseq $ \case
      RCSessionStarting {} -> Right (RCSessionStarting (Just rcId))
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

findKnownRemoteCtrl :: CM SessionSeq
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
    toView CEvtRemoteCtrlFound {remoteCtrl = remoteCtrlInfo rc (Just RCSSearching), ctrlAppInfo_, appVersion = currentAppVersion, compatible, sessionSeq = sseq}
  updateRemoteCtrlSession sseq $ \case
    RCSessionStarting {} -> Right RCSessionSearching {action, foundCtrl}
    _ -> Left $ ChatErrorRemoteCtrl RCEBadState
  atomically $ putTMVar cmdOk ()
  pure sseq

confirmRemoteCtrl :: RemoteCtrlId -> CM (RemoteCtrlInfo, CtrlAppInfo, SessionSeq)
confirmRemoteCtrl rcId = do
  sessions <- asks remoteCtrlSessions
  (sseq, listener, found) <- liftIOEither $ atomically $ do
    allSessions <- readTVar sessions
    case [(seqNo, action, foundCtrl) | (seqNo, RCSessionSearching {action, foundCtrl}) <- M.toList allSessions] of
      [(seqNo, _, _)]
        | any ((== Just rcId) . remoteCtrlSessionId) (M.elems $ M.delete seqNo allSessions) ->
            pure . Left $ ChatErrorRemoteCtrl RCEBusy
      [(seqNo, action, foundCtrl)] -> do
        writeTVar sessions $ M.insert seqNo (RCSessionStarting (Just rcId)) allSessions
        pure $ Right (seqNo, action, foundCtrl)
      _ -> pure . Left $ ChatErrorRemoteCtrl RCEBadState
  uninterruptibleCancel listener
  (RemoteCtrl {remoteCtrlId = foundRcId}, verifiedInv) <- atomically $ takeTMVar found
  unless (rcId == foundRcId) $ do
    abortRemoteCtrl sseq
    throwError $ ChatErrorRemoteCtrl RCEBadController
  connectRemoteCtrl verifiedInv sseq >>= \case
    (Nothing, _) -> throwChatError $ CEInternalError "connecting with a stored ctrl"
    (Just rci, appInfo) -> pure (rci, appInfo, sseq)

-- ** Common

remoteCtrlSessionId :: RemoteCtrlSession -> Maybe RemoteCtrlId
remoteCtrlSessionId = \case
  RCSessionStarting {remoteCtrlId_} -> remoteCtrlId_
  RCSessionConnecting {remoteCtrlId_} -> remoteCtrlId_
  RCSessionPendingConfirmation {remoteCtrlId_} -> remoteCtrlId_
  RCSessionConnected {remoteCtrlId} -> Just remoteCtrlId
  _ -> Nothing

startRemoteCtrlSession :: CM SessionSeq
startRemoteCtrlSession = startRemoteCtrlSessionFor Nothing

startRemoteCtrlSessionFor :: Maybe RemoteCtrlId -> CM SessionSeq
startRemoteCtrlSessionFor rcId = do
  sessions <- asks remoteCtrlSessions
  enabled <- chatReadVar simultaneousUI
  nextSessionSeq <- asks remoteSessionSeq
  liftIOEither . atomically $ do
    current <- readTVar sessions
    let busy =
          (not enabled && not (M.null current))
            || M.size current >= 8
            || any ((== rcId) . remoteCtrlSessionId) (M.elems current)
    if busy
      then pure . Left $ ChatErrorRemoteCtrl RCEBusy
      else do
        sseq <- stateTVar' nextSessionSeq $ \s -> (s, s + 1)
        Right sseq <$ writeTVar sessions (M.insert sseq (RCSessionStarting rcId) current)

reserveRemoteCtrl :: SessionSeq -> Maybe RemoteCtrlId -> CM ()
reserveRemoteCtrl sseq rcId = do
  sessions <- asks remoteCtrlSessions
  liftIOEither . atomically $ do
    current <- readTVar sessions
    case M.lookup sseq current of
      Just RCSessionStarting {remoteCtrlId_ = expected} ->
        if isJust expected && expected /= rcId
          then pure . Left $ ChatErrorRemoteCtrl RCEBadController
          else
            if maybe False (\rid -> any ((== Just rid) . remoteCtrlSessionId . snd) $ M.toList $ M.delete sseq current) rcId
              then pure . Left $ ChatErrorRemoteCtrl RCEBusy
              else Right () <$ writeTVar sessions (M.insert sseq (RCSessionStarting rcId) current)
      _ -> pure . Left $ ChatErrorRemoteCtrl RCEInactive

connectRemoteCtrl :: RCVerifiedInvitation -> SessionSeq -> CM (Maybe RemoteCtrlInfo, CtrlAppInfo)
connectRemoteCtrl verifiedInv@(RCVerifiedInvitation inv@RCInvitation {ca, app}) sseq = handleCtrlError sseq RCSRConnectionFailed "connectRemoteCtrl" $ do
  ctrlInfo <- parseCtrlAppInfo app
  expectedUI <- uiProtocolVersion
  let CtrlAppInfo {uiProtocol} = ctrlInfo
  unless (uiProtocol == expectedUI) $ throwError $ ChatErrorRemoteCtrl $ RCEProtocolError $ RPEInvalidBody "simultaneous UI protocol mismatch; update both devices"
  v <- checkAppVersion ctrlInfo
  rc_ <- withStore' $ \db -> getRemoteCtrlByFingerprint db ca
  mapM_ (validateRemoteCtrl inv) rc_
  reserveRemoteCtrl sseq (remoteCtrlId' <$> rc_)
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
  ( updateRemoteCtrlSession sseq $ \case
      RCSessionStarting {} -> Right RCSessionConnecting {remoteCtrlId_ = remoteCtrlId' <$> rc_, remoteCtrlFingerprint = ca, rcsClient, rcsWaitSession, recoveryEndpoint, ctrlAppInfo = ctrlInfo}
      _ -> Left $ ChatErrorRemoteCtrl RCEBadState
    )
    `catchAllErrors` \e -> do
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
        RCSessionConnecting {rcsWaitSession, recoveryEndpoint, remoteCtrlFingerprint} ->
          let remoteCtrlId_ = remoteCtrlId' <$> rc_
           in Right RCSessionPendingConfirmation {remoteCtrlId_, remoteCtrlFingerprint, ctrlDeviceName = ctrlName, rcsClient, tls, sessionCode, rcsWaitSession, rcsWaitConfirmation, recoveryEndpoint, ctrlAppInfo}
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
      uiProtocol <- uiProtocolVersion
      pure HostAppInfo {uiProtocol, appVersion, deviceName = hostDeviceName, encoding = localEncoding, encryptFiles, compression = BoolDef useCompression, restart = BoolDef (canReconnect && localEncoding == PEKotlin), reconnect = BoolDef (canReconnect && localEncoding == PEKotlin)}

uiProtocolVersion :: CM (Maybe Int)
uiProtocolVersion = do
  enabled <- chatReadVar simultaneousUI
  pure $ if enabled then Just 2 else Nothing

parseCtrlAppInfo :: JT.Value -> CM CtrlAppInfo
parseCtrlAppInfo ctrlAppInfo = do
  liftEitherWith (const $ ChatErrorRemoteCtrl RCEBadInvitation) $ JT.parseEither J.parseJSON ctrlAppInfo

handleRemoteCommand :: (ByteString -> Int -> CM' (Either ChatError ChatResponse)) -> CM () -> RemoteCrypto -> EventBuffer (Either ChatError ChatEvent) -> TMVar (Either ChatError ChatEvent) -> HTTP2Request -> CM' ()
handleRemoteCommand execCC stopAction encryption remoteOutputQ remoteStopEvent HTTP2Request {request, reqBody, sendResponse} = do
  logDebug "handleRemoteCommand"
  liftIO (tryAllErrors' parseRequest) >>= \case
    Right (_, _, RCSend {command = "/_stop remote ctrl"}) -> do
      reply $ RRChatResponse $ RRResult (CRCmdOk Nothing)
      void $ runExceptT stopAction
    Right (_, _, RCRecv {wait = time}) -> liftIO (handleRecvWithStop time remoteOutputQ remoteStopEvent) >>= reply
    Right (rfKN, getNext, rc) -> do
      -- Decryption can wait for body data while this session is revoked. Check
      -- admission after parsing, before executing commands or receiving files.
      admitted <-
        withRemoteSession remoteOutputQ $
          chatReadVar' currentUser >>= \case
            Nothing -> replyError $ ChatError CENoActiveUser
            Just user -> processCommand user rfKN getNext rc `catchAllErrors'` replyError
      either reply pure admitted
    Left e -> reply $ RRProtocolError e
  where
    parseRequest :: ExceptT RemoteProtocolError IO (C.SbKeyNonce, GetChunk, RemoteCommand)
    parseRequest = do
      (rfKN, header, getNext) <- parseDecryptHTTP2Body maxCommandBodySize encryption request reqBody
      (rfKN,getNext,) <$> liftEitherWith RPEInvalidJSON (J.eitherDecodeStrict header)
    replyError = reply . RRChatResponse . RRError
    processCommand :: User -> C.SbKeyNonce -> GetChunk -> RemoteCommand -> CM ()
    processCommand user rfKN getNext = \case
      RCSend {command, retryNumber} -> lift $ do
        response <- withRemoteCommandLease remoteOutputQ $ handleSend execCC command retryNumber
        either reply reply response
      RCRecv {wait = time} -> lift $ liftIO (handleRecv time remoteOutputQ) >>= reply
      RCStoreFile {fileName, fileSize, fileDigest} -> lift $ handleStoreFile rfKN fileName fileSize fileDigest getNext >>= reply
      RCGetFile {file} -> handleGetFile user file replyWith
    reply :: RemoteResponse -> CM' ()
    reply = (`replyWith` \_ _ -> pure ())
    replyWith :: Respond
    replyWith rr attach = do
      closed <- atomically $ eventBufferClosed remoteOutputQ
      let (response, attachment) = case closed of
            Nothing -> (rr, attach)
            Just _ -> case rr of
              RRChatEvent (Just (RRResult CEvtRemoteCtrlStopped {})) -> (rr, \_ _ -> pure ())
              _ -> (remoteSessionClosed, \_ _ -> pure ())
      (corrId, cmdKN, sfKN) <- atomically $ getRemoteSndKeys encryption
      liftIO (tryAllErrors' . encryptEncodeHTTP2Body corrId cmdKN encryption $ J.encode response) >>= \case
        Right resp -> liftIO . sendResponse . responseStreaming N.status200 [] $ \send flush -> do
          send resp
          attachment sfKN send
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

handleRecv :: Int -> EventBuffer (Either ChatError ChatEvent) -> IO RemoteResponse
handleRecv time events = newEmptyTMVarIO >>= handleRecvWithStop time events

-- The stop control message remains deliverable after request admission is revoked.
handleRecvWithStop :: Int -> EventBuffer (Either ChatError ChatEvent) -> TMVar (Either ChatError ChatEvent) -> IO RemoteResponse
handleRecvWithStop time events stopEvent = do
  logDebug $ "Recv: " <> tshow time
  timeout time (atomically $ (Right <$> takeTMVar stopEvent) `orElse` readEventBuffer events) >>= \case
    Nothing -> pure $ RRChatEvent Nothing
    Just (Right event) -> pure $ RRChatEvent $ Just $ eitherToResult event
    Just (Left _) -> pure remoteSessionClosed

-- | An event stream is also the lifetime token of its authenticated session.
-- This is an admission check, not a global command lock. Already admitted
-- requests are cancelled by the HTTP2 server shutdown; they may have committed
-- before revocation. In particular, never hold an STM transaction or a command
-- gate while reading an upload, waiting for an event, or writing a response.
withRemoteSession :: MonadIO m => EventBuffer a -> m b -> m (Either RemoteResponse b)
withRemoteSession events action = do
  closed <- liftIO . atomically $ eventBufferClosed events
  case closed of
    Just _ -> pure $ Left remoteSessionClosed
    Nothing -> Right <$> action

-- A shared profile lease, not a serialization gate: any number of admitted
-- commands run concurrently. Selection after unlink waits for these to drain.
-- Admission and increment share one STM transaction with the revocation token;
-- bracket releases the count on errors, cancellation and reply preparation.
withRemoteCommandLease :: EventBuffer a -> CM' b -> CM' (Either RemoteResponse b)
withRemoteCommandLease events action = do
  leases <- asks remoteCommandLeases
  let acquire =
        atomically $
          eventBufferClosed events >>= \case
            Just _ -> pure False
            Nothing -> modifyTVar' leases (+ 1) $> True
      release admitted = when admitted $ atomically $ modifyTVar' leases (subtract 1)
  bracket acquire release $ \admitted ->
    if admitted then Right <$> action else pure $ Left remoteSessionClosed

remoteSessionClosed :: RemoteResponse
remoteSessionClosed = RRProtocolError RPESessionClosed

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
    storeFileTo dir = do
      gate <- asks remoteFileNameGate
      liftIO $ mask $ \restore -> do
        reserved <- withCommandGate gate . tryAllErrors' $ do
          unless (validRemoteFileName fileName) $ throwError $ RPEInvalidBody "invalid file name"
          filePath <- liftIO $ dir `uniqueCombine` fileName
          canonPath <- liftIO $ canonicalizePath filePath
          inDir <- liftIO $ (takeDirectory canonPath ==) <$> canonicalizePath dir
          unless inDir $ throwError $ RPEInvalidBody "file path outside of files folder"
          -- Reserve before releasing the name gate; attachment IO never holds it.
          liftIO $ B.writeFile filePath ""
          pure filePath
        case reserved of
          Left e -> pure $ Left e
          Right filePath -> do
            result <-
              restore (tryAllErrors' $ receiveEncryptedFile rfKN getChunk fileSize fileDigest filePath >> pure filePath)
                `onException` removeFile filePath
            case result of
              Left _ -> removeFile filePath
              Right _ -> pure ()
            pure result

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
  sessions <- M.elems <$> chatReadVar remoteCtrlSessions
  let states = M.fromList [(rcId, rcsSessionState session) | session <- sessions, Just rcId <- [remoteCtrlSessionId session]]
  map (\rc@RemoteCtrl {remoteCtrlId} -> remoteCtrlInfo rc $ M.lookup remoteCtrlId states) <$> withStore' getRemoteCtrls

remoteCtrlInfo :: RemoteCtrl -> Maybe RemoteCtrlSessionState -> RemoteCtrlInfo
remoteCtrlInfo RemoteCtrl {remoteCtrlId, ctrlDeviceName, recoveryEndpoint} sessionState =
  RemoteCtrlInfo {remoteCtrlId, ctrlDeviceName, recoveryEnabled = isJust recoveryEndpoint, sessionState}

-- | Take a look at emoji of tlsunique, commit pairing, and start session server
verifyRemoteCtrlSession :: (ByteString -> Int -> CM' (Either ChatError ChatResponse)) -> Text -> CM ChatResponse
verifyRemoteCtrlSession execCC sessCode' = do
  (sseq, client, ctrlName, sessionCode, vars, recoveryEndpoint) <-
    do
      sessions <- M.toList <$> chatReadVar remoteCtrlSessions
      let pending = [(seqNo, session) | (seqNo, session@RCSessionPendingConfirmation {}) <- sessions]
          matching = filter (\(_, RCSessionPendingConfirmation {sessionCode}) -> sameVerificationCode sessCode' sessionCode) pending
          selected = case matching of [one] -> Just one; _ -> case pending of [one] -> Just one; _ -> Nothing
      case selected of
        Just (seqNo, RCSessionPendingConfirmation {rcsClient, ctrlDeviceName, sessionCode, rcsWaitConfirmation, recoveryEndpoint}) ->
          pure (seqNo, rcsClient, ctrlDeviceName, sessionCode, rcsWaitConfirmation, recoveryEndpoint)
        _ -> throwError $ ChatErrorRemoteCtrl RCEBadState
  handleCtrlError sseq RCSRSetupFailed "verifyRemoteCtrlSession" $ do
    let verified = sameVerificationCode sessCode' sessionCode
    timeoutThrow (ChatErrorRemoteCtrl RCETimeout) networkIOTimeout . liftIO $ confirmCtrlSession client verified -- signal verification result before crashing
    unless verified $ throwError $ ChatErrorRemoteCtrl $ RCEProtocolError PRESessionCode
    (rcsSession@RCCtrlSession {tls, sessionKeys}, rcCtrlPairing) <- timeoutThrow (ChatErrorRemoteCtrl RCETimeout) networkIOTimeout $ takeRCStep vars
    rc@RemoteCtrl {remoteCtrlId} <- commitRemoteCtrlPairing sseq ctrlName rcCtrlPairing recoveryEndpoint
    remoteOutputQ <- asks (tbqSize . config) >>= atomically . newEventBuffer
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
            handleRemoteCommand execCC (atomically $ closeEventBuffer remoteOutputQ EBDetached >> void (tryPutTMVar desktopStop ())) encryption remoteOutputQ remoteStopEvent req `runReaderT` cc
          stopped = atomically (readTMVar desktopStop) >> closeRemoteHostTransport tls
          idle = remoteCtrlWatchdog remoteCtrlIdleTimeout activity (closeRemoteHostTransport tls)
      race_ server $ if retainLink then race_ stopped idle else stopped
    ( updateRemoteCtrlSession sseq $ \case
        RCSessionPendingConfirmation {ctrlAppInfo} -> Right RCSessionConnected {remoteCtrlId, rcsClient = client, rcsSession, tls, http2Server, remoteOutputQ, remoteStopEvent, recoveryEndpoint, ctrlAppInfo}
        _ -> Left $ ChatErrorRemoteCtrl RCEBadState
      )
      `catchAllErrors` \e -> liftIO (cancel http2Server) >> throwError e
    atomically $ putTMVar serverReady ()
    void . forkIO $ monitor sseq http2Server remoteOutputQ desktopStop
    let remoteCtrl = remoteCtrlInfo rc $ Just RCSConnected {sessionCode = tlsSessionCode tls}
    pure CRRemoteCtrlConnected {remoteCtrl, compression}
  where
    monitor :: SessionSeq -> Async () -> EventBuffer (Either ChatError ChatEvent) -> TMVar () -> CM ()
    monitor sseq server events desktopStop = do
      res <- race (waitCatch server) (atomically $ waitEventBufferClosed events)
      -- Close network IO before waiting for the server on overflow/revocation.
      case res of
        Right EBOverflow -> do
          var <- asks remoteCtrlSessions
          (M.lookup sseq <$> readTVarIO var) >>= \case
            Just RCSessionConnected {tls} -> liftIO $ closeRemoteHostTransport tls
            _ -> pure ()
          cancel server
        Right EBDetached -> pure () -- explicit stop owns graceful delivery and cleanup
        Left _ -> pure ()
      logInfo $ "HTTP2 server stopped: " <> tshow res
      intentional <- atomically $ not <$> isEmptyTMVar desktopStop
      when intentional $ do
        sessionVar <- asks remoteCtrlSessions
        withStore' $ \db ->
          (M.lookup sseq <$> readTVarIO sessionVar) >>= \case
            Just RCSessionConnected {remoteCtrlId} -> setRemoteCtrlRecovery db remoteCtrlId Nothing
            _ -> pure ()
      cancelActiveRemoteCtrl $ Just (sseq, if intentional then RCSRStopped else RCSRDisconnected)

-- Check ownership INSIDE the database transaction that commits trust and enable
-- state. A stop clears the owner before its final revocation transaction. If it
-- races this transaction, revocation therefore serializes after the commit; a
-- late verification after stop/unlink cannot insert or re-enable a pairing.
commitRemoteCtrlPairing :: SessionSeq -> Text -> RCCtrlPairing -> Maybe RCEndpoint -> CM RemoteCtrl
commitRemoteCtrlPairing sseq ctrlName rcCtrlPairing endpoint = do
  sessionVar <- asks remoteCtrlSessions
  committed <- withStore $ \db -> do
    owns <-
      liftIO $
        (M.lookup sseq <$> readTVarIO sessionVar) >>= \case
          Just RCSessionPendingConfirmation {} -> pure True
          _ -> pure False
    if not owns
      then pure Nothing
      else do
        existing <- liftIO $ getRemoteCtrlByFingerprint db (ctrlFingerprint rcCtrlPairing)
        rc@RemoteCtrl {remoteCtrlId} <- case existing of
          Nothing -> insertRemoteCtrl db ctrlName rcCtrlPairing >>= getRemoteCtrl db
          Just rc@RemoteCtrl {ctrlPairing} -> do
            let dhPrivKey' = dhPrivKey rcCtrlPairing
            liftIO $ updateRemoteCtrl db rc ctrlName dhPrivKey'
            pure rc {ctrlDeviceName = ctrlName, ctrlPairing = ctrlPairing {dhPrivKey = dhPrivKey'}}
        liftIO . atomically
          $ modifyTVar' sessionVar
          $ M.adjust
            ( \session -> case session of
                pending@RCSessionPendingConfirmation {} -> (pending :: RemoteCtrlSession) {remoteCtrlId_ = Just remoteCtrlId}
                other -> other
            )
            sseq
        liftIO $ setRemoteCtrlRecovery db remoteCtrlId endpoint
        pure $ Just (rc :: RemoteCtrl) {recoveryEndpoint = endpoint}
  maybe (throwError $ ChatErrorRemoteCtrl RCEInactive) pure committed

stopRemoteCtrl :: CM ()
stopRemoteCtrl = stopRemoteCtrlFor Nothing

stopRemoteCtrlFor :: Maybe RemoteCtrlId -> CM ()
stopRemoteCtrlFor rcId =
  stopRemoteCtrlMatching
    (isJust rcId)
    (\_ session -> maybe True (\rid -> remoteCtrlSessionId session == Just rid) rcId)
    (\db -> maybe (disableRemoteCtrlRecovery db) (\rid -> setRemoteCtrlRecovery db rid Nothing) rcId)

stopRemoteCtrlSession :: SessionSeq -> CM ()
stopRemoteCtrlSession sseq = stopRemoteCtrlMatching True (\seqNo _ -> seqNo == sseq) (const $ pure ())

stopPendingRemoteCtrl :: CM ()
stopPendingRemoteCtrl = stopRemoteCtrlMatching True (\_ session -> isNothing $ remoteCtrlSessionId session) (const $ pure ())

stopRemoteCtrlMatching :: Bool -> (SessionSeq -> RemoteCtrlSession -> Bool) -> (DB.Connection -> IO ()) -> CM ()
stopRemoteCtrlMatching emitEvent matches revoke = do
  withStore' revoke
  var <- asks remoteCtrlSessions
  closing <- atomically $ do
    sessions <- readTVar var
    let selected = M.filterWithKey matches sessions
    forM_ (M.toList selected) $ \(sseq, session) -> case session of
      RCSessionConnected {remoteStopEvent, ctrlAppInfo = CtrlAppInfo {reconnect = BoolDef True}} ->
        void $ tryPutTMVar remoteStopEvent $ Right CEvtRemoteCtrlStopped {rcsState = rcsSessionState session, rcStopReason = RCSRStopped, sessionSeq = sseq, remoteCtrlId_ = remoteCtrlSessionId session}
      _ -> pure ()
    concat <$> mapM (takeRemoteCtrlSessions var . Just) (M.keys selected)
  forM_ closing $ \(sseq, session) -> do
    case session of
      RCSessionConnected {http2Server, ctrlAppInfo = CtrlAppInfo {reconnect = BoolDef True}} -> void $ timeout 2000000 $ waitCatch http2Server
      _ -> pure ()
    liftIO $ cancelRemoteCtrl False session
    when emitEvent $ toView CEvtRemoteCtrlStopped {rcsState = rcsSessionState session, rcStopReason = RCSRStopped, sessionSeq = sseq, remoteCtrlId_ = remoteCtrlSessionId session}
  -- A first verification may already hold the store transaction when stop
  -- unpublishes it. Revoke by its verified fingerprint after that transaction,
  -- even if it had not yet acquired a database pairing ID at unpublication.
  withStore' $ \db -> do
    revoke db
    forM_ closing $ \(_, session) -> case remoteCtrlSessionId session of
      Just rcId -> setRemoteCtrlRecovery db rcId Nothing
      Nothing -> forM_ (sessionFingerprint session) $ \fingerprint ->
        getRemoteCtrlByFingerprint db fingerprint >>= mapM_ (\RemoteCtrl {remoteCtrlId} -> setRemoteCtrlRecovery db remoteCtrlId Nothing)
  where
    sessionFingerprint = \case
      RCSessionConnecting {remoteCtrlFingerprint} -> Just remoteCtrlFingerprint
      RCSessionPendingConfirmation {remoteCtrlFingerprint} -> Just remoteCtrlFingerprint
      _ -> Nothing

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
    sessionVar <- asks remoteCtrlSessions
    when (terminalRecoveryError e) $ withStore' $ \db -> do
      active <- M.lookup sseq <$> readTVarIO sessionVar
      forM_ (active >>= remoteCtrlSessionId) $ \rcId -> setRemoteCtrlRecovery db rcId Nothing
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
  var <- asks remoteCtrlSessions
  sessions <- atomically $ takeRemoteCtrlSessions var (fst <$> handlerInfo_)
  forM_ sessions $ \(sseq, session) -> do
    liftIO $ cancelRemoteCtrl handlingError session
    when emitEvent $ forM_ (snd <$> handlerInfo_) $ \rcStopReason ->
      toView CEvtRemoteCtrlStopped {rcsState = rcsSessionState session, rcStopReason, sessionSeq = sseq, remoteCtrlId_ = remoteCtrlSessionId session}

-- Revoke request admission in the same transaction as unpublishing the
-- session, before asynchronous transport cleanup can yield. The owner-core
-- stop path must use this too. A stale monitor must not revoke a new session.
takeRemoteCtrlSessions :: TVar (M.Map SessionSeq RemoteCtrlSession) -> Maybe SessionSeq -> STM [(SessionSeq, RemoteCtrlSession)]
takeRemoteCtrlSessions var expectedSeq = do
  sessions <- readTVar var
  let (closing, remaining) = M.partitionWithKey (\sseq _ -> maybe True (== sseq) expectedSeq) sessions
  forM_ (M.elems closing) $ \case
    RCSessionConnected {remoteOutputQ} -> closeEventBuffer remoteOutputQ EBDetached
    _ -> pure ()
  writeTVar var remaining
  pure $ M.toList closing

cancelRemoteCtrl :: Bool -> RemoteCtrlSession -> IO ()
cancelRemoteCtrl handlingError = \case
  RCSessionStarting {} -> pure ()
  RCSessionSearching {action} ->
    unless handlingError $ uninterruptibleCancel action
  RCSessionConnecting {rcsClient, rcsWaitSession} -> do
    unless handlingError $ uninterruptibleCancel rcsWaitSession
    cancelCtrlClient rcsClient
  RCSessionPendingConfirmation {rcsClient, tls, rcsWaitSession} -> do
    unless handlingError $ uninterruptibleCancel rcsWaitSession
    cancelCtrlClient rcsClient
    closeConnection tls
  RCSessionConnected {rcsClient, tls, http2Server, remoteOutputQ} -> do
    atomically $ closeEventBuffer remoteOutputQ EBDetached
    -- Unblock HTTP/2 IO before joining workers, including file streams.
    closeRemoteHostTransport tls
    unless handlingError $ uninterruptibleCancel http2Server
    cancelCtrlClient rcsClient

deleteRemoteCtrl :: RemoteCtrlId -> CM ()
deleteRemoteCtrl rcId = do
  enabled <- chatReadVar simultaneousUI
  if enabled then stopRemoteCtrlFor (Just rcId) else checkNoRemoteCtrlSession
  withStore' (`deleteRemoteCtrlRecord` rcId)

checkNoRemoteCtrlSession :: CM ()
checkNoRemoteCtrlSession = do
  sessions <- chatReadVar remoteCtrlSessions
  unless (M.null sessions) $ throwError $ ChatErrorRemoteCtrl RCEBusy

-- | Transition controller to a new state, unless session update key is stale
updateRemoteCtrlSession :: SessionSeq -> (RemoteCtrlSession -> Either ChatError RemoteCtrlSession) -> CM ()
updateRemoteCtrlSession sseq state = do
  sessions <- asks remoteCtrlSessions
  liftIOEither . atomically $ do
    current <- readTVar sessions
    case M.lookup sseq current of
      Nothing -> pure . Left $ ChatErrorRemoteCtrl RCEInactive
      Just session -> case state session of
        Left ce -> pure $ Left ce
        Right session' -> Right () <$ writeTVar sessions (M.insert sseq session' current)

getRemoteCtrlAppInfo :: SessionSeq -> CM (Maybe CtrlAppInfo)
getRemoteCtrlAppInfo sseq = do
  current <- M.lookup sseq <$> chatReadVar remoteCtrlSessions
  pure $
    current >>= \case
      RCSessionStarting {} -> Nothing
      RCSessionSearching {} -> Nothing
      RCSessionConnecting {ctrlAppInfo} -> Just ctrlAppInfo
      RCSessionPendingConfirmation {ctrlAppInfo} -> Just ctrlAppInfo
      RCSessionConnected {ctrlAppInfo} -> Just ctrlAppInfo
