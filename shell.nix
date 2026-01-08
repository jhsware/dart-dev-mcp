let
  sources = import ./nix/sources.nix;
  pkgs = import sources.nixpkgs {};
  hcloud = pkgs.callPackage nix/hcloud.nix {};

  isMacOS = builtins.match ".*-darwin" pkgs.stdenv.hostPlatform.system != null;
in pkgs.mkShell rec {
  name = "dart";

  buildInputs = with pkgs; [    
    pkgs.dart
    pkgs.openssl
    pkgs.gnupg      # For GPG commit signing
    pkgs.pinentry   # For GPG passphrase entry
  ] ++ (if !isMacOS then [
    pkgs.openssh
  ] else []);

  shellHook = ''
    # Set up GPG environment for commit signing
    export GPG_TTY=$(tty)
    
    # Note: GPG tests create their own temporary GNUPGHOME
    # For real GPG signing, you'll need to set up keys:
    #   gpg --full-generate-key
    #   git config --global user.signingkey YOUR_KEY_ID
  '';
}
