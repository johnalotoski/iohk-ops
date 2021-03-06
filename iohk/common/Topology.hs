--  Imported from cardano-sl://infra/Pos/Network/Yaml.hs
--  with following modifications:
--
--  1. trimmed external dependencies
--  2. commented out some parts, mostly due to external dependencies
--  3. imported some external definitions (see the 'XXX: added code' section)
--
{-# LANGUAGE DeriveGeneric, GeneralizedNewtypeDeriving, OverloadedStrings, RecordWildCards, TupleSections #-}

-- | Infrastructure for parsing the .yaml network topology file
module Topology where

import           Data.Aeson             (FromJSON (..), ToJSON (..), (.!=),
                                         (.:), (.:?), (.=))
import qualified Data.Aeson             as A
import qualified Data.Aeson.Types       as A
import qualified Data.ByteString.Char8  as BS.C8
import qualified Data.HashMap.Lazy      as HM
import qualified Data.Map.Strict        as M
import qualified GHC.Generics           as G
-- import           Network.Broadcast.OutboundQueue.Types
import qualified Network.DNS            as DNS
-- import           Pos.Util.Config
-- import           Universum

-- import           Pos.Network.DnsDomains (DnsDomains (..), NodeAddr (..))


-- XXX: added code
--
import           Data.String
import           Data.Text
import           Data.Word

import           Types
--
-- XXX: end of added code

-- | Description of the network topology in a Yaml file
--
-- This differs from 'Pos.Network.Types.Topology' because for static nodes this
-- describes the entire network topology (all statically known nodes), not just
-- the topology from the point of view of the current node.
data Topology =
    TopologyStatic !AllStaticallyKnownPeers
  -- | TopologyBehindNAT !(DnsDomains (DNS.Domain))
  | TopologyP2P !Int !Int
  | TopologyTraditional !Int !Int
  deriving (Show)

-- | All statically known peers in the newtork
data AllStaticallyKnownPeers = AllStaticallyKnownPeers {
    allStaticallyKnownPeers :: !(M.Map NodeName NodeMetadata)
  }
  deriving (Show)

instance FromJSON NodeZone
instance ToJSON NodeZone

data NodeMetadata = NodeMetadata
    { -- | Node type
      nmType    :: !NodeType

      -- | Region
    , nmRegion  :: !NodeRegion

      -- | Static peers of this node
    , nmRoutes  :: !NodeRoutes

      -- | Address for this node
    , nmAddress :: !(NodeAddr (Maybe DNS.Domain))

      -- | Should the node register itself with the Kademlia network?
    , nmKademlia :: !RunKademlia

      -- | Should the node be set up for wallets
    , nmPublic :: !Bool

      -- | What organisation does the node belong to
    , nmOrg :: !(Maybe NodeOrg)

      -- | Availability zone
    , nmZone :: !NodeZone
    }
    deriving (Show)

-- | Parameters for Kademlia, in case P2P or traditional topology are used.
data KademliaParams = KademliaParams
    { kpId              :: !(Maybe KademliaId)
      -- ^ Kademlia identifier. Optional; one can be generated for you.
    , kpPeers           :: ![KademliaAddress]
      -- ^ Initial Kademlia peers, for joining the network.
    , kpAddress         :: !(Maybe KademliaAddress)
      -- ^ External Kadmelia address.
    , kpBind            :: !KademliaAddress
      -- ^ Address at which to bind the Kademlia socket.
      -- Shouldn't be necessary to have a separate bind and public address.
      -- The Kademlia instance in fact shouldn't even need to know its own
      -- address (should only be used to bind the socket). But due to the way
      -- that responses for FIND_NODES are serialized, Kademlia needs to know
      -- its own external address [TW-153]. The mainline 'kademlia' package
      -- doesn't suffer this problem.
    , kpExplicitInitial :: !Bool
    , kpDumpFile        :: !(Maybe FilePath)
    }
    deriving (Show)

instance FromJSON KademliaParams where
    parseJSON = A.withObject "KademliaParams" $ \obj -> do
        kpId <- obj .:? "identifier"
        kpPeers <- obj .: "peers"
        kpAddress <- obj .:? "externalAddress"
        kpBind <- obj .: "address"
        kpExplicitInitial <- obj .:? "explicitInitial" .!= False
        kpDumpFile <- obj .:? "dumpFile"
        return KademliaParams {..}

instance ToJSON KademliaParams where
    toJSON KademliaParams {..} = A.object [
          "identifier"      .= kpId
        , "peers"           .= kpPeers
        , "externalAddress" .= kpAddress
        , "address"         .= kpBind
        , "explicitInitial" .= kpExplicitInitial
        , "dumpFile"        .= kpDumpFile
        ]

-- | A Kademlia identifier in text representation (probably base64-url encoded).
newtype KademliaId = KademliaId String
    deriving (Show)

instance FromJSON KademliaId where
    parseJSON = fmap KademliaId . parseJSON

instance ToJSON KademliaId where
    toJSON (KademliaId txt) = toJSON txt

data KademliaAddress = KademliaAddress
    { kaHost :: !String
    , kaPort :: !Word16
    }
    deriving (Show)

instance FromJSON KademliaAddress where
    parseJSON = A.withObject "KademliaAddress " $ \obj ->
        KademliaAddress <$> obj .: "host" <*> obj .: "port"

instance ToJSON KademliaAddress where
    toJSON KademliaAddress {..} = A.object [
          "host" .= kaHost
        , "port" .= kaPort
        ]

{-------------------------------------------------------------------------------
  FromJSON instances
-------------------------------------------------------------------------------}

instance FromJSON NodeRegion where
  parseJSON = fmap NodeRegion . parseJSON

instance FromJSON NodeRoutes where
  parseJSON = fmap NodeRoutes . parseJSON

-- instance FromJSON (DnsDomains DNS.Domain) where
--   parseJSON = fmap DnsDomains . parseJSON

-- instance FromJSON (NodeAddr DNS.Domain) where
--   parseJSON = A.withObject "NodeAddr" $ extractNodeAddr aux
--     where
--       aux :: Maybe DNS.Domain -> A.Parser DNS.Domain
--       aux Nothing    = fail "Missing domain name or address"
--       aux (Just dom) = return dom

-- Useful when we have a 'NodeAddr' as part of a larger object
extractNodeAddr :: (Maybe DNS.Domain -> A.Parser a)
                -> A.Object
                -> A.Parser (NodeAddr a)
extractNodeAddr mkA obj = do
    mAddr <- obj .:? "addr"
    mHost <- obj .:? "host"
    mPort <- obj .:? "port"
    case (mAddr, mHost) of
      (Just addr, Nothing) -> return $ NodeAddrExact (aux addr) mPort
      (Nothing,  _)        -> do a <- mkA (aux <$> mHost)
                                 return $ NodeAddrDNS a mPort
      (Just _, Just _)     -> fail "Cannot use both 'addr' and 'host'"
  where
    aux :: String -> DNS.Domain
    aux = BS.C8.pack

instance FromJSON NodeMetadata where
  parseJSON = A.withObject "NodeMetadata" $ \obj -> do
      nmType     <- obj .: "type"
      nmRegion   <- obj .: "region"
      nmZone     <- obj .: "zone"
      nmRoutes   <- obj .:? "static-routes" .!= NodeRoutes []
      nmAddress  <- extractNodeAddr return obj
      nmKademlia <- obj .:? "kademlia" .!= defaultRunKademlia nmType
      nmOrg      <- obj .:? "org"
      nmPublic   <- obj .:? "public" .!= False
      return NodeMetadata{..}
   where
     defaultRunKademlia :: NodeType -> RunKademlia
     defaultRunKademlia NodeCore  = False
     defaultRunKademlia NodeRelay = True
     defaultRunKademlia NodeEdge  = False

instance FromJSON AllStaticallyKnownPeers where
  parseJSON = A.withObject "AllStaticallyKnownPeers" $ \obj ->
      AllStaticallyKnownPeers . M.fromList <$> mapM aux (HM.toList obj)
    where
      aux :: (Text, A.Value) -> A.Parser (NodeName, NodeMetadata)
      aux (name, val) = (NodeName name, ) <$> parseJSON val

instance FromJSON Topology where
  parseJSON = A.withObject "Topology" $ \obj -> do
      mNodes  <- obj .:? "nodes"
      case (mNodes, Nothing, Nothing) of
        (Just nodes, Nothing, Nothing) ->
            TopologyStatic <$> parseJSON nodes
        _ ->
          fail "Topology: expected to see 'nodes'"

-- instance IsConfig Topology where
--   configPrefix = return Nothing
