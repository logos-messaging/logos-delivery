{
  "targets": [
    {
      "target_name": "waku",
      "sources": [ "waku_addon.c", "../cbindings/base64.c" ],
      "include_dirs": [
        "../../build",
        "<!(ls -dt ../../nimbledeps/pkgs2/ffi-* | head -1)/ffi/codegen/templates/cpp/vendor"
      ],
      "libraries": [ "-llogosdelivery", "-L../../../build/", "../../../build/libtinycbor.a" ]
    }
  ]
}
