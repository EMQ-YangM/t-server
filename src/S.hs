{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module S where

import Control.Carrier.Lift hiding (run)
import Control.Carrier.State.Strict
  ( runState,
  )
import Control.Concurrent
import Control.Concurrent.STM (atomically, readTMVar)
import Control.Monad
import Control.Monad.IO.Class
import Data.Aeson
import Data.Map (Map)
import qualified Data.Map as Map
import GHC.Generics (Generic)
import Network.Wai.Handler.Warp
import Process.HasGroup as G
import Process.HasPeerGroup
  ( NodeState (..),
    runWithPeers',
  )
import Process.HasServer
import Process.Metric
import Process.TChan (TChan, newTChanIO)
import Process.Type
import Process.Util
import Servant hiding (HasServer)
import T
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

api :: Proxy Api
api = Proxy

s1 ::
  ( MonadIO m,
    HasServer "log" SigLog '[Status] sig m,
    HasGroup "group" SigNode '[NodeStatus] sig m,
    Has (Lift Handler) sig m
  ) =>
  m R
s1 = do
  vls <- call @"log" Status
  ns <- G.sendAllCall @"group" NodeStatus
  nss <- forM ns $ \(nid, tvar) -> do
    tt <- liftIO $ atomically $ readTMVar tvar
    pure (show nid, tt)
  pure $ R vls (map (\(a, (b, c)) -> RNS a b c) nss)

s2 ::
  ( MonadIO m,
    Has (Lift Handler) sig m,
    HasGroup "group" SigNode '[NodeStatus] sig m
  ) =>
  Int ->
  m RNS
s2 i = do
  (a, b) <- G.callById @"group" (NodeId i) NodeStatus
  pure (RNS (show $ NodeId i) a b)

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
          . runWithWorkGroup' @"group" (WorkGroupState mnt)
      )
      (s1 :<|> s2)

main :: IO ()
main = do
  nodes <- forM [1 .. 4] $ \i -> do
    tc <- newTChanIO
    pure (NodeId i, tc)
  let nodeMap = Map.fromList nodes
  hhs@(h : hs) <- forM nodes $ \(nid, tc) -> do
    nchan <- newMessageChan @SigNode
    pure ((nid, nchan), NodeState nid (Map.delete nid nodeMap) tc)

  logChan <- newMessageChan @SigLog

  forkIO $
    void $
      runMetric @LogMet $
        runServerWithChan logChan log

  forkIO $
    void $
      runWithServer @"log" logChan t0

  forkIO $
    void $
      runWithServer @"log" logChan $
        runServerWithChan @SigNode (snd $ fst h) $
          runWithPeers' @"peer" (snd h) $
            runMetric @NodeMet $
              runState Master t1

  forM_ hs $ \h' -> do
    forkIO $
      void $
        runWithServer @"log" logChan $
          runServerWithChan @SigNode (snd $ fst h') $
            runWithPeers' @"peer" (snd h') $
              runMetric @NodeMet $
                runState Slave t1

  putStrLn "start server"
  let mls = Map.fromList $ map fst hhs
  runSettings (setHost "*4" $ setPort 8081 defaultSettings) (app mls logChan)
