
## Pre-requisite
liblogosdelivery.so is needed to be compiled and present in build folder. To create it:

- Run only the first time and after changing the current commit
```code
make update
```
- Run the next every time you want to compile libwaku
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
go build -o waku-go examples/golang/waku.go
```

## Run
From the nwaku root folder:


```code
export LD_LIBRARY_PATH=build
```

```code
./waku-go
```
