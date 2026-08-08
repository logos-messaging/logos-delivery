# Shared CMake logic for nim-ffi generated bindings. Builds the Nim library as
# a shared object and the vendored TinyCBOR as a static library, and exposes
# them as the imported target `${NIM_FFI_LIB}` (+ `${NIM_FFI_LIB}_nim_lib`) and
# the `tinycbor` target. Included by the per-language generated CMakeLists,
# which set REPO_ROOT, NIM_FFI_LIB (library name) and NIM_FFI_SRC (path to the
# .nim root, relative to the including CMakeLists) before including this file.

get_filename_component(NIM_SRC
    "${CMAKE_CURRENT_SOURCE_DIR}/${NIM_FFI_SRC}"
    ABSOLUTE)

find_program(NIM_EXECUTABLE nim REQUIRED)

if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    set(NIM_LIB_FILE "${REPO_ROOT}/lib${NIM_FFI_LIB}.dylib")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Windows")
    set(NIM_LIB_FILE "${REPO_ROOT}/${NIM_FFI_LIB}.dll")
    set(NIM_IMPLIB_FILE "${REPO_ROOT}/${NIM_FFI_LIB}.lib")
else()
    set(NIM_LIB_FILE "${REPO_ROOT}/lib${NIM_FFI_LIB}.so")
endif()

# On Windows the default Nim toolchain (mingw gcc) doesn't emit an import
# library unless told to; without it MSVC consumers can't resolve any exported
# symbol at link time.
set(NIM_IMPLIB_PASSL "")
if(CMAKE_SYSTEM_NAME STREQUAL "Windows")
    set(NIM_IMPLIB_PASSL "--passL:-Wl,--out-implib,${NIM_IMPLIB_FILE}")
endif()

add_custom_command(
    OUTPUT  "${NIM_LIB_FILE}"
    COMMAND "${NIM_EXECUTABLE}" c
                --mm:orc
                -d:chronicles_log_level=WARN
                --app:lib
                --noMain
                "--nimMainPrefix:lib${NIM_FFI_LIB}"
                ${NIM_IMPLIB_PASSL}
                "-o:${NIM_LIB_FILE}"
                "${NIM_SRC}"
    WORKING_DIRECTORY "${REPO_ROOT}"
    DEPENDS "${NIM_SRC}"
    BYPRODUCTS "${NIM_IMPLIB_FILE}"
    COMMENT "Compiling Nim library lib${NIM_FFI_LIB}"
    VERBATIM
)
add_custom_target(${NIM_FFI_LIB}_nim_lib ALL DEPENDS "${NIM_LIB_FILE}")

# On Windows an IMPORTED SHARED target needs IMPORTED_IMPLIB, but the Visual
# Studio multi-config generator did not pick it up and emitted
# `${NIM_FFI_LIB}-NOTFOUND.obj`. Side-step the IMPORTED machinery there by
# exposing the import library through a plain INTERFACE library.
if(CMAKE_SYSTEM_NAME STREQUAL "Windows")
    add_library(${NIM_FFI_LIB} INTERFACE)
    target_link_libraries(${NIM_FFI_LIB} INTERFACE "${NIM_IMPLIB_FILE}")
else()
    add_library(${NIM_FFI_LIB} SHARED IMPORTED GLOBAL)
    set_target_properties(${NIM_FFI_LIB} PROPERTIES IMPORTED_LOCATION "${NIM_LIB_FILE}")
endif()
add_dependencies(${NIM_FFI_LIB} ${NIM_FFI_LIB}_nim_lib)

# Absolute path to the runtime library (DLL/dylib/so). Exposed via the cache so
# consumers in other directories can stage the DLL next to their executable on
# Windows.
set(${NIM_FFI_LIB}_RUNTIME_LIB "${NIM_LIB_FILE}" CACHE INTERNAL
    "Absolute path to the ${NIM_FFI_LIB} runtime library")

# ── TinyCBOR (vendored at ffi/codegen/templates/cpp/vendor/tinycbor) ─────────
# The C and C++ backends share one vendored TinyCBOR copy. Guarded so two
# sibling bindings dirs in one parent project don't redefine the target.
set(TINYCBOR_SRC_DIR "${REPO_ROOT}/ffi/codegen/templates/cpp/vendor")
if(NOT TARGET tinycbor)
    add_library(tinycbor STATIC
        "${TINYCBOR_SRC_DIR}/tinycbor/cborencoder.c"
        "${TINYCBOR_SRC_DIR}/tinycbor/cborencoder_close_container_checked.c"
        "${TINYCBOR_SRC_DIR}/tinycbor/cborparser.c"
        "${TINYCBOR_SRC_DIR}/tinycbor/cborparser_dup_string.c"
        "${TINYCBOR_SRC_DIR}/tinycbor/cborerrorstrings.c"
    )
    target_include_directories(tinycbor PUBLIC
        "${TINYCBOR_SRC_DIR}"            # consumer uses #include <tinycbor/cbor.h>
        "${TINYCBOR_SRC_DIR}/tinycbor"   # internal _p.h includes resolve here
    )
    set_property(TARGET tinycbor PROPERTY C_STANDARD 99)
    set_property(TARGET tinycbor PROPERTY POSITION_INDEPENDENT_CODE ON)
endif()
