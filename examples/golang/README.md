
## Pre-requisite
liblogosdelivery.so is needed to be compiled and present in build folder. To create it:

- Run this every time you want to compile liblogosdelivery
```code
make POSTGRES=1 liblogosdelivery -j4
```

Also needed:

- Install libpq (needed by Postgres client)
  - On Linux:
```code
sudo apt install libpq5
```
  - On MacOS (not tested)
```code
brew install libpq
```

## Compilation

From the nwaku root folder:

```code
make gowaku_example
```

It passes the TinyCBOR include path and archive that the generated header needs.

## Run
From the nwaku root folder:


```code
export LD_LIBRARY_PATH=build
```

```code
./build/gowaku_example
```
