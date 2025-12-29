{ pkgs }:

pkgs.fetchFromGitHub {
  owner = "guzba";
  repo = "zippy";
  rev = "a99f6a7d8a8e3e0213b3cad0daf0ea974bf58e3f";
  # WARNING: Requires manual updates when Nim compiler version changes.
  hash = "sha256-e2ma2Oyp0dlNx8pJsdZl5o5KnaoAX87tqfY0RLG3DZs=";
}