cmake_minimum_required(VERSION 3.14)
project(priostack_cpp LANGUAGES CXX VERSION 0.1.0)

# Header-only client exposed as an INTERFACE target. Consumers just:
#   add_subdirectory(clients/cpp)
#   target_link_libraries(my_app PRIVATE priostack::priostack)
# and get the include path plus the libcurl dependency.
find_package(CURL REQUIRED)

add_library(priostack INTERFACE)
add_library(priostack::priostack ALIAS priostack)
target_include_directories(priostack INTERFACE
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>)
target_compile_features(priostack INTERFACE cxx_std_17)
target_link_libraries(priostack INTERFACE CURL::libcurl)

# The quickstart is built only when this is the top-level project, so consumers
# adding this via add_subdirectory don't inherit an extra executable target.
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  add_executable(quickstart examples/quickstart.cpp)
  target_link_libraries(quickstart PRIVATE priostack::priostack)
endif()
