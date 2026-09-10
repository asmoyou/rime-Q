cmake_minimum_required(VERSION 3.16)
project(RimeQ VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(MSVC)
    add_compile_options(/utf-8)
endif()

find_package(SQLite3 REQUIRED)

add_library(rimeq_core
    src/core.cpp
    src/database.cpp
)
target_include_directories(rimeq_core PUBLIC include)
target_link_libraries(rimeq_core PRIVATE SQLite::SQLite3)
if(MSVC)
    target_compile_options(rimeq_core PRIVATE /W4 /utf-8)
else()
    target_compile_options(rimeq_core PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()

add_executable(rimeq tools/demo.cpp)
target_link_libraries(rimeq PRIVATE rimeq_core)
add_executable(rimeq_bench tools/benchmark.cpp)
target_link_libraries(rimeq_bench PRIVATE rimeq_core)

include(CTest)
if(BUILD_TESTING)
    add_executable(rimeq_tests tests/core_tests.cpp)
    target_link_libraries(rimeq_tests PRIVATE rimeq_core SQLite::SQLite3)
    add_test(NAME core_regressions COMMAND rimeq_tests)
    add_test(NAME demo COMMAND rimeq demo)
endif()
