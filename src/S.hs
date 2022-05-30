{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module S where

import Control.Carrier.HasGroup
  ( GroupState (GroupState),
    HasGroup,
    callById,
    castAll,
    castById,
    runWithGroup,
    sendAllCall,
  )
import Control.Carrier.HasPeer
  ( PeerState (..),
    runWithPeers,
  )
import Control.Carrier.HasServer (HasServer, call, cast, runWithServer)
import Control.Carrier.Lift (runM)
import Control.Carrier.Metric (runMetric)
import Control.Carrier.State.Strict
  ( runState,
  )
import Control.Concurrent (forkIO)
import Control.Concurrent.STM (atomically, readTMVar)
import Control.Monad (forM, forM_, void)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Aeson (FromJSON, ToJSON)
import Data.Map (Map)
import qualified Data.Map as Map
import GHC.Generics (Generic)
import Network.Wai.Handler.Warp
  ( defaultSettings,
    runSettings,
    setHost,
    setPort,
  )
import Process.TChan (TChan, newTChanIO)
import Process.Type (NodeId (..), Some)
import Process.Util (newMessageChan, runServerWithChan)
import Servant
  ( Application,
    Capture,
    Get,
    Handler,
    JSON,
    Proxy (..),
    hoistServer,
    serve,
    type (:<|>) (..),
    type (:>),
  )
import Servant.API.Verbs (Put)
import T
  ( CleanStatus (..),
    LogMet,
    NodeMet,
    NodeStatus (..),
    Role (..),
    SigLog,
    SigNode,
    Status (..),
    log,
    t0,
    t1,
  )
import Prelude hiding (log)

data RNS = RNS
  { nnoid :: String,
    nrole :: Role,
    nmetrics :: [(String, Int)]
  }
  deriving (Show, Generic, FromJSON, ToJSON)

data R = R
  { rmetric :: [(String, Int)],
    rnodes :: [RNS]
  }
  deriving (Show, Generic, FromJSON, ToJSON)

type Api =
  "nodes" :> Get '[JSON] R
    :<|> "nodes" :> Capture "NodeId" Int :> Get '[JSON] RNS
    :<|> "clean_status" :> Put '[JSON] String
    :<|> "clean_status" :> Capture "NodeId" Int :> Put '[JSON] String
    :<|> "clean_log_status" :> Put '[JSON] String

api :: Proxy Api
api = Proxy

s1 ::
  ( MonadIO m,
    HasServer "log" SigLog '[Status] sig m,
    HasGroup "group" SigNode '[NodeStatus] sig m
  ) =>
  m R
s1 = do
  vls <- call @"log" Status
  ns <- sendAllCall @"group" NodeStatus
  nss <- forM ns $ \(nid, tvar) -> do
    tt <- liftIO $ atomically $ readTMVar tvar
    pure (show nid, tt)
  pure $ R vls (map (\(a, (b, c)) -> RNS a b c) nss)

s2 ::
  ( MonadIO m,
    HasGroup "group" SigNode '[NodeStatus] sig m
  ) =>
  Int ->
  m RNS
s2 i = do
  (a, b) <- callById @"group" (NodeId i) NodeStatus
  pure (RNS (show $ NodeId i) a b)

s3 ::
  ( MonadIO m,
    HasGroup "group" SigNode '[CleanStatus] sig m
  ) =>
  m String
s3 = do
  castAll @"group" CleanStatus
  pure "clean all node status"

s4 ::
  ( MonadIO m,
    HasGroup "group" SigNode '[CleanStatus] sig m
  ) =>
  Int ->
  m String
s4 i = do
  castById @"group" (NodeId i) CleanStatus
  pure $ "clean " ++ show (NodeId i) ++ " node status"

s5 ::
  ( MonadIO m,
    HasServer "log" SigLog '[CleanStatus] sig m
  ) =>
  m String
s5 = do
  cast @"log" CleanStatus
  pure "clean log status"

app ::
  Map NodeId (TChan (Some SigNode)) ->
  TChan (Some SigLog) ->
  Application
app mnt tchan =
  serve api $
    hoistServer
      api
      ( runM @Handler
          . runWithServer @"log" tchan
          . runWithServer @"log" tchan
          . runWithGroup @"group" (GroupState mnt)
          . runWithGroup @"group" (GroupState mnt)
      )
      (s1 :<|> s2 :<|> s3 :<|> s4 :<|> s5)

main :: IO ()
main = do
  nodes <- forM [1 .. 4] $ \i -> do
    tc <- newTChanIO
    pure (NodeId i, tc)
  let nodeMap = Map.fromList nodes
  hhs@(h : hs) <- forM nodes $ \(nid, tc) -> do
    nchan <- newMessageChan @SigNode
    pure ((nid, nchan), PeerState nid (Map.delete nid nodeMap) tc)

  logChan <- newMessageChan @SigLog

  forkIO
    . void
    . runMetric @LogMet
    $ runServerWithChan logChan log

  forkIO
    . void
    $ runWithServer @"log" logChan t0

  forkIO
    . void
    . runWithServer @"log" logChan
    . runServerWithChan @SigNode (snd $ fst h)
    . runWithPeers @"peer" (snd h)
    . runMetric @NodeMet
    $ runState Master t1

  forM_ hs $ \h' -> do
    forkIO
      . void
      . runWithServer @"log" logChan
      . runServerWithChan @SigNode (snd $ fst h')
      . runWithPeers @"peer" (snd h')
      . runMetric @NodeMet
      $ runState Slave t1

  putStrLn "start server"
  let mls = Map.fromList $ map fst hhs
  runSettings (setHost "*4" $ setPort 8081 defaultSettings) (app mls logChan)
