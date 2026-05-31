{
  description = "ThinkPad P51 — ZFS + LUKS + impermanence";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    impermanence = {
      url = "github:nix-community/impermanence";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-hardware.url = "github:NixOS/nixos-hardware";
  };

  outputs = {
    self,
    nixpkgs,
    disko,
    impermanence,
    nixos-hardware,
  }: let
    inherit (nixpkgs.lib) nixosSystem;
  in {
    nixosConfigurations.p51 = nixosSystem {
      system = "x86_64-linux";

      specialArgs = {
        inherit disko impermanence;
      };

      modules = [
        disko.nixosModules.disko
        nixos-hardware.nixosModules.lenovo-thinkpad-p51

        ./hosts/p51
      ];
    };

    # Separate disko output so `nix run github:nix-community/disko -- --flake .#p51` works
    diskoConfigurations.p51 = import ./hosts/p51/disko-config.nix {
      diskDevice = "/dev/disk/by-id/nvme-Samsung_SSD_990_PRO_1TB"; # ⚠️ set this
    };
  };
}
