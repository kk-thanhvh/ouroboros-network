{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE BlockArguments      #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
module Analysis (
    AnalysisEnv (..)
  , AnalysisName (..)
  , Limit (..)
  , runAnalysis
  ) where

import           Codec.CBOR.Encoding (Encoding)
import           Control.Monad.Except
import           Data.List (intercalate)
import qualified Data.Map.Strict as Map
import           Data.Word (Word16, Word64)
import           NoThunks.Class (noThunks)

import           Ouroboros.Consensus.Block
import           Ouroboros.Consensus.Config
import           Ouroboros.Consensus.HeaderValidation (HasAnnTip (..),
                     HeaderState (..), annTipPoint)
import           Ouroboros.Consensus.Ledger.Abstract (tickThenApplyLedgerResult)
import           Ouroboros.Consensus.Ledger.Basics (LedgerResult (..))
import           Ouroboros.Consensus.Ledger.Extended
import           Ouroboros.Consensus.Ledger.SupportsProtocol
                     (LedgerSupportsProtocol (..))
import           Ouroboros.Consensus.Storage.Common (BlockComponent (..),
                     StreamFrom (..))
import           Ouroboros.Consensus.Storage.FS.API (SomeHasFS (..))
import           Ouroboros.Consensus.Util.ResourceRegistry


import           Ouroboros.Consensus.Storage.ChainDB (ChainDB)
import qualified Ouroboros.Consensus.Storage.ChainDB as ChainDB
import           Ouroboros.Consensus.Storage.ChainDB.Impl.LgrDB
                     (LgrDbSerialiseConstraints)
import           Ouroboros.Consensus.Storage.ImmutableDB (ImmutableDB)
import qualified Ouroboros.Consensus.Storage.ImmutableDB as ImmutableDB
import           Ouroboros.Consensus.Storage.LedgerDB.OnDisk (DiskSnapshot (..),
                     writeSnapshot)
import           Ouroboros.Consensus.Storage.Serialisation (SizeInBytes,
                     encodeDisk)

import           HasAnalysis (HasAnalysis)
import qualified HasAnalysis

{-------------------------------------------------------------------------------
  Run the requested analysis
-------------------------------------------------------------------------------}

data AnalysisName =
    ShowSlotBlockNo
  | CountTxOutputs
  | ShowBlockHeaderSize
  | ShowBlockTxsSize
  | ShowEBBs
  | OnlyValidation
  | StoreLedgerStateAt SlotNo
  | CheckNoThunksEvery Word64
  deriving Show

runAnalysis ::
     forall blk .
     ( LgrDbSerialiseConstraints blk
     , HasAnalysis blk
     , LedgerSupportsProtocol blk
     )
  => AnalysisName -> Analysis blk
runAnalysis ShowSlotBlockNo             = showSlotBlockNo
runAnalysis CountTxOutputs              = countTxOutputs
runAnalysis ShowBlockHeaderSize         = showHeaderSize
runAnalysis ShowBlockTxsSize            = showBlockTxsSize
runAnalysis ShowEBBs                    = showEBBs
runAnalysis OnlyValidation              = \_ -> return ()
runAnalysis (StoreLedgerStateAt slotNo) = storeLedgerStateAt slotNo
runAnalysis (CheckNoThunksEvery nBks)   = checkNoThunksEvery nBks

type Analysis blk = AnalysisEnv blk -> IO ()

data AnalysisEnv blk = AnalysisEnv {
      cfg        :: TopLevelConfig blk
    , initLedger :: ExtLedgerState blk
    , db         :: Either (ImmutableDB IO blk) (ChainDB IO blk)
    , registry   :: ResourceRegistry IO
    , ledgerDbFS :: SomeHasFS IO
    , limit      :: Limit
    }

{-------------------------------------------------------------------------------
  Analysis: show block and slot number for all blocks
-------------------------------------------------------------------------------}

showSlotBlockNo :: forall blk. HasAnalysis blk => Analysis blk
showSlotBlockNo AnalysisEnv { db, registry, initLedger, limit } =
    processAll_ db registry GetHeader initLedger limit process
  where
    process :: Header blk -> IO ()
    process hdr = putStrLn $ intercalate "\t" [
        show (blockNo   hdr)
      , show (blockSlot hdr)
      ]

{-------------------------------------------------------------------------------
  Analysis: show total number of tx outputs per block
-------------------------------------------------------------------------------}

countTxOutputs :: forall blk. HasAnalysis blk => Analysis blk
countTxOutputs AnalysisEnv { db, registry, initLedger, limit } = do
    void $ processAll db registry GetBlock initLedger limit 0 process
  where
    process :: Int -> blk -> IO Int
    process cumulative blk = do
        let cumulative' = cumulative + count
        putStrLn $ intercalate "\t" [
            show slotNo
          , show count
          , show cumulative'
          ]
        return cumulative'
      where
        count = HasAnalysis.countTxOutputs blk
        slotNo = blockSlot blk

{-------------------------------------------------------------------------------
  Analysis: show the header size in bytes for all blocks
-------------------------------------------------------------------------------}

showHeaderSize :: forall blk. HasAnalysis blk => Analysis blk
showHeaderSize AnalysisEnv { db, registry, initLedger, limit } = do
    maxHeaderSize <-
      processAll db registry ((,) <$> GetSlot <*> GetHeaderSize) initLedger limit 0 process
    putStrLn ("Maximum encountered header size = " <> show maxHeaderSize)
  where
    process :: Word16 -> (SlotNo, Word16) -> IO Word16
    process maxHeaderSize (slotNo, headerSize) = do
        putStrLn $ intercalate "\t" [
            show slotNo
          , "Header size = " <> show headerSize
          ]
        return $ maxHeaderSize `max` headerSize

{-------------------------------------------------------------------------------
  Analysis: show the total transaction sizes in bytes per block
-------------------------------------------------------------------------------}

showBlockTxsSize :: forall blk. HasAnalysis blk => Analysis blk
showBlockTxsSize AnalysisEnv { db, registry, initLedger, limit } =
    processAll_ db registry GetBlock initLedger limit process
  where
    process :: blk -> IO ()
    process blk = putStrLn $ intercalate "\t" [
          show (blockSlot blk)
        , "Num txs in block = " <> show numBlockTxs
        , "Total size of txs in block = " <> show blockTxsSize
        ]
      where
        txSizes :: [SizeInBytes]
        txSizes = HasAnalysis.blockTxSizes blk

        numBlockTxs :: Int
        numBlockTxs = length txSizes

        blockTxsSize :: SizeInBytes
        blockTxsSize = sum txSizes

{-------------------------------------------------------------------------------
  Analysis: show EBBs and their predecessors
-------------------------------------------------------------------------------}

showEBBs :: forall blk. HasAnalysis blk => Analysis blk
showEBBs AnalysisEnv { db, registry, initLedger, limit } = do
    putStrLn "EBB\tPrev\tKnown"
    processAll_ db registry GetBlock initLedger limit process
  where
    process :: blk -> IO ()
    process blk =
        case blockIsEBB blk of
          Just _epoch ->
            putStrLn $ intercalate "\t" [
                show (blockHash blk)
              , show (blockPrevHash blk)
              , show (    Map.lookup
                            (blockHash blk)
                            (HasAnalysis.knownEBBs (Proxy @blk))
                       == Just (blockPrevHash blk)
                     )
              ]
          _otherwise ->
            return () -- Skip regular blocks

{-------------------------------------------------------------------------------
  Analysis: store a ledger at specific slot
-------------------------------------------------------------------------------}

storeLedgerStateAt ::
     forall blk .
     ( LgrDbSerialiseConstraints blk
     , HasAnalysis blk
     , LedgerSupportsProtocol blk
     )
  => SlotNo -> Analysis blk
storeLedgerStateAt slotNo (AnalysisEnv { db, registry, initLedger, cfg, limit, ledgerDbFS }) = do
    putStrLn $ "About to store snapshot of a ledger at " <>
               show slotNo <> " " <>
               "this might take a while..."
    void $ processAll db registry GetBlock initLedger limit initLedger process
  where
    process :: ExtLedgerState blk -> blk -> IO (ExtLedgerState blk)
    process oldLedger blk = do
      let ledgerCfg     = ExtLedgerCfg cfg
          appliedResult = tickThenApplyLedgerResult ledgerCfg blk oldLedger
          newLedger     = either (error . show) lrResult $ runExcept $ appliedResult
      when (slotNo == blockSlot blk) $ storeLedgerState blk newLedger
      return newLedger

    storeLedgerState ::
         blk
      -> ExtLedgerState blk
      -> IO ()
    storeLedgerState blk ledgerState = do
      let snapshot = DiskSnapshot
                      (unSlotNo $ blockSlot blk)
                      (Just $ "db-analyser")
      writeSnapshot ledgerDbFS encLedger snapshot ledgerState
      putStrLn $ "storing state at " <> intercalate "\t" [
          show (blockNo   blk)
        , show (blockSlot blk)
        , show (blockHash blk)
        ]

    encLedger :: ExtLedgerState blk -> Encoding
    encLedger =
      let ccfg = configCodec cfg
      in encodeExtLedgerState
           (encodeDisk ccfg)
           (encodeDisk ccfg)
           (encodeDisk ccfg)

{-------------------------------------------------------------------------------
  Analysis: check for ledger state thunks every n blocks
-------------------------------------------------------------------------------}

checkNoThunksEvery ::
  forall blk.
  ( HasAnalysis blk,
    LedgerSupportsProtocol blk
  ) =>
  Word64 ->
  Analysis blk
checkNoThunksEvery
  nBlocks
  (AnalysisEnv {db, registry, initLedger, cfg, limit}) = do
    putStrLn $
      "Checking ledger state for thunks every "
        <> show nBlocks
        <> " blocks."
    void $ processAll db registry GetBlock initLedger limit initLedger process
  where
    process :: ExtLedgerState blk -> blk -> IO (ExtLedgerState blk)
    process oldLedger blk = do
      let ledgerCfg     = ExtLedgerCfg cfg
          appliedResult = tickThenApplyLedgerResult ledgerCfg blk oldLedger
          newLedger     = either (error . show) lrResult $ runExcept $ appliedResult
          bn            = blockNo blk
      when (unBlockNo bn `mod` nBlocks == 0 ) $ checkNoThunks bn newLedger
      return newLedger

    checkNoThunks :: BlockNo -> ExtLedgerState blk -> IO ()
    checkNoThunks bn ls =
      noThunks [] (ledgerState ls) >>= \case
        Nothing -> putStrLn $ "BlockNo " <> show bn <> ": no thunks found."
        Just ti -> do
          putStrLn $ "BlockNo " <> show bn <> ": thunks found."
          print ti

{-------------------------------------------------------------------------------
  Auxiliary: processing all blocks in the DB
-------------------------------------------------------------------------------}

data Limit = Limit Int | Unlimited

decreaseLimit :: Limit -> Maybe Limit
decreaseLimit Unlimited = Just Unlimited
decreaseLimit (Limit 0) = Nothing
decreaseLimit (Limit n) = Just . Limit $ n - 1

processAll ::
     forall blk b st. (HasHeader blk, HasAnnTip blk)
  => Either (ImmutableDB IO blk) (ChainDB IO blk)
  -> ResourceRegistry IO
  -> BlockComponent blk b
  -> ExtLedgerState blk
  -> Limit
  -> st
  -> (st -> b -> IO st)
  -> IO st
processAll = either processAllImmutableDB processAllChainDB

processAll_ ::
     forall blk b. (HasHeader blk, HasAnnTip blk)
  => Either (ImmutableDB IO blk) (ChainDB IO blk)
  -> ResourceRegistry IO
  -> BlockComponent blk b
  -> ExtLedgerState blk
  -> Limit
  -> (b -> IO ())
  -> IO ()
processAll_ db registery blockComponent initLedger limit callback =
    processAll db registery blockComponent initLedger limit () (const callback)

processAllChainDB ::
     forall st blk b. (HasHeader blk, HasAnnTip blk)
  => ChainDB IO blk
  -> ResourceRegistry IO
  -> BlockComponent blk b
  -> ExtLedgerState blk
  -> Limit
  -> st
  -> (st -> b -> IO st)
  -> IO st
processAllChainDB chainDB registery blockComponent (ExtLedgerState {..}) limit initState callback = do
    itr <- case headerStateTip headerState of
      Origin           -> ChainDB.streamAll
                             chainDB
                             registery
                             blockComponent
      NotOrigin annTip -> ChainDB.streamFrom
                             (StreamFromExclusive $ annTipPoint annTip)
                             chainDB
                             registery
                             blockComponent
    go itr limit initState
  where
    go :: ChainDB.Iterator IO blk b -> Limit -> st -> IO st
    go itr lt !st = case decreaseLimit lt of
      Nothing             -> return st
      Just decreasedLimit -> do
        itrResult <- ChainDB.iteratorNext itr
        case itrResult of
          ChainDB.IteratorExhausted    -> return st
          ChainDB.IteratorResult b     -> callback st b >>= go itr decreasedLimit
          ChainDB.IteratorBlockGCed pt -> error $ "block GC'ed " <> show pt

processAllImmutableDB ::
     forall st blk b. (HasHeader blk, HasAnnTip blk)
  => ImmutableDB IO blk
  -> ResourceRegistry IO
  -> BlockComponent blk b
  -> ExtLedgerState blk
  -> Limit
  -> st
  -> (st -> b -> IO st)
  -> IO st
processAllImmutableDB immutableDB registery blockComponent (ExtLedgerState {..}) limit initState callback = do
    itr <- case headerStateTip headerState of
      Origin           -> ImmutableDB.streamAll
                             immutableDB
                             registery
                             blockComponent
      NotOrigin annTip -> ImmutableDB.streamAfterKnownPoint
                             immutableDB
                             registery
                             blockComponent
                            (annTipPoint annTip)
    go itr limit initState
  where
    go :: ImmutableDB.Iterator IO blk b -> Limit -> st -> IO st
    go itr lt !st = case decreaseLimit lt of
      Nothing               -> return st
      Just decreasedLimit   -> do
        itrResult <- ImmutableDB.iteratorNext itr
        case itrResult of
          ImmutableDB.IteratorExhausted -> return st
          ImmutableDB.IteratorResult b  -> callback st b >>= go itr decreasedLimit
