{
  "targets": [
    {
      "target_name": "logosDelivery",
      "sources": [ "logos_delivery_addon.c", "../cbindings/base64.c" ],
      "include_dirs": [
        "../../build",
        "<(tinycbor_dir)"
      ],
      "libraries": [ "-llogosdelivery", "-L../../../build/", "../../../build/libtinycbor.a" ]
    }
  ]
}
