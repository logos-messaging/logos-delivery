# Building liblogosdelivery and Examples

## Prerequisites

- Nim 2.x compiler
- Rust toolchain (for RLN dependencies)
- GCC or Clang compiler
- Make

## Building the Library

### Dynamic Library

```bash
make liblogosdelivery
```

This creates `build/liblogosdelivery.dylib` (macOS) or `build/liblogosdelivery.so` (Linux).

### Static Library

```bash
nim liblogosdelivery STATIC=1
```

This creates `build/liblogosdelivery.a`.

## Building Examples

### liblogosdelivery Example

Compile the C example that demonstrates all library features:

```bash
# Using Make (recommended)
make liblogosdelivery_example

# Or manually on macOS:
gcc -o build/liblogosdelivery_example \
    liblogosdelivery/examples/liblogosdelivery_example.c \
    -I./liblogosdelivery \
    -L./build \
    -llmapi \
    -Wl,-rpath,./build

# Or manually on Linux:
gcc -o build/liblogosdelivery_example \
    liblogosdelivery/examples/liblogosdelivery_example.c \
    -I./liblogosdelivery \
    -L./build \
    -llmapi \
    -Wl,-rpath='$ORIGIN'
```

## Running Examples

```bash
./build/liblogosdelivery_example
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
├── liblogosdelivery.dylib        # Dynamic library (34MB)
├── liblogosdelivery.dylib.dSYM/  # Debug symbols
└── liblogosdelivery_example      # Compiled example (34KB)
```

## Library Headers

The main header file is:
- `liblogosdelivery/liblogosdelivery.h` - C API declarations

## Troubleshooting

### Library not found at runtime

If you get "library not found" errors when running the example:

**macOS:**
```bash
export DYLD_LIBRARY_PATH=/path/to/build:$DYLD_LIBRARY_PATH
./build/liblogosdelivery_example
```

**Linux:**
```bash
export LD_LIBRARY_PATH=/path/to/build:$LD_LIBRARY_PATH
./build/liblogosdelivery_example
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
gcc -o build/logosdelivery_example \
    liblogosdelivery/examples/logosdelivery_example.c \
    -I./liblogosdelivery \
    build/liblogosdelivery.a \
    -lm -lpthread
```

Note: Static library is much larger (~129MB) but creates a standalone executable.

## Cross-Compilation

For cross-compilation, you need to:
1. Build the Nim library for the target platform
2. Use the appropriate cross-compiler
3. Link against the target platform's liblogosdelivery

Example for Linux from macOS:
```bash
# Build library for Linux (requires Docker or cross-compilation setup)
# Then compile with cross-compiler
```

## Integration with Your Project

### CMake

```cmake
find_library(LMAPI_LIBRARY NAMES lmapi PATHS ${PROJECT_SOURCE_DIR}/build)
include_directories(${PROJECT_SOURCE_DIR}/liblogosdelivery)
target_link_libraries(your_target ${LMAPI_LIBRARY})
```

### Makefile

```makefile
CFLAGS += -I/path/to/liblogosdelivery
LDFLAGS += -L/path/to/build -llmapi -Wl,-rpath,/path/to/build

your_program: your_program.c
	$(CC) $(CFLAGS) $< -o $@ $(LDFLAGS)
```

## API Documentation

See:
- [liblogosdelivery.h](liblogosdelivery/liblogosdelivery.h) - API function declarations
- [MESSAGE_EVENTS.md](liblogosdelivery/MESSAGE_EVENTS.md) - Message event handling guide
