{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE NamedFieldPuns             #-}
{-# LANGUAGE StandaloneDeriving         #-}

-- | Reference implementation of a representation of a block in a block chain.
--
module Block (
      -- * Types
      Block (..)
    , BlockHeader(..)
    , BlockBody(..)
    , HasHeader(..)
    , Slot(..)
    , BlockNo(..)
    , BlockSigner(..)
    , HeaderHash(..)
    , BodyHash(..)

      -- * Hashing
    , hashHeader
    , hashBody
    )
    where

import           Data.Hashable
import qualified Data.Text as Text

import           Ouroboros
import           Serialise

import           Test.QuickCheck

-- | Our highly-simplified version of a block. It retains the separation
-- between a block header and body, which is a detail needed for the protocols.
--
data Block (p :: OuroborosProtocol) = Block {
       blockHeader :: BlockHeader p,
       blockBody   :: BlockBody
     }

deriving instance Show (Block p)
deriving instance Eq   (Block p)

-- | A block header. It retains simplified versions of all the essential
-- elements.
--
data BlockHeader (p :: OuroborosProtocol) = BlockHeader {
       headerHash     :: HeaderHash,  -- ^ The cached 'HeaderHash' of this header.
       headerPrevHash :: HeaderHash,  -- ^ The 'headerHash' of the previous block header
       headerSlot     :: Slot,        -- ^ The Ouroboros time slot index of this block
       headerBlockNo  :: BlockNo,     -- ^ The block index from the Genesis
       headerSigner   :: BlockSigner, -- ^ Who signed this block
       headerBodyHash :: BodyHash     -- ^ The hash of the corresponding block body
     }

deriving instance Show (BlockHeader p)
deriving instance Eq   (BlockHeader p)

-- | A block body.
--
-- For this model we use an opaque string as we do not care about the content
-- because we focus on the blockchain layer (rather than the ledger layer).
--
newtype BlockBody    = BlockBody String
  deriving (Show, Eq, Ord)

-- | The 0-based index of the block in the blockchain
newtype BlockNo      = BlockNo Word
  deriving (Show, Eq, Ord, Hashable, Enum)

-- | An identifier for someone signing a block.
--
-- We model this as if there were an enumerated set of valid block signers
-- (which for Ouroboros BFT is actually the case), and omit the cryptography
-- and model things as if the signatures were valid.
--
newtype BlockSigner  = BlockSigner Word
  deriving (Show, Eq, Ord, Hashable)

-- | The hash of all the information in a 'BlockHeader'.
--
newtype HeaderHash   = HeaderHash Int
  deriving (Show, Eq, Ord, Hashable)

-- | The hash of all the information in a 'BlockBody'.
--
newtype BodyHash     = BodyHash Int
  deriving (Show, Eq, Ord, Hashable)

-- | Compute the 'BodyHash' of the 'BlockBody'
--
hashBody :: BlockBody -> BodyHash
hashBody (BlockBody b) = BodyHash (hash b)

-- | Compute the 'HeaderHash' of the 'BlockHeader'.
--
hashHeader :: BlockHeader p -> HeaderHash
hashHeader (BlockHeader _ b c d e f) = HeaderHash (hash (b, c, d, e, f))

--
-- Class to help us treat blocks and headers similarly
--

-- | This class lets us treat chains of block headers and chains of whole
-- blocks in a parametrised way.
--
class HasHeader (b :: OuroborosProtocol -> *) where
    blockHash      :: b p -> HeaderHash
    blockPrevHash  :: b p -> HeaderHash
    blockSlot      :: b p -> Slot
    blockNo        :: b p -> BlockNo
    blockSigner    :: b p -> BlockSigner
    blockBodyHash  :: b p -> BodyHash

    blockInvariant :: b p -> Bool

instance HasHeader BlockHeader where
    blockHash      = headerHash
    blockPrevHash  = headerPrevHash
    blockSlot      = headerSlot
    blockNo        = headerBlockNo
    blockSigner    = headerSigner
    blockBodyHash  = headerBodyHash

    -- | The header invariant is that the cached header hash is correct.
    --
    blockInvariant = \b -> hashHeader b == headerHash b

instance HasHeader Block where
    blockHash      = headerHash     . blockHeader
    blockPrevHash  = headerPrevHash . blockHeader
    blockSlot      = headerSlot     . blockHeader
    blockNo        = headerBlockNo  . blockHeader
    blockSigner    = headerSigner   . blockHeader
    blockBodyHash  = headerBodyHash . blockHeader

    -- | The block invariant is just that the actual block body hash matches the
    -- body hash listed in the header.
    --
    blockInvariant Block { blockBody, blockHeader = BlockHeader {headerBodyHash} } =
        headerBodyHash == hashBody blockBody

--
-- Generators
--

instance Arbitrary BlockBody where
    arbitrary = BlockBody <$> vectorOf 4 (choose ('A', 'Z'))
    -- probably no need for shrink, the content is arbitrary and opaque
    -- if we add one, it might be to shrink to an empty block

--
-- Serialisation
--

instance Serialise (Block p) where

  encode Block {blockHeader, blockBody} =
      encodeListLen 2
   <> encode blockHeader
   <> encode   blockBody

  decode = do
      decodeListLenOf 2
      Block <$> decode <*> decode

instance Serialise (BlockHeader p) where

  encode BlockHeader {
         headerHash     = HeaderHash headerHash,
         headerPrevHash = HeaderHash headerPrevHash,
         headerSlot     = Slot headerSlot,
         headerBlockNo  = BlockNo headerBlockNo,
         headerSigner   = BlockSigner headerSigner,
         headerBodyHash = BodyHash headerBodyHash
       } =
      encodeListLen 6
   <> encodeInt  headerHash
   <> encodeInt  headerPrevHash
   <> encodeWord headerSlot
   <> encodeWord headerBlockNo
   <> encodeWord headerSigner
   <> encodeInt  headerBodyHash

  decode = do
      decodeListLenOf 6
      BlockHeader <$> (HeaderHash <$> decodeInt)
                  <*> (HeaderHash <$> decodeInt)
                  <*> (Slot <$> decodeWord)
                  <*> (BlockNo <$> decodeWord)
                  <*> (BlockSigner <$> decodeWord)
                  <*> (BodyHash <$> decodeInt)

instance Serialise BlockBody where

  encode (BlockBody b) = encodeString (Text.pack b)

  decode = BlockBody . Text.unpack <$> decodeString
