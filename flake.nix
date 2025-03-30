{
  description = "the flutter devshell definition for nixos developers";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      # not doing android builds for now, mobile is no fun
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
          config.android_sdk.accept_license = true;
        };
      in {
        devShells.default =
          let android = pkgs.androidenv.composeAndroidPackages {
            toolsVersion = "26.1.1";
            platformToolsVersion = "34.0.5";
            buildToolsVersions = [ "30.0.3" ];
            includeEmulator = true;
            emulatorVersion = "34.1.9";
            platformVersions = [ "28" "29" "33" "34" ];
            includeSources = false;
            includeSystemImages = true;
            # we need "google_apis" here but it doesn't build, nix hashes are wrong
            systemImageTypes = [ "google_apis_playstore" ];
            abiVersions = [ "armeabi-v7a" "arm64-v8a" ];
            cmakeVersions = [ "3.10.2" ];
            includeNDK = true;
            ndkVersions = [ "22.0.7026061" ];
            useGoogleAPIs = true;
            useGoogleTVAddOns = false;
          };
          in pkgs.mkShell {
            buildInputs = with pkgs; [
              flutter327
              jdk17
              android.platform-tools
              # you may need this for linux
              # pkg-config gtk3 gtk3.dev ninja clang glibc
            ];

            ANDROID_HOME = android.androidsdk + /libexec/android-sdk;
            JAVA_HOME = pkgs.jdk17;
            ANDROID_AVD_HOME = (toString ./.) + "/.android/avd";
            ANDROID_SDK_ROOT = android.androidsdk + /libexec/android-sdk;
          };
      });
      
      # let
      #   pkgs = import nixpkgs {
      #     inherit system;
      #     config.allowUnfree = true;
      #   };
      # in {
      #   devShells.default = 
      #     pkgs.mkShell {
      #       buildInputs = (with pkgs; [flut pkg-config gtk3 gtk3.dev ninja clang glibc]);
      #     };
      # }
}