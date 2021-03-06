# To interact with this file:
# nix-repl lib.nix

let
  application = "iohk-ops";
  # iohk-nix can be overridden for debugging purposes by setting
  # NIX_PATH=iohk_nix=/path/to/iohk-nix
  iohkNix = import (
    let try = builtins.tryEval <iohk_nix>;
    in if try.success
    then builtins.trace "using host <iohk_nix>" try.value
    else
      let
        spec = builtins.fromJSON (builtins.readFile ./iohk-nix.json);
      in builtins.fetchTarball {
        url = "${spec.url}/archive/${spec.rev}.tar.gz";
        inherit (spec) sha256;
      }) { inherit application; };

  # nixpkgs can be overridden for debugging purposes by setting
  # NIX_PATH=custom_nixpkgs=/path/to/nixpkgs
  pkgs = iohkNix.pkgs;
  lib = pkgs.lib;
in lib // (rec {
  ## nodeElasticIP :: Node -> EIP
  nodeElasticIP = node:
    { name = "${node.name}-ip";
      value = { inherit (node) region accessKeyId; };
    };

  centralRegion = "eu-central-1";
  centralZone   = "eu-central-1b";

  ## nodesElasticIPs :: Map NodeName Node -> Map EIPName EIP
  nodesElasticIPs = nodes: lib.flip lib.mapAttrs' nodes
    (name: node: nodeElasticIP node);

  resolveSGName = resources: name: resources.ec2SecurityGroups.${name};

  orgRegionKeyPairName = org: region: "cardano-keypair-${org}-${region}";

  inherit (iohkNix) nixpkgs;
  inherit pkgs;

  traceF   = f: x: builtins.trace                         (f x)  x;
  traceSF  = f: x: builtins.trace (builtins.seq     (f x) (f x)) x;
  traceDSF = f: x: builtins.trace (builtins.deepSeq (f x) (f x)) x;

  # Parse peers from a file
  #
  # > peersFromFile ./peers.txt
  # ["ip:port/dht" "ip:port/dht" ...]
  peersFromFile = file: lib.splitString "\n" (builtins.readFile file);

  # Given a list of NixOS configs, generate a list of peers (ip/dht mappings)
  genPeersFromConfig = configs:
    let
      f = c: "${c.networking.publicIPv4}:${toString c.services.cardano-node.port}";
    in map f configs;

  # modulo operator
  # mod 11 10 == 1
  # mod 1 10 == 1
  mod = base: int: base - (int * (builtins.div base int));

  # Removes files within a Haskell source tree which won't change the
  # result of building the package.
  # This is so that cached build products can be used whenever possible.
  # It also applies the lib.cleanSource filter from nixpkgs which
  # removes VCS directories, emacs backup files, etc.
  cleanSourceTree = src:
    if lib.canCleanSource src
      then lib.cleanSourceWith {
        filter = with pkgs.stdenv;
          name: type: let baseName = baseNameOf (toString name); in ! (
            # Filter out cabal build products.
            baseName == "dist" || baseName == "dist-newstyle" ||
            baseName == "cabal.project.local" ||
            lib.hasPrefix ".ghc.environment" baseName ||
            # Filter out stack build products.
            lib.hasPrefix ".stack-work" baseName ||
            # Filter out files which are commonly edited but don't
            # affect the cabal build.
            lib.hasSuffix ".nix" baseName
          );
        src = lib.cleanSource src;
      } else src;

} // (with (import ./lib/ssh-keys.nix { inherit lib; }); rec {
  #
  # Access
  #
  inherit devOps csl-developers;

  devOpsKeys = allKeysFrom devOps;
  devKeys = devOpsKeys ++ allKeysFrom csl-developers;
  mantisOpsKeys = allKeysFrom devOps ++ allKeysFrom mantis-devOps;

  # Access to login to CI infrastructure
  ciInfraKeys = devOpsKeys ++ allKeysFrom { inherit (csl-developers) angerman; };

  buildSlaveKeys = {
    macos = devOpsKeys ++ allKeysFrom remoteBuilderKeys;
    linux = remoteBuilderKeys.hydraBuildFarm;
  };

}))
