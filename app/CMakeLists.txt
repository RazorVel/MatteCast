cmake_minimum_required(VERSION 3.16)
project(MatteCast LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

add_compile_options(
    -Wall -Wextra -Wformat=2 -Wformat-security
    -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE
)
set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -pie -Wl,-z,relro,-z,now")

find_package(OpenCV REQUIRED COMPONENTS core imgproc imgcodecs videoio)

set(ONNXRUNTIME_ROOT "/opt/onnxruntime" CACHE PATH "ONNX Runtime root")
find_path(ONNXRUNTIME_INCLUDE_DIR onnxruntime_cxx_api.h
    PATHS "${ONNXRUNTIME_ROOT}/include" NO_DEFAULT_PATH REQUIRED)
find_library(ONNXRUNTIME_LIBRARY onnxruntime
    PATHS "${ONNXRUNTIME_ROOT}/lib" NO_DEFAULT_PATH REQUIRED)

add_executable(mattecast_server
    server.cpp
    rvm_processor.cpp
)

target_include_directories(mattecast_server PRIVATE
    ${OpenCV_INCLUDE_DIRS}
    ${ONNXRUNTIME_INCLUDE_DIR}
)

target_link_libraries(mattecast_server PRIVATE
    ${OpenCV_LIBS}
    ${ONNXRUNTIME_LIBRARY}
    pthread
    dl
)

set_target_properties(mattecast_server PROPERTIES
    BUILD_RPATH "${ONNXRUNTIME_ROOT}/lib"
    INSTALL_RPATH "/usr/local/lib/onnxruntime"
)
