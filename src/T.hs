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

import Control.Algebra (Has)
import Control.Carrier.State.Strict
  ( State,
    get,
    put,
  )
import Control.Concurrent
import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TMVar (readTMVar)
import Control.Monad (forM, forever)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Aeson (FromJSON)
import Data.Aeson.Types (ToJSON)
import GHC.Generics
import Process.HasPeerGroup
  ( HasPeerGroup,
    callAll,
    callById,
  )
import Process.HasServer (HasServer)
import qualified Process.HasServer as S
import Process.Metric
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

data Cal where
  Cal :: Cal

data CS where
  CS :: String -> CS

data Status where
  Status :: RespVal [(String, Int)] %1 -> Status

data NodeStatus where
  NodeStatus :: RespVal (Role, [(String, Int)]) %1 -> NodeStatus

mkSigAndClass
  "SigNode"
  [ ''NodeStatus
  ]

mkSigAndClass
  "SigLog"
  [ ''Log,
    ''Cal,
    ''Status
  ]

mkSigAndClass
  "SigRPC"
  [ ''CallMsg,
    ''ChangeMaster
  ]

mkMetric
  "LogMet"
  [ "all_log",
    "all_all"
  ]

mkMetric
  "NodeMet"
  [ "all_a",
    "all_b",
    "all_c"
  ]

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
      putVal all_log 0
    SigLog3 (Status resp) -> withResp resp $ do
      getAll @LogMet

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
    HasPeerGroup "peer" SigRPC '[CallMsg, ChangeMaster] sig m
  ) =>
  m ()
t1 = forever $ do
  inc all_a
  handleFlushMsgs @SigNode $ \case
    SigNode1 (NodeStatus resp) -> withResp resp $ do
      rv <- getAll @NodeMet
      role <- get @Role
      pure (role, rv)

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
