{
  meta = {
    nixpkgs = import <nixpkgs> {};
  };

  api = import ./api.nix;
  frontend = import ./frontend.nix;
}

