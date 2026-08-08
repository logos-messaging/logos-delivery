cmake_minimum_required(VERSION 3.14)
project({{LIB}}_cpp_bindings CXX C)

# The generated bindings target C++20: designated initializers and other
# C++20 constructs are used throughout the emitted code.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# MSVC defaults __cplusplus to 199711L regardless of the active /std:c++XX
# level — the generated header's C++20 guard would then misfire. /Zc:__cplusplus
# makes MSVC report the actual standard. Harmless on every other compiler.
if(MSVC)
    add_compile_options(/Zc:__cplusplus)
endif()

# ── Locate the repository root (contains ffi.nimble) ─────────────────────────
set(_search_dir "${CMAKE_CURRENT_SOURCE_DIR}")
set(REPO_ROOT "")
foreach(_i RANGE 10)
    if(EXISTS "${_search_dir}/ffi.nimble")
        set(REPO_ROOT "${_search_dir}")
        break()
    endif()
    get_filename_component(_search_dir "${_search_dir}" DIRECTORY)
endforeach()
if("${REPO_ROOT}" STREQUAL "")
    message(FATAL_ERROR "Cannot find repo root (no ffi.nimble in any ancestor)")
endif()

# Build the Nim dylib + vendored TinyCBOR (shared with the C backend).
set(NIM_FFI_LIB {{LIB}})
set(NIM_FFI_SRC {{SRC}})
include("${REPO_ROOT}/ffi/codegen/templates/nim_ffi_lib.cmake")

add_library({{LIB}}_headers INTERFACE)
target_include_directories({{LIB}}_headers INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries({{LIB}}_headers INTERFACE {{LIB}} tinycbor)

if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/main.cpp")
    add_executable({{LIB}}_example main.cpp)
    target_link_libraries({{LIB}}_example PRIVATE {{LIB}}_headers)
    add_dependencies({{LIB}}_example {{LIB}}_nim_lib)
    if(CMAKE_SYSTEM_NAME STREQUAL "Windows")
        add_custom_command(TARGET {{LIB}}_example POST_BUILD
            COMMAND "${CMAKE_COMMAND}" -E copy_if_different
                "${{{LIB}}_RUNTIME_LIB}"
                "$<TARGET_FILE_DIR:{{LIB}}_example>"
            COMMENT "Staging {{LIB}}.dll next to {{LIB}}_example.exe")
    endif()
endif()
