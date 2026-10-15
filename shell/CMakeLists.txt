cmake_minimum_required(VERSION 3.20)
project(MakePackShell CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")   # static CRT (/MT): no VC++ redist
add_compile_options(/utf-8 /W4 /permissive-)
add_compile_definitions(UNICODE _UNICODE WIN32_LEAN_AND_MEAN)

add_library(MakePackShell SHARED MakePackShell.cpp)
target_link_libraries(MakePackShell PRIVATE shlwapi)

# Test only, never shipped: tools\build_shell.ps1 runs harness.exe against the fresh DLL.
add_executable(fake_makepack test/fake_makepack.cpp)
add_executable(harness test/harness.cpp)
