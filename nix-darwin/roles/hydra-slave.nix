{ config, lib, pkgs, ... }:

{
  imports = [
    ../modules/basics.nix
    ../modules/hydra-slave.nix
  ];
}
