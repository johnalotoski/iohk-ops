{-# OPTIONS_GHC -Wall -Wno-orphans -Wno-missing-signatures -Wno-unticked-promoted-constructors -Wno-type-defaults #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE ViewPatterns #-}

module NixOps where

import           Control.Exception                (throwIO)
import           Control.Lens                     ((<&>))
import           Control.Monad                    (forM_)
import qualified Data.Aeson                    as AE
import           Data.Aeson                       ((.:), (.:?), (.=), (.!=))
import qualified Data.Aeson.Types              as AE
import           Data.Aeson.Encode.Pretty         (encodePretty)
import qualified Data.ByteString.Lazy          as BL
import           Data.ByteString.Lazy.Char8       (ByteString)
import qualified Data.ByteString.UTF8          as BU
import qualified Data.ByteString.Lazy.UTF8     as LBU
import           Data.Char                        (ord, toLower)
import           Data.Csv                         (decodeWith, FromRecord(..), FromField(..), HasHeader(..), defaultDecodeOptions, decDelimiter)
import           Data.Either
import           Data.Hourglass                   (timeAdd, timeFromElapsed, timePrint, Duration(..), ISO8601_DateAndTime(..))
import           Data.List                        (sort)
import           Data.Maybe
import qualified Data.Map.Strict               as Map
import           Data.Monoid                      ((<>))
import qualified Data.Set                      as Set
import qualified Data.Text                     as T
import qualified Data.Text.IO                  as TIO
import           Data.Text.Lazy                   (fromStrict)
import           Data.Text.Lazy.Encoding          (encodeUtf8)
import qualified Data.Vector                   as V
import qualified Data.Yaml                     as YAML
import           Data.Yaml                        (FromJSON(..), ToJSON(..))
import qualified Filesystem.Path.CurrentOS     as Path
import           GHC.Generics              hiding (from, to)
import           Prelude                   hiding (FilePath)
import           Safe                             (headMay)
import qualified System.IO                     as Sys
import           Time.System
import           Time.Types
import           Turtle                    hiding (env, err, fold, inproc, prefix, procs, e, f, o, x)
import qualified Turtle                        as Turtle


import           Topology


-- * Constants
--
awsPublicIPURL :: URL
awsPublicIPURL = "http://169.254.169.254/latest/meta-data/public-ipv4"

defaultEnvironment   = Development
defaultTarget        = AWS
defaultNode          = NodeName "c-a-1"
defaultNodePort      = PortNo 3000
defaultNixpkgs       = Commit "9b948ea439ddbaa26740ce35543e7e35d2aa6d18"

defaultHold          = 1200 :: Seconds -- 20 minutes


-- * Projects
--
data Project
  = CardanoSL
  | IOHK
  | Nixpkgs
  | Stack2nix
  | Nixops
  deriving (Bounded, Enum, Eq, Read, Show)

every :: (Bounded a, Enum a) => [a]
every = enumFromTo minBound maxBound

projectURL     :: Project -> URL
projectURL     CardanoSL       = "https://github.com/input-output-hk/cardano-sl.git"
projectURL     IOHK            = "https://github.com/input-output-hk/iohk-nixops.git"
projectURL     Nixpkgs         = "https://github.com/nixos/nixpkgs.git"
projectURL     Stack2nix       = "https://github.com/input-output-hk/stack2nix.git"
projectURL     Nixops          = "https://github.com/input-output-hk/nixops.git"

projectSrcFile :: Project -> FilePath
projectSrcFile CardanoSL       = "cardano-sl-src.json"
projectSrcFile Nixpkgs         = "nixpkgs-src.json"
projectSrcFile Stack2nix       = "stack2nix-src.json"
projectSrcFile IOHK            = error "Feeling self-referential?"
projectSrcFile Nixops          = error "No corresponding -src.json spec for 'nixops' yet."


-- * Primitive types
--
newtype Branch       = Branch       { fromBranch       :: Text   } deriving (FromJSON, Generic, Show, IsString)
newtype Commit       = Commit       { fromCommit       :: Text   } deriving (FromJSON, Generic, Show, IsString, ToJSON)
newtype NixParam     = NixParam     { fromNixParam     :: Text   } deriving (FromJSON, Generic, Show, IsString, Eq, Ord, AE.ToJSONKey, AE.FromJSONKey)
newtype NixHash      = NixHash      { fromNixHash      :: Text   } deriving (FromJSON, Generic, Show, IsString, ToJSON)
newtype NixAttr      = NixAttr      { fromAttr         :: Text   } deriving (FromJSON, Generic, Show, IsString)
newtype NixopsCmd    = NixopsCmd    { fromCmd          :: Text   } deriving (FromJSON, Generic, Show, IsString)
newtype Region       = Region       { fromRegion       :: Text   } deriving (FromJSON, Generic, Show, IsString)
newtype URL          = URL          { fromURL          :: Text   } deriving (FromJSON, Generic, Show, IsString, ToJSON)
newtype FQDN         = FQDN         { fromFQDN         :: Text   } deriving (FromJSON, Generic, Show, IsString, ToJSON)
newtype IP           = IP           { getIP            :: Text   } deriving (Show, Generic, FromField)
newtype PortNo       = PortNo       { fromPortNo       :: Int    } deriving (FromJSON, Generic, Show, ToJSON)
newtype Exec         = Exec         { fromExec         :: Text   } deriving (IsString, Show)
newtype Arg          = Arg          { fromArg          :: Text   } deriving (IsString, Show)

deriving instance Eq NodeType
deriving instance Read NodeName
deriving instance AE.ToJSONKey NodeName
fromNodeName :: NodeName -> Text
fromNodeName (NodeName x) = x


-- * Some orphan instances..
--
instance FromJSON FilePath where parseJSON = AE.withText "filepath" $ \v -> pure $ fromText v
instance ToJSON   FilePath where toJSON    = AE.String . format fp
deriving instance Generic Seconds; instance FromJSON Seconds; instance ToJSON Seconds
deriving instance Generic Elapsed; instance FromJSON Elapsed; instance ToJSON Elapsed


-- * A bit of Nix types
--
data SourceKind = Git | Github

data NixSource (a :: SourceKind) where
  -- | The output of 'nix-prefetch-git'
  GitSource ::
    { gUrl             :: URL
    , gRev             :: Commit
    , gSha256          :: NixHash
    , gFetchSubmodules :: Bool
    } -> NixSource Git
  GithubSource ::
    { ghOwner           :: Text
    , ghRepo            :: Text
    , ghRev             :: Commit
    , ghSha256          :: NixHash
    } -> NixSource Github
deriving instance Show (NixSource a)
instance FromJSON (NixSource Git) where
  parseJSON = AE.withObject "GitSource" $ \v -> GitSource
      <$> v .: "url"
      <*> v .: "rev"
      <*> v .: "sha256"
      <*> v .: "fetchSubmodules"
instance FromJSON (NixSource Github) where
  parseJSON = AE.withObject "GithubSource" $ \v -> GithubSource
      <$> v .: "owner"
      <*> v .: "repo"
      <*> v .: "rev"
      <*> v .: "sha256"

githubSource :: ByteString -> Maybe (NixSource Github)
githubSource = AE.decode
gitSource    :: ByteString -> Maybe (NixSource Git)
gitSource    = AE.decode

readSource :: (ByteString -> Maybe (NixSource a)) -> Project -> IO (NixSource a)
readSource parser (projectSrcFile -> path) =
  (fromMaybe (errorT $ format ("File doesn't parse as NixSource: "%fp) path) . parser)
  <$> BL.readFile (T.unpack $ format fp path)

nixpkgsNixosURL :: Commit -> URL
nixpkgsNixosURL (Commit rev) = URL $
  "https://github.com/NixOS/nixpkgs/archive/" <> rev <> ".tar.gz"

-- | The set of first-class types present in Nix
data NixValue
  = NixBool Bool
  | NixInt  Integer
  | NixStr  Text
  | NixFile FilePath
  deriving (Generic, Show)
instance FromJSON NixValue
instance ToJSON NixValue

nixValueStr :: NixValue -> Text
nixValueStr (NixBool bool) = T.toLower $ showT bool
nixValueStr (NixInt  int)  = showT int
nixValueStr (NixStr  str)  = str
nixValueStr (NixFile f)    = let txt = format fp f
                             in if T.isPrefixOf "/" txt
                                then txt else ("./" <> txt)

nixArgCmdline :: NixParam -> NixValue -> [Text]
nixArgCmdline (NixParam name) x@(NixBool _) = ["--arg",    name, nixValueStr x]
nixArgCmdline (NixParam name) x@(NixInt  _) = ["--arg",    name, nixValueStr x]
nixArgCmdline (NixParam name) x@(NixStr  _) = ["--argstr", name, nixValueStr x]
nixArgCmdline (NixParam name) x@(NixFile _) = ["--arg",    name, nixValueStr x]


-- * Domain
--
data Deployment
  = Explorer
  | Nodes
  | Infra
  | ReportServer
  | Timewarp
  deriving (Bounded, Eq, Enum, Generic, Read, Show)
instance FromJSON Deployment

data Environment
  = Any               -- ^ Wildcard or unspecified, depending on context.
  | Production
  | Staging
  | Development
  deriving (Bounded, Eq, Enum, Generic, Read, Show)
instance FromJSON Environment

data Target
  = All               -- ^ Wildcard or unspecified, depending on context.
  | AWS
  deriving (Bounded, Eq, Enum, Generic, Read, Show)
instance FromJSON Target

envConfigFilename :: IsString s => Environment -> s
envConfigFilename Any           = "config.yaml"
envConfigFilename Development   = "config.yaml"
envConfigFilename Staging       = "staging.yaml"
envConfigFilename Production    = "production.yaml"

selectDeployer :: Environment -> [Deployment] -> NodeName
selectDeployer Staging delts | elem Nodes delts = "iohk"
                             | otherwise        = "cardano-deployer"
selectDeployer _ _                              = "cardano-deployer"

selectTopologyConfig :: Environment -> [Deployment] -> FilePath
selectTopologyConfig Development _ = "topology-development.yaml"
selectTopologyConfig Staging     _ = "topology-staging.yaml"
selectTopologyConfig _           _ = "topology.yaml"

deployerIP :: Options -> IO IP
deployerIP o = IP <$> incmd o "curl" ["--silent", fromURL awsPublicIPURL]


-- * Topology
--
readTopology :: FilePath -> IO Topology
readTopology file = do
  eTopo <- liftIO $ YAML.decodeFileEither $ Path.encodeString file
  case eTopo of
    Right (topology :: Topology) -> pure topology
    Left err -> errorT $ format ("Failed to parse topology file: "%fp%": "%w) file err

data SimpleTopo
  =  SimpleTopo (Map.Map NodeName SimpleNode)
  deriving (Generic, Show)
instance ToJSON SimpleTopo
data SimpleNode
  =  SimpleNode
     { snType     :: NodeType
     , snRegion   :: NodeRegion
     , snFQDN     :: FQDN
     , snPort     :: PortNo
     , snInPeers  :: [NodeName]                  -- ^ Incoming connection edges
     , snKademlia :: RunKademlia
     } deriving (Generic, Show)
instance ToJSON SimpleNode where-- toJSON = jsonLowerStrip 2
  toJSON SimpleNode{..} = AE.object
   [ "type"        .= (lowerShowT snType & T.stripPrefix "node"
                        & fromMaybe (error "A NodeType constructor gone mad: doesn't start with 'Node'."))
   , "address"     .= fromFQDN snFQDN
   , "port"        .= fromPortNo snPort
   , "peers"       .= snInPeers
   , "region"      .= snRegion
   , "kademlia"    .= snKademlia ]
instance ToJSON NodeRegion
instance ToJSON NodeName
deriving instance Generic NodeName
deriving instance Generic NodeRegion
deriving instance Generic NodeType
instance ToJSON NodeType

topoNodes :: SimpleTopo -> [NodeName]
topoNodes (SimpleTopo cmap) = Map.keys cmap

topoNCores :: SimpleTopo -> Int
topoNCores (SimpleTopo cmap) = Map.size $ flip Map.filter cmap ((== NodeCore) . snType)

summariseTopology :: Topology -> SimpleTopo
summariseTopology (TopologyStatic (AllStaticallyKnownPeers nodeMap)) =
  SimpleTopo $ Map.mapWithKey simplifier nodeMap
  where simplifier node (NodeMetadata snType snRegion (NodeRoutes outRoutes) nmAddr snKademlia) =
          SimpleNode{..}
          where (mPort,  fqdn)   = case nmAddr of
                                     (NodeAddrExact fqdn'  mPort') -> (mPort', fqdn') -- (Ok, bizarrely, this contains FQDNs, even if, well.. : -)
                                     (NodeAddrDNS   mFqdn  mPort') -> (mPort', flip fromMaybe mFqdn
                                                                      $ error "Cannot deploy a topology with nodes lacking a FQDN address.")
                (snPort, snFQDN) = (,) (fromMaybe defaultNodePort $ PortNo . fromIntegral <$> mPort)
                                   $ (FQDN . T.pack . BU.toString) $ fqdn
                snInPeers = Set.toList . Set.fromList
                            $ [ other
                            | (other, (NodeMetadata _ _ (NodeRoutes routes) _ _)) <- Map.toList nodeMap
                            , elem node (concat routes) ]
                            <> concat outRoutes
summariseTopology x = errorT $ format ("Unsupported topology type: "%w) x

dumpTopologyNix :: FilePath -> IO ()
dumpTopologyNix topo = sh $ do
  let nodeSpecExpr prefix =
        format ("with (import <nixpkgs> {}); "%s%" (import deployments/cardano-nodes-config.nix { accessKeyId = \"\"; deployerIP = \"\"; topologyFile = "%fp%"; systemStart = 0; })")
               prefix topo
      getNodeArgsAttr prefix attr = inproc "nix-instantiate" ["--strict", "--show-trace", "--eval" ,"-E", nodeSpecExpr prefix <> "." <> attr] empty
      liftNixList = inproc "sed" ["s/\" \"/\", \"/g"]
  (cores  :: [NodeName]) <- getNodeArgsAttr "map (x: x.name)" "cores"  & liftNixList <&> ((NodeName <$>) . readT . lineToText)
  (relays :: [NodeName]) <- getNodeArgsAttr "map (x: x.name)" "relays" & liftNixList <&> ((NodeName <$>) . readT . lineToText)
  echo "Cores:"
  forM_ cores  $ \(NodeName x) -> do
    printf ("  "%s%"\n    ") x
    Turtle.proc "nix-instantiate" ["--strict", "--show-trace", "--eval" ,"-E", nodeSpecExpr "" <> ".nodeArgs." <> x] empty
  echo "Relays:"
  forM_ relays $ \(NodeName x) -> do
    printf ("  "%s%"\n    ") x
    Turtle.proc "nix-instantiate" ["--strict", "--show-trace", "--eval" ,"-E", nodeSpecExpr "" <> ".nodeArgs." <> x] empty

nodeNames :: Options -> NixopsConfig -> [NodeName]
nodeNames (oOnlyOn -> Nothing)    NixopsConfig{..} = topoNodes topology
nodeNames (oOnlyOn -> nodeLimit)  NixopsConfig{..}
  | Nothing   <- nodeLimit = topoNodes topology
  | Just node <- nodeLimit
  , SimpleTopo nodeMap <- topology
  = if Map.member node nodeMap then [node]
    else errorT $ format ("Node '"%s%"' doesn't exist in cluster '"%fp%"'.") (showT $ fromNodeName node) cTopology


-- * deployment structure
--
type FileSpec = (Environment, Target, Text)

deployments :: [(Deployment, [FileSpec])]
deployments =
  [ (Explorer
    , [ (Any,         All, "deployments/cardano-explorer.nix")
      , (Development, All, "deployments/cardano-explorer-env-development.nix")
      , (Production,  All, "deployments/cardano-explorer-env-production.nix")
      , (Staging,     All, "deployments/cardano-explorer-env-staging.nix")
      , (Any,         AWS, "deployments/cardano-explorer-target-aws.nix") ])
  , (Nodes
    , [ (Any,         All, "deployments/cardano-nodes.nix")
      , (Development, All, "deployments/cardano-nodes-env-development.nix")
      , (Production,  All, "deployments/cardano-nodes-env-production.nix")
      , (Staging,     All, "deployments/cardano-nodes-env-staging.nix")
      , (Any,         AWS, "deployments/cardano-nodes-target-aws.nix") ])
  , (Infra
    , [ (Any,         All, "deployments/infrastructure.nix")
      , (Production,  All, "deployments/infrastructure-env-production.nix")
      , (Any,         AWS, "deployments/infrastructure-target-aws.nix") ])
  , (ReportServer
    , [ (Any,         All, "deployments/report-server.nix")
      , (Production,  All, "deployments/report-server-env-production.nix")
      , (Staging,     All, "deployments/report-server-env-staging.nix")
      , (Any,         AWS, "deployments/report-server-target-aws.nix") ])
  , (Timewarp
    , [ (Any,         All, "deployments/timewarp.nix")
      , (Any,         AWS, "deployments/timewarp-target-aws.nix") ])
  ]

deploymentSpecs :: Deployment -> [FileSpec]
deploymentSpecs = fromJust . flip lookup deployments

filespecEnvSpecific :: Environment -> FileSpec -> Bool
filespecEnvSpecific x (x', _, _) = x == x'
filespecTgtSpecific :: Target      -> FileSpec -> Bool
filespecTgtSpecific x (_, x', _) = x == x'

filespecNeededEnv :: Environment -> FileSpec -> Bool
filespecNeededTgt :: Target      -> FileSpec -> Bool
filespecNeededEnv x fs = filespecEnvSpecific Any fs || filespecEnvSpecific x fs
filespecNeededTgt x fs = filespecTgtSpecific All fs || filespecTgtSpecific x fs

filespecFile :: FileSpec -> Text
filespecFile (_, _, x) = x

elementDeploymentFiles :: Environment -> Target -> Deployment -> [Text]
elementDeploymentFiles env tgt depl = filespecFile <$> (filter (\x -> filespecNeededEnv env x && filespecNeededTgt tgt x) $ deploymentSpecs depl)


data Options = Options
  { oConfigFile       :: Maybe FilePath
  , oOnlyOn           :: Maybe NodeName
  , oConfirm          :: Bool
  , oDebug            :: Bool
  , oSerial           :: Bool
  , oVerbose          :: Bool
  } deriving Show

parserNodeLimit :: Parser (Maybe NodeName)
parserNodeLimit = optional $ NodeName <$> (optText "just-node" 'n' "Limit operation to the specified node")

parserOptions :: Parser Options
parserOptions = Options
                <$> optional (optPath "config"    'c' "Configuration file")
                <*> (optional $ NodeName
                     <$>     (optText "only-on"   'n' "Limit operation to the specified node"))
                <*>           switch  "confirm"   'y' "Pass --confirm to nixops"
                <*>           switch  "debug"     'd' "Pass --debug to nixops"
                <*>           switch  "serial"    's' "Disable parallelisation"
                <*>           switch  "verbose"   'v' "Print all commands that are being run"

nixpkgsCommitPath :: Commit -> Text
nixpkgsCommitPath = ("nixpkgs=" <>) . fromURL . nixpkgsNixosURL

nixopsCmdOptions :: Options -> NixopsConfig -> [Text]
nixopsCmdOptions Options{..} NixopsConfig{..} =
  ["--debug"   | oDebug]   <>
  ["--confirm" | oConfirm] <>
  ["--show-trace"
  ,"--deployment", cName
  ,"-I", nixpkgsCommitPath cNixpkgsCommit
  ]


-- | Before adding a field here, consider, whether the value in question
--   ought to be passed to Nix.
--   If so, the way to do it is to add a deployment argument (see DeplArgs),
--   which are smuggled across Nix border via --arg/--argstr.
data NixopsConfig = NixopsConfig
  { cName             :: Text
  , cGenCmdline       :: Text
  , cNixops           :: FilePath
  , cNixpkgsCommit    :: Commit
  , cTopology         :: FilePath
  , cEnvironment      :: Environment
  , cTarget           :: Target
  , cElements         :: [Deployment]
  , cFiles            :: [Text]
  , cDeplArgs         :: DeplArgs
  -- this isn't stored in the config file, but is, instead filled in during initialisation
  , topology          :: SimpleTopo
  } deriving (Generic, Show)
instance FromJSON NixopsConfig where
    parseJSON = AE.withObject "NixopsConfig" $ \v -> NixopsConfig
        <$> v .: "name"
        <*> v .:? "gen-cmdline" .!= "--unknown--"
        <*> v .:? "nixops"      .!= "nixops"
        <*> v .:? "nixpkgs"     .!= defaultNixpkgs
        <*> v .:? "topology"    .!= "topology-development.yaml"
        <*> v .: "environment"
        <*> v .: "target"
        <*> v .: "elements"
        <*> v .: "files"
        <*> v .: "args"
        <*> pure undefined -- this is filled in in readConfig
instance ToJSON Environment
instance ToJSON Target
instance ToJSON Deployment
instance ToJSON NixopsConfig where
  toJSON NixopsConfig{..} = AE.object
   [ "name"         .= cName
   , "gen-cmdline"  .= cGenCmdline
   , "nixops"       .= cNixops
   , "nixpkgs"      .= fromCommit cNixpkgsCommit
   , "topology"     .= cTopology
   , "environment"  .= showT cEnvironment
   , "target"       .= showT cTarget
   , "elements"     .= cElements
   , "files"        .= cFiles
   , "args"         .= cDeplArgs ]

deploymentFiles :: Environment -> Target -> [Deployment] -> [Text]
deploymentFiles cEnvironment cTarget cElements =
  "deployments/firewalls.nix":
  "deployments/keypairs.nix":
  concat (elementDeploymentFiles cEnvironment cTarget <$> cElements)

type DeplArgs = Map.Map NixParam NixValue

selectDeploymentArgs :: Options -> FilePath -> Environment -> [Deployment] -> Elapsed -> IO DeplArgs
selectDeploymentArgs o _ env delts (Elapsed systemStart) = do
    let staticArgs = [ ("accessKeyId"
                       , NixStr . fromNodeName $ selectDeployer env delts) ]
    (IP deployerIp) <- deployerIP o
    pure $ Map.fromList $
      staticArgs
      <> [ ("deployerIP",   NixStr deployerIp)
         , ("systemStart",  NixInt $ fromIntegral systemStart)]

deplArg    :: NixopsConfig -> NixParam -> NixValue -> NixValue
deplArg      NixopsConfig{..} k def = Map.lookup k cDeplArgs & fromMaybe def
  --(errorT $ format ("Deployment arguments don't hold a value for key '"%s%"'.") (showT k))

setDeplArg :: NixopsConfig -> NixParam -> NixValue -> NixopsConfig
setDeplArg c@NixopsConfig{..} k v = c { cDeplArgs = Map.insert k v cDeplArgs }

-- | Interpret inputs into a NixopsConfig
mkConfig :: Options -> Text -> Branch -> Maybe FilePath -> Maybe FilePath -> Commit -> Environment -> Target -> [Deployment] -> Elapsed -> IO NixopsConfig
mkConfig o cGenCmdline (Branch cName) mNixops mTopology cNixpkgsCommit cEnvironment cTarget cElements systemStart = do
  let cNixops   = fromMaybe "nixops" mNixops
      cFiles    = deploymentFiles                          cEnvironment cTarget cElements
      cTopology = flip fromMaybe mTopology $
                  selectTopologyConfig                     cEnvironment         cElements
  cDeplArgs    <- selectDeploymentArgs o cTopology         cEnvironment         cElements systemStart
  topology <- liftIO $ summariseTopology <$> readTopology cTopology
  pure NixopsConfig{..}

-- | Write the config file
writeConfig :: MonadIO m => Maybe FilePath -> NixopsConfig -> m FilePath
writeConfig mFp c@NixopsConfig{..} = do
  let configFilename = flip fromMaybe mFp $ envConfigFilename cEnvironment
  liftIO $ writeTextFile configFilename $ T.pack $ BU.toString $ YAML.encode c
  pure configFilename

-- | Read back config, doing validation
readConfig :: MonadIO m => FilePath -> m NixopsConfig
readConfig cf = do
  cfParse <- liftIO $ YAML.decodeFileEither $ Path.encodeString $ cf
  let c@NixopsConfig{..}
        = case cfParse of
            Right cfg -> cfg
            -- TODO: catch and suggest versioning
            Left  e -> errorT $ format ("Failed to parse config file "%fp%": "%s)
                       cf (T.pack $ YAML.prettyPrintParseException e)
      storedFileSet  = Set.fromList cFiles
      deducedFiles   = deploymentFiles cEnvironment cTarget cElements
      deducedFileSet = Set.fromList $ deducedFiles
  unless (storedFileSet == deducedFileSet) $
    die $ format ("Config file '"%fp%"' is incoherent with respect to elements "%w%":\n  - stored files:  "%w%"\n  - implied files: "%w%"\n")
          cf cElements (sort cFiles) (sort deducedFiles)
  -- Can't read topology file without knowing its name, hence this phasing.
  topo <- liftIO $ summariseTopology <$> readTopology cTopology
  pure c { topology = topo }


parallelIO' :: Options -> NixopsConfig -> ([NodeName] -> [a]) -> (a -> IO ()) -> IO ()
parallelIO' o@Options{..} c@NixopsConfig{..} xform action =
  (if oSerial
   then sequence_
   else sh . parallel) $
  action <$> (xform $ nodeNames o c)

parallelIO :: Options -> NixopsConfig -> (NodeName -> IO ()) -> IO ()
parallelIO o c = parallelIO' o c id

logCmd  bin args = do
  printf ("-- "%s%"\n") $ T.intercalate " " $ bin:args
  Sys.hFlush Sys.stdout

inproc :: Text -> [Text] -> Shell Line -> Shell Line
inproc bin args inp = do
  liftIO $ logCmd bin args
  Turtle.inproc bin args inp

inprocs :: MonadIO m => Text -> [Text] -> Shell Line -> m Text
inprocs bin args inp = do
  (exitCode, out) <- liftIO $ procStrict bin args inp
  unless (exitCode == ExitSuccess) $
    liftIO (throwIO (ProcFailed bin args exitCode))
  pure out

cmd   :: Options -> Text -> [Text] -> IO ()
cmd'  :: Options -> Text -> [Text] -> IO (ExitCode, Text)
incmd :: Options -> Text -> [Text] -> IO Text

cmd   Options{..} bin args = do
  when oVerbose $ logCmd bin args
  Turtle.procs      bin args empty
cmd'  Options{..} bin args = do
  when oVerbose $ logCmd bin args
  Turtle.procStrict bin args empty
incmd Options{..} bin args = do
  when oVerbose $ logCmd bin args
  inprocs bin args empty


-- * Invoking nixops
--
nixops'' :: (Options -> Text -> [Text] -> IO b) -> Options -> NixopsConfig -> NixopsCmd -> [Arg] -> IO b
nixops'' executor o c@NixopsConfig{..} com args =
  executor o (format fp cNixops)
  (fromCmd com : nixopsCmdOptions o c <> fmap fromArg args)

nixops' :: Options -> NixopsConfig -> NixopsCmd -> [Arg] -> IO (ExitCode, Text)
nixops  :: Options -> NixopsConfig -> NixopsCmd -> [Arg] -> IO ()
nixops' = nixops'' cmd'
nixops  = nixops'' cmd

nixopsMaybeLimitNodes :: Options -> [Arg]
nixopsMaybeLimitNodes (oOnlyOn -> maybeNode) = ((("--include":) . (:[]) . Arg . fromNodeName) <$> maybeNode & fromMaybe [])


-- * Deployment lifecycle
--
exists :: Options -> NixopsConfig -> IO Bool
exists o c@NixopsConfig{..} = do
  (code, _) <- nixops' o c "info" []
  pure $ code == ExitSuccess

create :: Options -> NixopsConfig -> IO ()
create o c@NixopsConfig{..} = do
  deplExists <- exists o c
  when deplExists $
    die $ format ("Deployment already exists?: '"%s%"'") cName
  printf ("Creating deployment "%s%"\n") cName
  export "NIX_PATH_LOCKED" "1"
  export "NIX_PATH" (nixpkgsCommitPath cNixpkgsCommit)
  nixops o c "create" $ Arg <$> deploymentFiles cEnvironment cTarget cElements

modify :: Options -> NixopsConfig -> IO ()
modify o@Options{..} c@NixopsConfig{..} = do
  printf ("Syncing Nix->state for deployment "%s%"\n") cName
  nixops o c "modify" $ Arg <$> deploymentFiles cEnvironment cTarget cElements

  let deplArgs = Map.toList cDeplArgs
                 <> [("topologyYaml", NixFile $ cTopology)
                    ,("environment",  NixStr  $ lowerShowT cEnvironment)]
  printf ("Setting deployment arguments:\n")
  forM_ deplArgs $ \(name, val)
    -> printf ("  "%s%": "%s%"\n") (fromNixParam name) (nixValueStr val)
  nixops o c "set-args" $ Arg <$> (concat $ uncurry nixArgCmdline <$> deplArgs)

  printf ("Generating 'topology.nix' from '"%fp%"'..\n") cTopology
  preExisting <- testpath cTopology
  unless preExisting $
    die $ format ("Topology config '"%fp%"' doesn't exist.") cTopology
  simpleTopo <- summariseTopology <$> readTopology cTopology
  liftIO . writeTextFile "topology.nix" . T.pack . LBU.toString $ encodePretty simpleTopo
  when oDebug $ dumpTopologyNix "./topology.nix"

deploy :: Options -> NixopsConfig -> Bool -> Bool -> Bool -> Bool -> Maybe Seconds -> IO ()
deploy o@Options{..} c@NixopsConfig{..} evonly buonly check rebuildExplorerFrontend bumpSystemStartHeldBy = do
  when (elem Nodes cElements) $ do
     keyExists <- testfile "keys/key1.sk"
     unless keyExists $
       die "Deploying nodes, but 'keys/key1.sk' is absent."

  export "NIX_PATH_LOCKED" "1"
  export "NIX_PATH" (nixpkgsCommitPath cNixpkgsCommit)
  when (not evonly) $ do
    when (elem Nodes cElements) $ do
      export "GC_INITIAL_HEAP_SIZE" (showT $ 8 * 1024*1024*1024) -- for 100 nodes it eats 12GB of ram *and* needs a bigger heap
    export "SMART_GEN_IP"     =<< getIP <$> deployerIP o
    when (elem Explorer cElements && rebuildExplorerFrontend) $ do
      cmd o "scripts/generate-explorer-frontend.sh" []

  now <- timeCurrent
  let startParam             = NixParam "systemStart"
      secNixVal (Elapsed x)  = NixInt $ fromIntegral x
      holdSecs               = fromMaybe defaultHold bumpSystemStartHeldBy
      nowHeld                = now `timeAdd` mempty { durationSeconds = holdSecs }
      startE                 = case bumpSystemStartHeldBy of
        Just _  -> nowHeld
        Nothing -> Elapsed $ fromIntegral $ (\(NixInt x)-> x) $ deplArg c startParam (secNixVal nowHeld)
      c' = setDeplArg c startParam $ secNixVal startE
  when (isJust bumpSystemStartHeldBy) $ do
    printf ("Setting --system-start to "%s%" ("%d%" minutes into future).  Don't forget to commit config YAML!\n")
           (T.pack $ timePrint ISO8601_DateAndTime (timeFromElapsed startE :: DateTime)) (div holdSecs 60)
    void $ writeConfig oConfigFile c'

  modify o c'

  printf ("Deploying cluster "%s%"\n") cName
  nixops o c' "deploy"
    $  [ "--max-concurrent-copy", "50", "-j", "4" ]
    ++ [ "--evaluate-only" | evonly ]
    ++ [ "--build-only"    | buonly ]
    ++ [ "--check"         | check  ]
    ++ nixopsMaybeLimitNodes o
  echo "Done."

destroy :: Options -> NixopsConfig -> IO ()
destroy o c@NixopsConfig{..} = do
  printf ("Destroying cluster "%s%"\n") cName
  nixops (o { oConfirm = True }) c "destroy"
    $ nixopsMaybeLimitNodes o
  echo "Done."

delete :: Options -> NixopsConfig -> IO ()
delete o c@NixopsConfig{..} = do
  printf ("Un-defining cluster "%s%"\n") cName
  nixops (o { oConfirm = True }) c "delete"
    $ nixopsMaybeLimitNodes o
  echo "Done."

fromscratch :: Options -> NixopsConfig -> IO ()
fromscratch o c = do
  destroy o c
  delete o c
  create o c
  deploy o c False False False True (Just defaultHold)


-- * Building
--
runSetRev :: Options -> Project -> Commit -> IO ()
runSetRev o proj rev = do
  printf ("Setting '"%s%"' commit to "%s%"\n") (lowerShowT proj) (fromCommit rev)
  spec <- incmd o "nix-prefetch-git" ["--no-deepClone", fromURL $ projectURL proj, fromCommit rev]
  writeFile (T.unpack $ format fp $ projectSrcFile proj) $ T.unpack spec

runFakeKeys :: IO ()
runFakeKeys = do
  echo "Faking keys/key*.sk"
  testdir "keys"
    >>= flip unless (mkdir "keys")
  forM_ ([1..41]) $
    (\x-> do touch $ Turtle.fromText $ format ("keys/key"%d%".sk") x)
  echo "Minimum viable keyset complete."

generateGenesis :: Options -> NixopsConfig -> IO ()
generateGenesis o NixopsConfig{..} = do
  let cardanoSLDir     = "cardano-sl"
      genSuffix        = "tns"
      (,) genM genN    = (,) (topoNCores topology) 1200
      genFiles         = [ "core/genesis-core-tns.bin"
                         , "genesis-info/tns.log"
                         , "godtossing/genesis-godtossing-tns.bin" ]
      cardanoBumpFiles = [ "cardano-sl-src.json"
                         , "pkgs/default.nix" ]
  GitSource{..} <- readSource gitSource CardanoSL
  printf ("Generating genesis using cardano-sl commit "%s%"\n  M:"%d%"\n  N:"%d%"\n")
    (fromCommit gRev) genM genN
  preExisting <- testpath cardanoSLDir
  unless preExisting $
    cmd o "git" ["clone", fromURL $ projectURL CardanoSL, "cardano-sl"]
  cd cardanoSLDir
  cmd o "git" ["fetch"]
  cmd o "git" ["checkout", "master"]
  cmd o "git" ["reset", "--hard", fromCommit gRev]
  export "M" (showT genM)
  export "N" (showT genN)
  cmd o "scripts/generate/genesis.sh"
    ["--build-mode", "nix", "--iohkops-dir", "..", "--install-as-suffix", genSuffix]
  cmd o "git" (["add"] <> genFiles)
  cmd o "git" ["commit", "-m", format ("Regenerate genesis, M="%d%", N="%d) genM genN]
  echo "Genesis generated and committed, bumping 'iohk-op'"
  cardanoGenesisCommit <- incmd o "git" ["log", "-n1", "--pretty=format:%H"]
  cd ".."
  printf ("Please, push commit '"%s%"' to the cardano-sl repository and press Enter.\n-> ") cardanoGenesisCommit
  _ <- readline
  runSetRev o CardanoSL $ Commit cardanoGenesisCommit
  cmd o "pkgs/generate.sh" []
  cmd o "git" (["add"] <> cardanoBumpFiles)
  cmd o "git" ["commit", "-m", format ("Bump cardano: Regenerated genesis, M="%d%", N="%d) genM genN]

deploymentBuildTarget :: Deployment -> NixAttr
deploymentBuildTarget Nodes = "cardano-sl-static"
deploymentBuildTarget x     = error $ "'deploymentBuildTarget' has no idea what to build for " <> show x

build :: Options -> NixopsConfig -> Deployment -> IO ()
build o _c depl = do
  echo "Building derivation..."
  cmd o "nix-build" ["--max-jobs", "4", "--cores", "2", "-A", fromAttr $ deploymentBuildTarget depl]


-- * State management
--
-- Check if nodes are online and reboots them if they timeout
checkstatus :: Options -> NixopsConfig -> IO ()
checkstatus o c = do
  parallelIO o c $ rebootIfDown o c

rebootIfDown :: Options -> NixopsConfig -> NodeName -> IO ()
rebootIfDown o c (Arg . fromNodeName -> node) = do
  (x, _) <- nixops' o c "ssh" $ (node : ["-o", "ConnectTimeout=5", "echo", "-n"])
  case x of
    ExitSuccess -> return ()
    ExitFailure _ -> do
      TIO.putStrLn $ "Rebooting " <> fromArg node
      nixops o c "reboot" ["--include", node]

ssh  :: Options -> NixopsConfig -> Exec -> [Arg] -> NodeName -> IO ()
ssh o c e a n = ssh' o c e a n (TIO.putStr . ((fromNodeName n <> "> ") <>))

ssh' :: Options -> NixopsConfig -> Exec -> [Arg] -> NodeName -> (Text -> IO ()) -> IO ()
ssh' o c exec args (fromNodeName -> node) postFn = do
  let cmdline = Arg node: "--": Arg (fromExec exec): args
  (exitcode, out) <- nixops' o c "ssh" cmdline
  postFn out
  case exitcode of
    ExitSuccess -> return ()
    ExitFailure code -> TIO.putStrLn $ "ssh cmd '" <> (T.intercalate " " $ fromArg <$> cmdline) <> "' to '" <> node <> "' failed with " <> showT code

parallelSSH :: Options -> NixopsConfig -> Exec -> [Arg] -> IO ()
parallelSSH o c@NixopsConfig{..} ex as = do
  parallelIO o c $
    ssh o c ex as

scpFromNode :: Options -> NixopsConfig -> NodeName -> Text -> Text -> IO ()
scpFromNode o c (fromNodeName -> node) from to = do
  (exitcode, _) <- nixops' o c "scp" $ Arg <$> ["--from", node, from, to]
  case exitcode of
    ExitSuccess -> return ()
    ExitFailure code -> TIO.putStrLn $ "scp from " <> node <> " failed with " <> showT code

sshForEach :: Options -> NixopsConfig -> [Text] -> IO ()
sshForEach o c command =
  nixops o c "ssh-for-each" $ Arg <$> "--": command

deployed'commit :: Options -> NixopsConfig -> NodeName -> IO ()
deployed'commit o c m = do
  ssh' o c "pgrep" ["-fa", "cardano-node"] m $
    \r-> do
      case cut space r of
        (_:path:_) -> do
          drv <- incmd o "nix-store" ["--query", "--deriver", T.strip path]
          pathExists <- testpath $ fromText $ T.strip drv
          unless pathExists $
            errorT $ "The derivation used to build the package is not present on the system: " <> T.strip drv
          sh $ do
            str <- inproc "nix-store" ["--query", "--references", T.strip drv] empty &
                   inproc "egrep"       ["/nix/store/[a-z0-9]*-cardano-sl-[0-9a-f]{7}\\.drv"] &
                   inproc "sed" ["-E", "s|/nix/store/[a-z0-9]*-cardano-sl-([0-9a-f]{7})\\.drv|\\1|"]
            when (str == "") $
              errorT $ "Cannot determine commit id for derivation: " <> T.strip drv
            echo $ "The 'cardano-sl' process running on '" <> unsafeTextToLine (fromNodeName m) <> "' has commit id " <> str
        [""] -> errorT $ "Looks like 'cardano-node' is down on node '" <> fromNodeName m <> "'"
        _    -> errorT $ "Unexpected output from 'pgrep -fa cardano-node': '" <> r <> "' / " <> showT (cut space r)


startForeground :: Options -> NixopsConfig -> NodeName -> IO ()
startForeground o c node =
  ssh' o c "bash" [ "-c", "'systemctl show cardano-node --property=ExecStart | sed -e \"s/.*path=\\([^ ]*\\) .*/\\1/\" | xargs grep \"^exec \" | cut -d\" \" -f2-'"]
  node $ \unitStartCmd ->
    printf ("Starting Cardano in foreground;  Command line:\n  "%s%"\n") unitStartCmd >>
    ssh o c "bash" ["-c", Arg $ "'sudo -u cardano-node " <> unitStartCmd <> "'"] node

stop :: Options -> NixopsConfig -> IO ()
stop o c = echo "Stopping nodes..."
  >> parallelSSH o c "systemctl" ["stop", "cardano-node"]

defLogs, profLogs :: [(Text, Text -> Text)]
defLogs =
    [ ("/var/lib/cardano-node/node.log", (<> ".log"))
    , ("/var/lib/cardano-node/jsonLog.json", (<> ".json"))
    , ("/var/lib/cardano-node/time-slave.log", (<> "-ts.log"))
    , ("/var/log/saALL", (<> ".sar"))
    ]
profLogs =
    [ ("/var/lib/cardano-node/cardano-node.prof", (<> ".prof"))
    , ("/var/lib/cardano-node/cardano-node.hp", (<> ".hp"))
    -- in fact, if there's a heap profile then there's no eventlog and vice versa
    -- but scp will just say "not found" and it's all good
    , ("/var/lib/cardano-node/cardano-node.eventlog", (<> ".eventlog"))
    ]

start :: Options -> NixopsConfig -> IO ()
start o c =
  parallelSSH o c "bash" ["-c", Arg $ "'" <> rmCmd <> "; " <> startCmd <> "'"]
  where
    rmCmd = foldl (\str (f, _) -> str <> " " <> f) "rm -f" logs
    startCmd = "systemctl start cardano-node"
    logs = mconcat [ defLogs, profLogs ]

date :: Options -> NixopsConfig -> IO ()
date o c = parallelIO o c $
  \n -> ssh' o c "date" [] n
  (\out -> TIO.putStrLn $ fromNodeName n <> ": " <> out)

wipeJournals :: Options -> NixopsConfig -> IO ()
wipeJournals o c@NixopsConfig{..} = do
  echo "Wiping journals on cluster.."
  parallelSSH o c "bash"
    ["-c", "'systemctl --quiet stop systemd-journald && rm -f /var/log/journal/*/* && systemctl start systemd-journald && sleep 1 && systemctl restart nix-daemon'"]
  echo "Done."

getJournals :: Options -> NixopsConfig -> IO ()
getJournals o c@NixopsConfig{..} = do
  let nodes = nodeNames o c

  echo "Dumping journald logs on cluster.."
  parallelSSH o c "bash"
    ["-c", "'rm -f log && journalctl -u cardano-node > log'"]

  echo "Obtaining dumped journals.."
  let outfiles  = format ("log-cardano-node-"%s%".journal") . fromNodeName <$> nodes
  parallelIO' o c (flip zip outfiles) $
    \(node, outfile) -> scpFromNode o c node "log" outfile
  timeStr <- T.pack . timePrint ISO8601_DateAndTime <$> dateCurrent

  let archive   = format ("journals-"%s%"-"%s%"-"%s%".tgz") (lowerShowT cEnvironment) cName timeStr
  printf ("Packing journals into "%s%"\n") archive
  cmd o "tar" (["czf", archive, "--force-local"] <> outfiles)
  cmd o "rm" $ "-f" : outfiles
  echo "Done."

confirmOrTerminate :: Text -> IO ()
confirmOrTerminate question = do
  echo $ unsafeTextToLine question <> "  Enter 'yes' to proceed:"
  reply <- readline
  unless (reply == Just "yes") $ do
    echo "User declined to proceed, exiting."
    exit $ ExitFailure 1

wipeNodeDBs :: Options -> NixopsConfig -> IO ()
wipeNodeDBs o c@NixopsConfig{..} = do
  confirmOrTerminate "Wipe node DBs on the entire cluster?"
  parallelSSH o c "rm" ["-rf", "/var/lib/cardano-node"]
  echo "Done."

updateNixops :: Options -> NixopsConfig -> IO ()
updateNixops o@Options{..} c@NixopsConfig{..} = do
  let (,) nixopsDir outLink = (,) "nixops" ("nixops-link" :: FilePath)
      configFile = flip fromMaybe oConfigFile $
        error "The 'update-nixops' subcommand requires the -c/--config option to 'iohk-ops'."
  preExists <- testpath nixopsDir
  unless preExists $ do
    errorT $ format ("The 'update-nixops' subcommand requires a '"%fp%"' subdirectory as input.") nixopsDir
  cd nixopsDir
  cmd o "nix-build" ["-A", "build.x86_64-linux", "--out-link", "../" <> format fp outLink, "release.nix"]
  sh $ do
    gitHeadRev <- inproc "git" ["rev-parse", "HEAD"] empty
    cd ".."
    nixopsStorePath <- inproc "readlink" [format fp outLink] empty
    liftIO $ printf ("Built nixops commit '"%s%"' is at '"%s%"', updating config '"%fp%"'\n")
      (lineToText gitHeadRev) (lineToText nixopsStorePath) configFile
    writeConfig (Just configFile) $ c { cNixops = Path.fromText $ lineToText nixopsStorePath <> "/bin/nixops" }
    -- Unfortunately, Turtle doesn't seem to provide anything of the form Shell a -> IO a,
    -- that would allow us to smuggle non-Text values out of a Shell monad.
  echo "Done."


-- * Functions for extracting information out of nixops info command
--
-- | Get all nodes in EC2 cluster
data DeploymentStatus = UpToDate | Obsolete | Outdated
  deriving (Show, Eq)

instance FromField DeploymentStatus where
  parseField "up-to-date" = pure UpToDate
  parseField "obsolete" = pure Obsolete
  parseField "outdated" = pure Outdated
  parseField _ = mzero

data DeploymentInfo = DeploymentInfo
    { diName :: !NodeName
    , diStatus :: !DeploymentStatus
    , diType :: !Text
    , diResourceID :: !Text
    , diPublicIP :: !IP
    , diPrivateIP :: !IP
    } deriving (Show, Generic)

instance FromRecord DeploymentInfo
deriving instance FromField NodeName

nixopsDecodeOptions = defaultDecodeOptions {
    decDelimiter = fromIntegral (ord '\t')
  }

info :: Options -> NixopsConfig -> IO (Either String (V.Vector DeploymentInfo))
info o c = do
  (exitcode, nodes) <- nixops' o c "info" ["--no-eval", "--plain"]
  case exitcode of
    ExitFailure code -> return $ Left ("Parsing info failed with exit code " <> show code)
    ExitSuccess -> return $ decodeWith nixopsDecodeOptions NoHeader (encodeUtf8 $ fromStrict nodes)

toNodesInfo :: V.Vector DeploymentInfo -> [DeploymentInfo]
toNodesInfo vector =
  V.toList $ V.filter filterEC2 vector
    where
      filterEC2 di = T.take 4 (diType di) == "ec2 " && diStatus di /= Obsolete

getNodePublicIP :: Text -> V.Vector DeploymentInfo -> Maybe Text
getNodePublicIP name vector =
    headMay $ V.toList $ fmap (getIP . diPublicIP) $ V.filter (\di -> fromNodeName (diName di) == name) vector


-- * Utils
showT :: Show a => a -> Text
showT = T.pack . show

readT :: Read a => Text -> a
readT = read . T.unpack

lowerShowT :: Show a => a -> Text
lowerShowT = T.toLower . T.pack . show

errorT :: Text -> a
errorT = error . T.unpack

jsonLowerStrip :: (Generic a, AE.GToJSON AE.Zero (Rep a)) => Int -> a -> AE.Value
jsonLowerStrip n = AE.genericToJSON $ AE.defaultOptions { AE.fieldLabelModifier = map toLower . drop n }
