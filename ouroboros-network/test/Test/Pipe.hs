{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE CPP                 #-}

{-# OPTIONS_GHC -Wno-orphans     #-}

module Test.Pipe (tests) where

import           Codec.Serialise (Serialise (..))
import           Control.Monad
import           Control.Monad.Class.MonadAsync
import           Control.Monad.Class.MonadFork
import           Control.Monad.Class.MonadSTM
import           Control.Monad.Class.MonadTimer
import qualified Data.ByteString.Lazy as BL
import           Data.Int
import           Data.List (mapAccumL)
import           Data.Void (Void)
import           System.Process (createPipe)
import           Test.ChainGenerators (TestBlockChainAndUpdates (..))
import           Test.QuickCheck
import           Test.Tasty (TestTree, testGroup)
import           Test.Tasty.QuickCheck (testProperty)
import           Text.Show.Functions ()

import           Codec.SerialiseTerm
import           Control.Tracer

import           Ouroboros.Network.Mux
import qualified Network.Mux as Mx
import qualified Network.Mux.Bearer.Pipe as Mx
import           Network.Mux.Types (MuxBearer)

import           Network.TypedProtocol.Driver
import qualified Network.TypedProtocol.ReqResp.Client as ReqResp
import qualified Network.TypedProtocol.ReqResp.Server as ReqResp
import qualified Network.TypedProtocol.ReqResp.Codec.Cbor as ReqResp
import qualified Network.TypedProtocol.ReqResp.Examples as ReqResp


import           Ouroboros.Network.MockChain.Chain (Chain, ChainUpdate, Point)
import qualified Ouroboros.Network.MockChain.Chain as Chain
import qualified Ouroboros.Network.MockChain.ProducerState as CPS
import           Ouroboros.Network.NodeToNode
import           Ouroboros.Network.Protocol.ChainSync.Client as ChainSync
import           Ouroboros.Network.Protocol.ChainSync.Codec as ChainSync
import           Ouroboros.Network.Protocol.ChainSync.Examples as ChainSync
import           Ouroboros.Network.Protocol.ChainSync.Server as ChainSync
import           Ouroboros.Network.Protocol.Handshake.Type (acceptEq)
import           Ouroboros.Network.Protocol.Handshake.Version (simpleSingletonVersions)
import qualified Ouroboros.Network.Snocket as Snocket
import           Ouroboros.Network.Socket as Socket

import Text.Printf

--
-- The list of all tests
--

tests :: TestTree
tests =
#if defined(mingw32_HOST_OS)
      testGroup "Pipe"
                 [ testProperty "pipe sync demo" prop_pipe_demo
                 {- Named pipes testcase is disabled since it causes
                  - a deadlock when we attempt to cancel a thread that
                  - is blocked in hPut().
                  -}
                 --  testProperty "namedpipe sync demo" prop_namedpipe_demo
                 --  testProperty "named pipes" prop_pipe_send_recv_
                 ]
#else
      testGroup "Pipe"
                 [ testProperty "pipe sync demo"        prop_pipe_demo
                 ]
#endif

--
-- Properties
--

prop_pipe_demo :: TestBlockChainAndUpdates -> Property
prop_pipe_demo (TestBlockChainAndUpdates chain updates) =
    ioProperty $ anonymousPipesDemo chain updates


defaultMiniProtocolLimit :: Int64
defaultMiniProtocolLimit = 3000000

-- | The enumeration of all mini-protocols in our demo protocol.
data DemoProtocols = ChainSync
  deriving (Eq, Ord, Enum, Bounded, Show)

instance Mx.ProtocolEnum DemoProtocols where
  fromProtocolEnum ChainSync = 2

  toProtocolEnum 2 = Just ChainSync
  toProtocolEnum _ = Nothing

instance Mx.MiniProtocolLimits DemoProtocols where
  maximumMessageSize ChainSync  = defaultMiniProtocolLimit
  maximumIngressQueue ChainSync = defaultMiniProtocolLimit

-- |
-- Allow to run a singly req-resp protocol.
--
data TestProtocols2 = ReqRespPr
  deriving (Eq, Ord, Enum, Bounded, Show)

instance Mx.ProtocolEnum TestProtocols2 where
  fromProtocolEnum ReqRespPr = 4

  toProtocolEnum 4 = Just ReqRespPr
  toProtocolEnum _ = Nothing

instance Mx.MiniProtocolLimits TestProtocols2 where
  maximumMessageSize ReqRespPr  = defaultMiniProtocolLimit
  maximumIngressQueue ReqRespPr = defaultMiniProtocolLimit

anonymousPipesDemo :: forall block .
        ( Chain.HasHeader block, Serialise (Chain.HeaderHash block), Serialise block, Eq block
        , Show block)
     => Chain block -> [ChainUpdate block block] -> IO Bool
anonymousPipesDemo chain0 updates = do
    (hndRead1, hndWrite1) <- createPipe
    (hndRead2, hndWrite2) <- createPipe
    b1 <- Mx.pipeAsMuxBearer hndRead1 hndWrite2
    b2 <- Mx.pipeAsMuxBearer hndRead2 hndWrite1
    demo b1 b2 chain0 updates

#if defined(mingw32_HOST_OS)

_clientName :: String
_clientName = "\\\\.\\pipe\\named-client"

_serverName :: String
_serverName = "\\\\.\\pipe\\named-server"

_prop_namedpipe_demo :: Positive Int -> TestBlockChainAndUpdates -> Property
_prop_namedpipe_demo (Positive sn) (TestBlockChainAndUpdates chain updates) =
    ioProperty $ _namedPipesDemo sn chain updates

_namedPipesDemo :: forall block .
        ( Chain.HasHeader block, Serialise (Chain.HeaderHash block), Serialise block, Eq block
        , Show block)
     => Int -> Chain block -> [ChainUpdate block block] -> IO Bool
_namedPipesDemo x chain0 updates = do
    let client = Snocket.namedPipeSnocket _clientName (_serverName ++ show x)
        server = Snocket.namedPipeSnocket (_serverName ++ show x) _clientName

    !s <- Snocket.createServer server
    c <- Snocket.createClient client
    (as,n) <- Snocket.accept server s
    printf "connected with %s\n" $ show n
    b1 <- Snocket.toBearer client c
    b2 <- Snocket.toBearer server as
    r <- demo b1 b2 chain0 updates
    Snocket.close server s
    Snocket.close client c
    Snocket.close server as
    return r

_prop_pipe_send_recv :: (Int -> Int -> (Int, Int))
                      -> [Int]
                      -> Property
_prop_pipe_send_recv f xs = ioProperty $ do
    cv <- newEmptyTMVarM
    sv <- newEmptyTMVarM
    tbl <- newConnectionTable
    printf "testing with function %s\n" (show f)

    {- The siblingVar is used by the initiator and responder to wait on each other before exiting.
     - Without this wait there is a risk that one side will finish first causing the Muxbearer to
     - be torn down and the other side exiting before it has a chance to write to its result TMVar.
     -}
    siblingVar <- newTVarM 2

    let -- Server Node; only req-resp server
        responderApp :: OuroborosApplication ResponderApp () TestProtocols2 IO BL.ByteString Void ()
        responderApp = OuroborosResponderApplication $
          \peerid ReqRespPr channel -> do
            r <- runPeer nullTracer
                         ReqResp.codecReqResp
                         peerid
                         channel
                         (ReqResp.reqRespServerPeer (ReqResp.reqRespServerMapAccumL (\a -> pure . f a) 0))
            atomically $ putTMVar sv r
            waitSibling siblingVar
            printf "responder done\n"

        -- Client Node; only req-resp client
        initiatorApp :: OuroborosApplication InitiatorApp () TestProtocols2 IO BL.ByteString () Void
        initiatorApp = OuroborosInitiatorApplication $
          \peerid ReqRespPr channel -> do
            r <- runPeer nullTracer
                         ReqResp.codecReqResp
                         peerid
                         channel
                         (ReqResp.reqRespClientPeer (ReqResp.reqRespClientMap xs))
            atomically $ putTMVar cv r
            waitSibling siblingVar
            printf "initiator done\n"

    res <-
      withSimpleServerNode
        tbl
        (Snocket.namedPipeSnocket _serverName _clientName)
        _serverName
        (\(DictVersion codec) -> encodeTerm codec)
        (\(DictVersion codec) -> decodeTerm codec)
        (\_ _ -> ())
        (\(DictVersion _) -> acceptEq)
        (simpleSingletonVersions NodeToNodeV_1 (NodeToNodeVersionData 0) (DictVersion nodeToNodeCodecCBORTerm) responderApp)
        $ \_ _ -> do
          connectToNode
            (Snocket.namedPipeSnocket _clientName _serverName)
            (\(DictVersion codec) -> encodeTerm codec)
            (\(DictVersion codec) -> decodeTerm codec)
            nullTracer
            (\_ _ -> ())
            (simpleSingletonVersions NodeToNodeV_1 (NodeToNodeVersionData 0) (DictVersion nodeToNodeCodecCBORTerm) initiatorApp)
            (Just _clientName)
            _serverName
          printf "ready to take MVars\n"
          !r <- atomically $ (,) <$> takeTMVar sv <*> takeTMVar cv
          printf "mvars taken %s\n" (show r)
          return r

    printf "test case done\n"

    return (res == mapAccumL f 0 xs)

  where
    waitSibling :: TVar IO Int -> IO ()
    waitSibling cntVar = do
        atomically $ modifyTVar' cntVar (\a -> a - 1)
        atomically $ do
            cnt <- readTVar cntVar
            unless (cnt == 0) retry

#endif

-- | A demonstration that we can run the simple chain consumer protocol
-- over a pipe with full message serialisation, framing etc.
--
demo :: forall block .
        ( Chain.HasHeader block
        , Serialise (Chain.HeaderHash block)
        , Serialise block, Eq block
        , Show block
        )
     => MuxBearer DemoProtocols IO -> MuxBearer DemoProtocols IO -> Chain block -> [ChainUpdate block block] -> IO Bool
demo b1 b2 chain0 updates = do

    producerVar <- atomically $ newTVar (CPS.initChainProducerState chain0)
    consumerVar <- atomically $ newTVar chain0
    done <- atomically newEmptyTMVar

    let Just expectedChain = Chain.applyChainUpdates updates chain0
        target = Chain.headPoint expectedChain

        consumerApp :: OuroborosApplication InitiatorApp String DemoProtocols IO BL.ByteString () Void
        consumerApp = simpleInitiatorApplication $
          \ChainSync ->
            MuxPeer nullTracer
                    (ChainSync.codecChainSync encode (fmap const decode) encode decode)
                    (ChainSync.chainSyncClientPeer
                      (ChainSync.chainSyncClientExample consumerVar
                      (consumerClient done target consumerVar)))

        server :: ChainSyncServer block (Point block) IO ()
        server = ChainSync.chainSyncServerExample () producerVar

        producerApp ::OuroborosApplication ResponderApp String DemoProtocols IO BL.ByteString Void ()
        producerApp = simpleResponderApplication $
          \ChainSync ->
            MuxPeer nullTracer
                    (ChainSync.codecChainSync encode (fmap const decode) encode decode)
                    (ChainSync.chainSyncServerPeer server)

    _ <- async $ Mx.muxStart "producer" (toApplication producerApp) b1
    _ <- async $ Mx.muxStart "consumer" (toApplication consumerApp) b2

    void $ fork $ sequence_
        [ do threadDelay 10e-4 -- 1 milliseconds, just to provide interest
             atomically $ do
                 p <- readTVar producerVar
                 let Just p' = CPS.applyChainUpdate update p
                 writeTVar producerVar p'
             | update <- updates
        ]

    atomically $ takeTMVar done

  where
    checkTip target consumerVar = atomically $ do
      chain <- readTVar consumerVar
      return (Chain.headPoint chain == target)

    -- A simple chain-sync client which runs until it recieves an update to
    -- a given point (either as a roll forward or as a roll backward).
    consumerClient :: TMVar IO Bool
                   -> Point block
                   -> TVar IO (Chain block)
                   -> ChainSync.Client block IO ()
    consumerClient done target chain =
      ChainSync.Client
        { ChainSync.rollforward = \_ -> checkTip target chain >>= \b ->
            if b then do
                    atomically $ putTMVar done True
                    pure $ Left ()
                 else
                    pure $ Right $ consumerClient done target chain
        , ChainSync.rollbackward = \_ _ -> checkTip target chain >>= \b ->
            if b then do
                    atomically $ putTMVar done True
                    pure $ Left ()
                 else
                    pure $ Right $ consumerClient done target chain
        , ChainSync.points = \_ -> pure $ consumerClient done target chain
        }
