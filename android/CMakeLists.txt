cmake_minimum_required(VERSION 3.22.1)
project("app_links_kit" C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(app_links_kit SHARED
    src/main/cpp/dn_app_links_bridge.cpp
)

# find_library, not find_package(JNI): the NDK ships the JNI headers.
find_library(log-lib log)

target_link_libraries(app_links_kit ${log-lib})
