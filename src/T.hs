{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module T where

import Control.Carrier.HasPeer
  ( HasPeer,
    callAll,
    callById,
  )
import Control.Carrier.HasServer (HasServer, cast)
import qualified Control.Carrier.HasServer as S
import Control.Carrier.Metric
import Control.Carrier.Reader
import Control.Carrier.State.Strict
  ( State,
    get,
    put,
  )
import Control.Concurrent
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TMVar (readTMVar)
import Control.Effect.Metric (reset)
import Control.Monad (forM, forever)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Aeson (FromJSON)
import Data.Aeson.Types (ToJSON)
import Data.Set (Set)
import qualified Data.Set as Set
import GHC.Generics
import Process.TH
import Process.Type
import Process.Util
import System.Random
import Prelude hiding (log)

data Role = Master | Slave
  deriving (Show, Generic, FromJSON, ToJSON)

data ChangeMaster where
  ChangeMaster :: RespVal () %1 -> ChangeMaster

data CallMsg where
  CallMsg :: RespVal Int %1 -> CallMsg

data Log where
  Log :: String -> Log

data AuthLog where
  AuthLog :: (String, Bool) -> AuthLog

data Cal where
  Cal :: Cal

data CS where
  CS :: String -> CS

data Status where
  Status :: RespVal [(String, Int)] %1 -> Status

data NodeStatus where
  NodeStatus :: RespVal (Role, [(String, Int)]) %1 -> NodeStatus

data CleanStatus where
  CleanStatus :: CleanStatus

data Auth where
  Auth :: String -> RespVal Bool %1 -> Auth

mkSigAndClass
  "SigAuth"
  [ ''Auth,
    ''Status
  ]

mkSigAndClass
  "SigNode"
  [ ''NodeStatus,
    ''CleanStatus
  ]

mkSigAndClass
  "SigLog"
  [ ''Log,
    ''Cal,
    ''Status,
    ''CleanStatus,
    ''AuthLog
  ]

mkSigAndClass
  "SigRPC"
  [ ''CallMsg,
    ''ChangeMaster
  ]

mkMetric
  "LogMet"
  [ "all_log",
    "all_all",
    "rate"
  ]

mkMetric
  "NodeMet"
  [ "all_a",
    "all_b",
    "all_c"
  ]

mkMetric
  "AuthMetric"
  [ "auth_success",
    "auth_failed"
  ]

auth ::
  ( MonadIO m,
    Has (Reader (Set String)) sig m,
    Has (Metric AuthMetric) sig m,
    Has (MessageChan SigAuth) sig m,
    HasServer "log" SigLog '[AuthLog] sig m
  ) =>
  m ()
auth = forever $ do
  withMessageChan @SigAuth \case
    SigAuth1 (Auth name resp) -> withResp resp $ do
      names <- ask
      if Set.member name names
        then do
          cast @"log" $ AuthLog (name, True)
          inc auth_success
          pure True
        else do
          cast @"log" $ AuthLog (name, False)
          inc auth_failed
          pure False
    SigAuth2 (Status resp) ->
      withResp resp $ getAll @AuthMetric

log ::
  ( MonadIO m,
    Has (Metric LogMet) sig m,
    Has (MessageChan SigLog) sig m
  ) =>
  m ()
log = forever $ do
  withMessageChan @SigLog \case
    SigLog1 (Log _) -> do
      inc all_all
      inc all_log
    SigLog2 Cal -> do
      val <- getVal all_log
      all <- getVal all_all
      liftIO $ print (val, all)
      putVal rate val
      putVal all_log 0
    SigLog3 (Status resp) -> withResp resp $ do
      getAll @LogMet
    SigLog4 CleanStatus -> do
      reset @LogMet
    SigLog5 (AuthLog al) -> do
      liftIO $ print al

t0 ::
  ( MonadIO m,
    HasServer "log" SigLog '[Cal] sig m
  ) =>
  m ()
t0 = forever $ do
  S.cast @"log" Cal
  liftIO $ threadDelay 1_000_000

t1 ::
  ( MonadIO m,
    Has (State Role) sig m,
    Has (Metric NodeMet) sig m,
    Has (MessageChan SigNode) sig m,
    HasServer "log" SigLog '[Log] sig m,
    HasPeer "peer" SigRPC '[CallMsg, ChangeMaster] sig m
  ) =>
  m ()
t1 = forever $ do
  inc all_a

  handleFlushMsgs @SigNode $ \case
    SigNode1 (NodeStatus resp) -> withResp resp $ do
      rv <- getAll @NodeMet
      role <- get @Role
      pure (role, rv)
    SigNode2 CleanStatus -> do
      reset @NodeMet

  get @Role >>= \case
    Master -> do
      inc all_b
      res <- callAll @"peer" $ CallMsg
      vals <- forM res $ \(a, b) -> do
        val <- liftIO $ atomically $ readTMVar b
        pure (val, a)
      let mnid = snd $ maximum vals
      callById @"peer" mnid ChangeMaster
      put Slave
    Slave -> do
      inc all_c
      handleMsg @"peer" $ \case
        SigRPC1 (CallMsg rsp) -> withResp rsp $ do
          liftIO $ randomRIO @Int (1, 1_000_000)
        SigRPC2 (ChangeMaster rsp) -> withResp rsp $ do
          S.cast @"log" $ Log ""
          put Master
