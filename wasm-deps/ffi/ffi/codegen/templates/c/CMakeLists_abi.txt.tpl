cmake_minimum_required(VERSION 3.14)
project({{LIB}}_c_abi_bindings C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# The CBOR-free `abi = c` binding links no TinyCBOR — the generated header
# structs are the ABI. Only the Nim dylib is built.

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

# Extra `nim c` arguments (e.g. a `-d:` that flips a shared example source to
# `abi = c`). A library that declares `defaultABIFormat = "c"` needs none.
set(NIM_FFI_EXTRA_ARGS "" CACHE STRING "Extra nim c args when building the dylib")

find_program(NIM_EXECUTABLE nim REQUIRED)

if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    set(NIM_LIB_FILE "${REPO_ROOT}/lib{{LIB}}.dylib")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Windows")
    set(NIM_LIB_FILE "${REPO_ROOT}/{{LIB}}.dll")
else()
    set(NIM_LIB_FILE "${REPO_ROOT}/lib{{LIB}}.so")
endif()

get_filename_component(NIM_SRC "${CMAKE_CURRENT_SOURCE_DIR}/{{SRC}}" ABSOLUTE)

add_custom_command(
    OUTPUT  "${NIM_LIB_FILE}"
    COMMAND "${NIM_EXECUTABLE}" c
                --mm:orc
                -d:chronicles_log_level=WARN
                --app:lib
                --noMain
                "--nimMainPrefix:lib{{LIB}}"
                ${NIM_FFI_EXTRA_ARGS}
                "-o:${NIM_LIB_FILE}"
                "${NIM_SRC}"
    WORKING_DIRECTORY "${REPO_ROOT}"
    DEPENDS "${NIM_SRC}"
    COMMENT "Compiling Nim library lib{{LIB}} (abi = c)"
    VERBATIM
)
add_custom_target({{LIB}}_nim_lib ALL DEPENDS "${NIM_LIB_FILE}")

add_library({{LIB}} SHARED IMPORTED GLOBAL)
set_target_properties({{LIB}} PROPERTIES IMPORTED_LOCATION "${NIM_LIB_FILE}")
add_dependencies({{LIB}} {{LIB}}_nim_lib)

find_package(Threads REQUIRED)

add_library({{LIB}}_headers INTERFACE)
target_include_directories({{LIB}}_headers INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries({{LIB}}_headers INTERFACE {{LIB}} Threads::Threads)
target_compile_definitions({{LIB}}_headers INTERFACE _POSIX_C_SOURCE=200809L)

if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/main.c")
    add_executable({{LIB}}_example main.c)
    target_link_libraries({{LIB}}_example PRIVATE {{LIB}}_headers)
    add_dependencies({{LIB}}_example {{LIB}}_nim_lib)
endif()
