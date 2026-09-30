#pragma once
#include <cstddef>
#include <cstdint>
#include <exception>
#include <string>
#include <vector>

enum OrtLoggingLevel { ORT_LOGGING_LEVEL_WARNING = 2 };
enum GraphOptimizationLevel { ORT_ENABLE_ALL = 99 };
enum OrtAllocatorType { OrtArenaAllocator = 0 };
enum OrtMemType { OrtMemTypeDefault = 0 };
struct OrtCUDAProviderOptions { int device_id = 0; };

namespace Ort {
class Exception : public std::exception {
public: const char* what() const noexcept override { return "stub"; }
};
class Env { public: Env(OrtLoggingLevel, const char*) {} };
class SessionOptions {
public:
 SessionOptions& SetGraphOptimizationLevel(GraphOptimizationLevel){return *this;}
 SessionOptions& SetIntraOpNumThreads(int){return *this;}
 SessionOptions& SetInterOpNumThreads(int){return *this;}
 SessionOptions& AppendExecutionProvider_CUDA(const OrtCUDAProviderOptions&){return *this;}
};
class MemoryInfo {
public: static MemoryInfo CreateCpu(OrtAllocatorType, OrtMemType){return MemoryInfo();}
};
class TensorTypeAndShapeInfo {
public: std::vector<int64_t> GetShape() const { return {1,1,720,1280}; }
};
class Value {
public:
 Value()=default; Value(std::nullptr_t){}
 Value(const Value&)=delete; Value& operator=(const Value&)=delete;
 Value(Value&&)=default; Value& operator=(Value&&)=default;
 template<class T> static Value CreateTensor(const MemoryInfo&, T*, size_t, const int64_t*, size_t){return Value();}
 TensorTypeAndShapeInfo GetTensorTypeAndShapeInfo() const {return TensorTypeAndShapeInfo();}
 template<class T> const T* GetTensorData() const { static T value{}; return &value; }
};
class RunOptions { public: RunOptions(std::nullptr_t){} };
class Session {
public:
 Session(Env&, const char*, const SessionOptions&){}
 std::vector<Value> Run(const RunOptions&, const char* const*, const Value*, size_t,
                        const char* const*, size_t output_count) {
   std::vector<Value> v; v.reserve(output_count); while(v.size()<output_count) v.emplace_back(); return v;
 }
};
}
