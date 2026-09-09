# FAQ

## How do I see what address a node is listening for?

Grep for "Listening on". It should be printed at INFO level at the beginning. E.g. from Kibana:

`Oct 7, 2020 @ 23:17:00.383INF 2020-10-07 23:17:00.375+00:00 Listening on                               topics="wakunode" tid=1 file=logosdeliverynode.nim:140 full=/ip4/0.0.0.0/tcp/60000/p2p/16Uiu2HAkzHaTP5JsUwfR9NR8Rj9HC24puS6ocaU8wze4QrXr9iXp`

## How do I find out node addresses at the test cluster?

The easiest way is to use `jq` and query the fleets registry that Status operates:

```
curl -s https://fleets.status.im | jq '.fleets["waku.test"]'

# Output
{
  "tcp/p2p/waku": {
    "node-01.do-ams3.waku.test": "/dns4/node-01.do-ams3.waku.test.status.im/tcp/30303/p2p/16Uiu2HAkykgaECHswi3YKJ5dMLbq2kPVCo89fcyTd38UcQD6ej5W",
    "node-01.gc-us-central1-a.waku.test": "/dns4/node-01.gc-us-central1-a.waku.test.status.im/tcp/30303/p2p/16Uiu2HAmDCp8XJ9z1ev18zuv8NHekAsjNyezAvmMfFEJkiharitG",
    "node-01.ac-cn-hongkong-c.waku.test": "/dns4/node-01.ac-cn-hongkong-c.waku.test.status.im/tcp/30303/p2p/16Uiu2HAkzHaTP5JsUwfR9NR8Rj9HC24puS6ocaU8wze4QrXr9iXp"
  },
  "enr/p2p/waku": {
    "node-01.do-ams3.waku.test": "enr:-QESuEC1p_s3xJzAC_XlOuuNrhVUETmfhbm1wxRGis0f7DlqGSw2FM-p2Ugl_r25UHQJ3f1rIRrpzxJXSMaJe4yk1XFSAYJpZIJ2NIJpcISygI2rim11bHRpYWRkcnO4XAArNiZub2RlLTAxLmRvLWFtczMud2FrdS50ZXN0LnN0YXR1c2ltLm5ldAZ2XwAtNiZub2RlLTAxLmRvLWFtczMud2FrdS50ZXN0LnN0YXR1c2ltLm5ldAYfQN4DgnJzkwABCAAAAAEAAgADAAQABQAGAAeJc2VjcDI1NmsxoQJATXRSRSUyTw_QLB6H_U3oziVQgNRgrXpK7wp2AMyNxYN0Y3CCdl-DdWRwgiMohXdha3UyDw",
    "node-01.gc-us-central1-a.waku.test": "enr:-QEkuECnZ3IbVAgkOzv-QLnKC4dRKAPRY80m1-R7G8jZ7yfT3ipEfBrhKN7ARcQgQ-vg-h40AQzyvAkPYlHPaFKk6u9uAYJpZIJ2NIJpcIQiEAFDim11bHRpYWRkcnO4bgA0Ni9ub2RlLTAxLmdjLXVzLWNlbnRyYWwxLWEud2FrdS50ZXN0LnN0YXR1c2ltLm5ldAZ2XwA2Ni9ub2RlLTAxLmdjLXVzLWNlbnRyYWwxLWEud2FrdS50ZXN0LnN0YXR1c2ltLm5ldAYfQN4DgnJzkwABCAAAAAEAAgADAAQABQAGAAeJc2VjcDI1NmsxoQMIJwesBVgUiBCi8yiXGx7RWylBQkYm1U9dvEy-neLG2YN0Y3CCdl-DdWRwgiMohXdha3UyDw",
    "node-01.ac-cn-hongkong-c.waku.test": "enr:-QEkuEDzQyIAhs-CgBHIrJqtBv3EY1uP1Psrc-y8yJKsmxW7dh3DNcq2ergMUWSFVcJNlfcgBeVsFPkgd_QopRIiCV2pAYJpZIJ2NIJpcIQI2ttrim11bHRpYWRkcnO4bgA0Ni9ub2RlLTAxLmFjLWNuLWhvbmdrb25nLWMud2FrdS50ZXN0LnN0YXR1c2ltLm5ldAZ2XwA2Ni9ub2RlLTAxLmFjLWNuLWhvbmdrb25nLWMud2FrdS50ZXN0LnN0YXR1c2ltLm5ldAYfQN4DgnJzkwABCAAAAAEAAgADAAQABQAGAAeJc2VjcDI1NmsxoQJIN4qwz3v4r2Q8Bv8zZD0eqBcKw6bdLvdkV7-JLjqIj4N0Y3CCdl-DdWRwgiMohXdha3UyDw"
  },
  "wss/p2p/waku": {
    "node-01.do-ams3.waku.test": "/dns4/node-01.do-ams3.waku.test.status.im/tcp/8000/wss/p2p/16Uiu2HAkykgaECHswi3YKJ5dMLbq2kPVCo89fcyTd38UcQD6ej5W",
    "node-01.gc-us-central1-a.waku.test": "/dns4/node-01.gc-us-central1-a.waku.test.status.im/tcp/8000/wss/p2p/16Uiu2HAmDCp8XJ9z1ev18zuv8NHekAsjNyezAvmMfFEJkiharitG",
    "node-01.ac-cn-hongkong-c.waku.test": "/dns4/node-01.ac-cn-hongkong-c.waku.test.status.im/tcp/8000/wss/p2p/16Uiu2HAkzHaTP5JsUwfR9NR8Rj9HC24puS6ocaU8wze4QrXr9iXp"
  }
}
```
