#include <onnxruntime_c_api.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <charconv>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include <unistd.h>

namespace {
constexpr int64_t kPadding = 0;
constexpr int64_t kEOS = 2;
constexpr size_t kMaximumInput = 512;
constexpr size_t kMaximumLineBytes = kMaximumInput * 8;
constexpr int64_t kVocabularySize = 50364;
const OrtApi* api = nullptr;

void check(OrtStatus* error) {
    if (error == nullptr) return;
    std::string message(api->GetErrorMessage(error));
    api->ReleaseStatus(error);
    throw std::runtime_error(message);
}

template <typename T>
using Handle = std::unique_ptr<T, void(ORT_API_CALL*)(T*)>;

template <typename T, typename Factory>
Handle<T> makeHandle(void(ORT_API_CALL* release)(T*), Factory create) {
    Handle<T> result(nullptr, release);
    T* raw = nullptr;
    OrtStatus* error = create(&raw);
    result.reset(raw);
    check(error);
    return result;
}

std::vector<int64_t> readTokens() {
    std::string line;
    line.reserve(kMaximumLineBytes);
    for (;;) {
        const auto byte = std::cin.get();
        if (byte == std::char_traits<char>::eof() || byte == '\n') break;
        if (line.size() == kMaximumLineBytes) throw std::runtime_error("Input line too long");
        line.push_back(static_cast<char>(byte));
    }
    std::vector<int64_t> tokens;
    const char* end = line.data() + line.size();
    for (const char* cursor = line.data(); cursor < end;) {
        if (std::isspace(static_cast<unsigned char>(*cursor))) {
            ++cursor;
            continue;
        }
        int64_t token = 0;
        const auto parsed = std::from_chars(cursor, end, token);
        if (parsed.ec != std::errc{} || parsed.ptr == cursor || token < 0 || token >= kVocabularySize ||
            (parsed.ptr != end && !std::isspace(static_cast<unsigned char>(*parsed.ptr)))) {
            throw std::runtime_error("Invalid token ID");
        }
        tokens.push_back(token);
        cursor = parsed.ptr;
        if (tokens.size() > kMaximumInput) throw std::runtime_error("Too many input tokens");
    }
    if (tokens.empty()) throw std::runtime_error("Missing input tokens");
    return tokens;
}

void watchParent() {
    const pid_t parent = getppid();
    if (parent <= 1) std::_Exit(1);
    std::thread([parent] {
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(45);
        for (;;) {
            if (getppid() != parent || std::chrono::steady_clock::now() >= deadline) std::_Exit(1);
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
        }
    }).detach();
}

Handle<OrtValue> integerTensor(std::vector<int64_t>& data, const OrtMemoryInfo* memory) {
    const std::array<int64_t, 2> shape{1, static_cast<int64_t>(data.size())};
    return makeHandle(api->ReleaseValue, [&](OrtValue** output) {
        return api->CreateTensorWithDataAsOrtValue(memory, data.data(), data.size() * sizeof(data.front()),
                                                   shape.data(), shape.size(),
                                                   ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, output);
    });
}

Handle<OrtSession> makeSession(const OrtEnv* env, const OrtSessionOptions* options, const char* path) {
    return makeHandle(api->ReleaseSession, [&](OrtSession** result) {
        return api->CreateSession(env, path, options, result);
    });
}

template <size_t Count>
Handle<OrtValue> run(OrtSession* session, const std::array<const char*, Count>& names,
                     const std::array<const OrtValue*, Count>& values, const char* outputName) {
    return makeHandle(api->ReleaseValue, [&](OrtValue** result) {
        return api->Run(session, nullptr, names.data(), values.data(), Count, &outputName, 1, result);
    });
}

float decodeFloat16(uint16_t bits) {
    const int exponent = (bits >> 10) & 0x1F;
    const int fraction = bits & 0x3FF;
    if (exponent == 31) return std::numeric_limits<float>::quiet_NaN();
    const float value = exponent == 0 ? std::ldexp(static_cast<float>(fraction), -24)
                                     : std::ldexp(static_cast<float>(1024 + fraction), exponent - 25);
    return (bits & 0x8000) ? -value : value;
}

int64_t bestToken(OrtValue* value, size_t prefixSize) {
    auto info = makeHandle(api->ReleaseTensorTypeAndShapeInfo, [&](OrtTensorTypeAndShapeInfo** result) {
        return api->GetTensorTypeAndShape(value, result);
    });
    size_t rank = 0;
    check(api->GetDimensionsCount(info.get(), &rank));
    if (rank != 3) throw std::runtime_error("Invalid SAGE logits rank");
    std::array<int64_t, 3> shape{};
    check(api->GetDimensions(info.get(), shape.data(), rank));
    if (shape[0] != 1 || (shape[1] != 1 && shape[1] != static_cast<int64_t>(prefixSize)) ||
        shape[2] != kVocabularySize) {
        throw std::runtime_error("Invalid SAGE logits dimensions");
    }

    void* raw = nullptr;
    check(api->GetTensorMutableData(value, &raw));
    ONNXTensorElementDataType type{};
    check(api->GetTensorElementType(info.get(), &type));
    const auto offset = (shape[1] - 1) * shape[2];
    float maximum = -std::numeric_limits<float>::infinity();
    int64_t best = -1;
    for (int64_t token = 0; token < shape[2]; ++token) {
        float score = 0;
        switch (type) {
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT:
            score = static_cast<const float*>(raw)[offset + token];
            break;
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16:
            score = decodeFloat16(static_cast<const uint16_t*>(raw)[offset + token]);
            break;
        default:
            throw std::runtime_error("Unsupported SAGE logits type");
        }
        if (std::isfinite(score) && score > maximum) {
            maximum = score;
            best = token;
        }
    }
    if (best < 0) throw std::runtime_error("SAGE logits contain no finite candidate");
    return best;
}

std::vector<int64_t> correct(const char* encoderPath, const char* decoderPath, std::vector<int64_t> tokens) {
    auto env = makeHandle(api->ReleaseEnv, [](OrtEnv** result) {
        return api->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "KeyboopSage", result);
    });
    auto options = makeHandle(api->ReleaseSessionOptions, [](OrtSessionOptions** result) {
        return api->CreateSessionOptions(result);
    });
    check(api->SetIntraOpNumThreads(options.get(), 2));
    check(api->SetInterOpNumThreads(options.get(), 1));
    check(api->SetSessionGraphOptimizationLevel(options.get(), ORT_ENABLE_EXTENDED));
    auto memory = makeHandle(api->ReleaseMemoryInfo, [](OrtMemoryInfo** result) {
        return api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, result);
    });

    const auto encoder = makeSession(env.get(), options.get(), encoderPath);
    const auto decoder = makeSession(env.get(), options.get(), decoderPath);
    std::vector<int64_t> sourceMask(tokens.size(), 1);
    auto source = integerTensor(tokens, memory.get());
    auto mask = integerTensor(sourceMask, memory.get());
    constexpr std::array<const char*, 2> encoderInputs{"input_ids", "attention_mask"};
    auto encoded = run(encoder.get(), encoderInputs, {source.get(), mask.get()}, "last_hidden_state");

    constexpr std::array<const char*, 3> decoderInputs{"input_ids", "encoder_hidden_states", "encoder_attention_mask"};
    std::vector<int64_t> output{kPadding};
    const size_t maximumNewTokens = std::max<size_t>(8, (tokens.size() * 3) / 2);
    for (size_t i = 0; i < maximumNewTokens; ++i) {
        auto ids = integerTensor(output, memory.get());
        auto logits = run(decoder.get(), decoderInputs, {ids.get(), encoded.get(), mask.get()}, "logits");
        const auto token = bestToken(logits.get(), output.size());
        output.push_back(token);
        if (token == kEOS) return {output.begin() + 1, output.end()};
    }
    throw std::runtime_error("SAGE did not complete within the token budget");
}
} // namespace

int main(int argc, const char* argv[]) {
    const OrtApiBase* base = OrtGetApiBase();
    if (argc == 2 && std::string(argv[1]) == "--version") {
        std::cout << "KeyboopSage (ONNX Runtime " << base->GetVersionString() << ")\n";
        return 0;
    }
    if (argc != 3) {
        std::cerr << "Usage: KeyboopSage <encoder.onnx> <decoder.onnx>\n";
        return 2;
    }
    api = base->GetApi(ORT_API_VERSION);
    if (!api) {
        std::cerr << "Incompatible ONNX Runtime C API\n";
        return 1;
    }
    try {
        watchParent();
        const auto corrected = correct(argv[1], argv[2], readTokens());
        for (size_t i = 0; i < corrected.size(); ++i) std::cout << (i == 0 ? "" : " ") << corrected[i];
        std::cout << '\n';
        return 0;
    } catch (const std::exception& error) {
        // Runtime model paths and errors stay in stderr. The caller never displays them verbatim.
        std::cerr << "KeyboopSage: " << error.what() << '\n';
        return 1;
    }
}
