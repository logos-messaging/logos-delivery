## App description
This is a very simple example that shows how to invoke libwaku functions from a C program.

## Build
1. Open terminal
2. cd to nwaku root folder
3. make cwaku_example -j8

This will create liblogosdelivery.so and cwaku_example binary within the build folder.

## Run
1. Open terminal
2. cd to nwaku root folder
3. export LD_LIBRARY_PATH=build
4. `./build/cwaku_example --host=0.0.0.0 --port=60001`

Use `./build/cwaku_example --help` to see some other options.

