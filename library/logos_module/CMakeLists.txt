cmake_minimum_required(VERSION 3.14)
project(LogosDeliveryModulePlugin LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)
else()
    message(FATAL_ERROR "LogosModule.cmake not found. Set LOGOS_MODULE_BUILDER_ROOT.")
endif()

# The module is module.nim, a static archive exporting the logos_module_* C
# ABI. It is linked into the plugin, as a Rust cdylib would be, so its lp_*
# calls reach the protocol layer of the same image. Only the Qt glue is
# generated and built here.
logos_module(
    NAME delivery_module
    EXTERNAL_LIBS
        logosdelivery_module
        rln
)
