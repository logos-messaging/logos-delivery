#
# This Nix expression centralizes the configuration
# for the Android development environment.
#

{ androidenv, lib, stdenv }:

# The "android-sdk-license" license is accepted
# by setting android_sdk.accept_license = true.
androidenv.composeAndroidPackages {
  cmdLineToolsVersion = "9.0";
  toolsVersion = "26.1.1";
  platformToolsVersion = "34.0.5";
  buildToolsVersions = [ "34.0.0" ];
  platformVersions = [ "34" ];
  cmakeVersions = [ "3.22.1" ];
  ndkVersion = "27.2.12479018";
  includeNDK = true;
  includeExtras = [
    "extras;android;m2repository"
    "extras;google;m2repository"
  ];
}
