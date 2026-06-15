{
  "targets": [
    {
      "target_name": "waku",
      "sources": [ "waku_addon.c", "../cbindings/base64.c" ],
      "libraries": [ "-llogosdelivery", "-L../../../build/" ]
    }
  ]
}
