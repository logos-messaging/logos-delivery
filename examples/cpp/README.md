## App description
This is a very simple example that shows how to invoke liblogosdelivery functions from a C++ program.

## Build
1. Open terminal
2. cd to logos-delivery root folder
3. make cpp-logos-delivery-example -j8

This will create liblogosdelivery.so and cpp-logos-delivery-example binary within the build folder.

## Run
1. Open terminal
2. cd to logos-delivery root folder
3. export LD_LIBRARY_PATH=build
4. `./build/cpp-logos-delivery-example --host=0.0.0.0 --port=60001`

Use `./build/cpp-logos-delivery-example --help` to see some other options.

