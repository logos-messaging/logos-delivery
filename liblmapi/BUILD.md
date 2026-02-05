# Building liblmapi and Examples

## Prerequisites

- Nim 2.x compiler
- Rust toolchain (for RLN dependencies)
- GCC or Clang compiler
- Make

## Building the Library

### Dynamic Library

```bash
make liblmapi
```

This creates `build/liblmapi.dylib` (macOS) or `build/liblmapi.so` (Linux).

### Static Library

```bash
nim liblmapiStatic
```

This creates `build/liblmapi.a`.

## Building Examples

### liblmapi Example

Compile the C example that demonstrates all library features:

```bash
# Using Make (recommended)
make liblmapi_example

# Or manually on macOS:
gcc -o build/liblmapi_example \
    liblmapi/examples/liblmapi_example.c \
    -I./liblmapi \
    -L./build \
    -llmapi \
    -Wl,-rpath,./build

# Or manually on Linux:
gcc -o build/liblmapi_example \
    liblmapi/examples/liblmapi_example.c \
    -I./liblmapi \
    -L./build \
    -llmapi \
    -Wl,-rpath='$ORIGIN'
```

## Running Examples

```bash
./build/liblmapi_example
```

The example will:
1. Create a Logos Messaging node
2. Register event callbacks for message events
3. Start the node
4. Subscribe to a content topic
5. Send a message
6. Show message delivery events (sent, propagated, or error)
7. Unsubscribe and cleanup

## Build Artifacts

After building, you'll have:

```
build/
├── liblmapi.dylib        # Dynamic library (34MB)
├── liblmapi.dylib.dSYM/  # Debug symbols
└── liblmapi_example      # Compiled example (34KB)
```

## Library Headers

The main header file is:
- `liblmapi/liblmapi.h` - C API declarations

## Troubleshooting

### Library not found at runtime

If you get "library not found" errors when running the example:

**macOS:**
```bash
export DYLD_LIBRARY_PATH=/path/to/build:$DYLD_LIBRARY_PATH
./build/liblmapi_example
```

**Linux:**
```bash
export LD_LIBRARY_PATH=/path/to/build:$LD_LIBRARY_PATH
./build/liblmapi_example
```

### Compilation fails

Make sure you've run:
```bash
make update
```

This updates all git submodules which are required for building.

## Static Linking

To link statically instead of dynamically:

```bash
gcc -o build/simple_example \
    liblmapi/examples/simple_example.c \
    -I./liblmapi \
    build/liblmapi.a \
    -lm -lpthread
```

Note: Static library is much larger (~129MB) but creates a standalone executable.

## Cross-Compilation

For cross-compilation, you need to:
1. Build the Nim library for the target platform
2. Use the appropriate cross-compiler
3. Link against the target platform's liblmapi

Example for Linux from macOS:
```bash
# Build library for Linux (requires Docker or cross-compilation setup)
# Then compile with cross-compiler
```

## Integration with Your Project

### CMake

```cmake
find_library(LMAPI_LIBRARY NAMES lmapi PATHS ${PROJECT_SOURCE_DIR}/build)
include_directories(${PROJECT_SOURCE_DIR}/liblmapi)
target_link_libraries(your_target ${LMAPI_LIBRARY})
```

### Makefile

```makefile
CFLAGS += -I/path/to/liblmapi
LDFLAGS += -L/path/to/build -llmapi -Wl,-rpath,/path/to/build

your_program: your_program.c
	$(CC) $(CFLAGS) $< -o $@ $(LDFLAGS)
```

## API Documentation

See:
- [liblmapi.h](liblmapi/liblmapi.h) - API function declarations
- [MESSAGE_EVENTS.md](liblmapi/MESSAGE_EVENTS.md) - Message event handling guide
- [IMPLEMENTATION_SUMMARY.md](liblmapi/IMPLEMENTATION_SUMMARY.md) - Implementation details
