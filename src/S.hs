{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
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
import Control.Carrier.Reader
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
import qualified Data.Set as Set
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
  ( Auth (..),
    AuthMetric,
    CleanStatus (..),
    LogMet,
    NodeMet,
    NodeStatus (..),
    Role (..),
    SigAuth,
    SigLog,
    SigNode,
    Status (..),
    auth,
    log,
    t0,
    t1,
  )
import Prelude hiding (log)

data RNS = RNS
  { nrole :: Role,
    nmetrics :: Map String Int
  }
  deriving (Show, Generic, FromJSON, ToJSON)

data R = R
  { rmetric :: Map String Int,
    rauth :: Map String Int,
    rnodes :: Map Int RNS
  }
  deriving (Show, Generic, FromJSON, ToJSON)

type Api =
  "nodes" :> Get '[JSON] R
    :<|> "nodes" :> Capture "NodeId" Int :> Get '[JSON] RNS
    :<|> "clean_status" :> Capture "user name" String :> Put '[JSON] String
    :<|> "clean_status" :> Capture "user name" String :> Capture "NodeId" Int :> Put '[JSON] String
    :<|> "clean_log_status" :> Capture "user name" String :> Put '[JSON] String

api :: Proxy Api
api = Proxy

s1 ::
  ( MonadIO m,
    HasServer "log" SigLog '[Status] sig m,
    HasServer "auth" SigAuth '[Status] sig m,
    HasGroup "group" SigNode '[NodeStatus] sig m
  ) =>
  m R
s1 = do
  vls <- call @"log" Status

  ns <- sendAllCall @"group" NodeStatus

  nss <- forM ns $ \(NodeId nid, tvar) -> do
    (role, tt) <- liftIO $ atomically $ readTMVar tvar
    pure (nid, RNS role $ Map.fromList tt)

  authMs <- call @"auth" Status

  pure $
    R
      (Map.fromList vls)
      (Map.fromList authMs)
      (Map.fromList nss)

s2 ::
  ( MonadIO m,
    HasGroup "group" SigNode '[NodeStatus] sig m
  ) =>
  Int ->
  m RNS
s2 i = do
  (a, b) <- callById @"group" (NodeId i) NodeStatus
  pure (RNS a (Map.fromList b))

s3 ::
  ( MonadIO m,
    HasServer "auth" SigAuth '[Auth] sig m,
    HasGroup "group" SigNode '[CleanStatus] sig m
  ) =>
  String ->
  m String
s3 user =
  authen user $ do
    castAll @"group" CleanStatus
    pure "clean all node status"

s4 ::
  ( MonadIO m,
    HasServer "auth" SigAuth '[Auth] sig m,
    HasGroup "group" SigNode '[CleanStatus] sig m
  ) =>
  String ->
  Int ->
  m String
s4 user i =
  authen user $ do
    castById @"group" (NodeId i) CleanStatus
    pure $ "clean " ++ show (NodeId i) ++ " node status"

s5 ::
  ( MonadIO m,
    HasServer "auth" SigAuth '[Auth] sig m,
    HasServer "log" SigLog '[CleanStatus] sig m
  ) =>
  String ->
  m String
s5 user =
  authen user $ do
    cast @"log" CleanStatus
    pure "clean log status"

authen ::
  ( MonadIO m,
    HasServer "auth" SigAuth '[Auth] sig m
  ) =>
  String ->
  m String ->
  m String
authen user fun =
  call @"auth" (Auth user) >>= \case
    True -> fun
    False -> do
      pure "auth failed"

app ::
  Map NodeId (TChan (Some SigNode)) ->
  TChan (Some SigLog) ->
  TChan (Some SigAuth) ->
  Application
app mnt tchan authChan =
  serve api $
    hoistServer
      api
      ( runM @Handler
          . runWithServer @"log" tchan
          . runWithServer @"log" tchan
          . runWithServer @"auth" authChan
          . runWithServer @"auth" authChan
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

  authChan <- newMessageChan @SigAuth

  ls <- lines <$> readFile "data/user"

  forkIO
    . void
    . runReader (Set.fromList ls)
    . runMetric @AuthMetric
    $ runServerWithChan authChan auth

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
  runSettings (setHost "*4" $ setPort 8081 defaultSettings) (app mls logChan authChan)
