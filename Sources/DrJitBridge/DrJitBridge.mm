// DrJitBridge.mm
// ─────────────────────────────────────────────────────────────────────────────
// Objective-C++ implementation of DrJitBridge.h.
//
// Uses the drjit-core C99 API (jit.h) directly to avoid instantiating the
// heavy C++ template machinery.  The Metal backend emits MSL at runtime;
// no JIT entitlement is needed on visionOS.
//
// Variable lifecycle:
//   uint32_t index = jit_var_f32(...)    → ref count = 1
//   jit_var_inc_ref(index)               → ref count + 1
//   jit_var_dec_ref(index)               → ref count - 1; freed at 0
//
// DrJitArray::Pimpl holds one ref.  Copies share the index and call
// inc_ref in the copy constructor, dec_ref in the destructor.
// ─────────────────────────────────────────────────────────────────────────────

#include "DrJitBridge.h"

// drjit-core C99 API — Metal backend on Apple
#include <drjit-core/jit.h>

#import <Metal/Metal.h>
#import <Foundation/Foundation.h>

#include <cstring>
#include <stdexcept>
#include <cassert>

// ─── Pimpl ────────────────────────────────────────────────────────────────────

struct DrJitArray::Pimpl {
    uint32_t index  = 0;   ///< drjit-core variable handle; 0 = empty/invalid

    // After evaluate(), host-side copy of the result.
    std::vector<float> hostData;

    Pimpl() = default;
    explicit Pimpl(uint32_t idx) : index(idx) {}

    ~Pimpl() {
        if (index) jit_var_dec_ref(index);
    }

    // Non-copyable via shared_ptr sharing (see DrJitArray copy ctor)
    Pimpl(const Pimpl&) = delete;
    Pimpl& operator=(const Pimpl&) = delete;
};

// ─── Helpers ──────────────────────────────────────────────────────────────────

static constexpr JitBackend kBackend = JitBackend::Metal;

DrJitArray DrJitArray::fromIndex(uint32_t index) {
    // index already has its initial ref from whichever jit_var_* call created it
    return DrJitArray(std::make_shared<DrJitArray::Pimpl>(index));
}

/// Apply a unary op and return a new DrJitArray.
static DrJitArray unary(uint32_t a, JitOp op) {
    const uint32_t dep[1] = { a };
    return DrJitArray::fromIndex(jit_var_op(op, dep));
}

/// Apply a binary op and return a new DrJitArray.
static DrJitArray binary(uint32_t a, uint32_t b, JitOp op) {
    const uint32_t dep[2] = { a, b };
    return DrJitArray::fromIndex(jit_var_op(op, dep));
}

/// Ternary: fma(a, b, c) = a*b + c
static DrJitArray ternary(uint32_t a, uint32_t b, uint32_t c, JitOp op) {
    const uint32_t dep[3] = { a, b, c };
    return DrJitArray::fromIndex(jit_var_op(op, dep));
}

// ─── DrJitArray lifecycle ─────────────────────────────────────────────────────

DrJitArray::DrJitArray()
    : d_(std::make_shared<Pimpl>()) {}

DrJitArray::DrJitArray(std::shared_ptr<Pimpl> p)
    : d_(std::move(p)) {}

DrJitArray::DrJitArray(const DrJitArray& other)
    : d_(std::make_shared<Pimpl>()) {
    d_->index = other.d_->index;
    if (d_->index) jit_var_inc_ref(d_->index);
}

DrJitArray::DrJitArray(DrJitArray&& other) noexcept
    : d_(std::move(other.d_)) {
    other.d_ = std::make_shared<Pimpl>();
}

DrJitArray::~DrJitArray() = default;

DrJitArray& DrJitArray::operator=(const DrJitArray& other) {
    if (this != &other) {
        if (d_->index) jit_var_dec_ref(d_->index);
        d_->index = other.d_->index;
        if (d_->index) jit_var_inc_ref(d_->index);
        d_->hostData.clear();
    }
    return *this;
}

DrJitArray& DrJitArray::operator=(DrJitArray&& other) noexcept {
    if (this != &other) {
        d_ = std::move(other.d_);
        other.d_ = std::make_shared<Pimpl>();
    }
    return *this;
}

// ─── Arithmetic ───────────────────────────────────────────────────────────────

DrJitArray DrJitArray::add(const DrJitArray& rhs) const { return binary(d_->index, rhs.d_->index, JitOp::Add); }
DrJitArray DrJitArray::sub(const DrJitArray& rhs) const { return binary(d_->index, rhs.d_->index, JitOp::Sub); }
DrJitArray DrJitArray::mul(const DrJitArray& rhs) const { return binary(d_->index, rhs.d_->index, JitOp::Mul); }
DrJitArray DrJitArray::div(const DrJitArray& rhs) const { return binary(d_->index, rhs.d_->index, JitOp::Div); }
DrJitArray DrJitArray::neg()  const { return unary(d_->index, JitOp::Neg); }
DrJitArray DrJitArray::abs_() const { return unary(d_->index, JitOp::Abs); }
DrJitArray DrJitArray::sqrt_() const { return unary(d_->index, JitOp::Sqrt); }
DrJitArray DrJitArray::rcp()  const { return unary(d_->index, JitOp::Rcp); }

DrJitArray DrJitArray::fma(const DrJitArray& b, const DrJitArray& c) const {
    return ternary(d_->index, b.d_->index, c.d_->index, JitOp::Fma);
}

DrJitArray DrJitArray::min_(const DrJitArray& rhs) const { return binary(d_->index, rhs.d_->index, JitOp::Min); }
DrJitArray DrJitArray::max_(const DrJitArray& rhs) const { return binary(d_->index, rhs.d_->index, JitOp::Max); }

// ─── Transcendentals ──────────────────────────────────────────────────────────
// JitOp::Sin, Cos, Exp2, Log2 are "multi-function generator" operations.
// On Metal they are emitted as MSL built-in calls (sin, cos, exp2, log2).

DrJitArray DrJitArray::sin_()  const { return unary(d_->index, JitOp::Sin); }
DrJitArray DrJitArray::cos_()  const { return unary(d_->index, JitOp::Cos); }
DrJitArray DrJitArray::exp2_() const { return unary(d_->index, JitOp::Exp2); }
DrJitArray DrJitArray::log2_() const { return unary(d_->index, JitOp::Log2); }

// ─── Info ─────────────────────────────────────────────────────────────────────

std::size_t DrJitArray::size() const {
    return d_->index ? jit_var_size(d_->index) : 0;
}

bool DrJitArray::isEmpty() const { return size() == 0; }

// ─── Evaluation ───────────────────────────────────────────────────────────────

std::vector<float> DrJitArray::evaluate() const {
    if (!d_->index) return {};

    jit_var_schedule(d_->index);
    jit_eval();

    // jit_var_data() returns a GPU buffer address on the Metal backend —
    // not CPU-accessible without explicit sync/blit. Use jit_var_read()
    // instead: it handles the GPU→CPU transfer for each element internally.
    const std::size_t n = jit_var_size(d_->index);
    if (n == 0) return {};

    d_->hostData.resize(n);
    for (std::size_t i = 0; i < n; ++i) {
        jit_var_read(d_->index, i, &d_->hostData[i]);
    }

    return d_->hostData;
}

const float* DrJitArray::dataPtr() const SWIFT_RETURNS_INDEPENDENT_VALUE {
    return d_->hostData.empty() ? nullptr : d_->hostData.data();
}

std::size_t DrJitArray::dataCount() const { return d_->hostData.size(); }

// ─── DrJitContext ─────────────────────────────────────────────────────────────

void DrJitContext::initMetal() {
    // visionOS/iOS sandbox: the app container root is not writable.
    // Dr.Jit creates $HOME/.drjit to cache compiled Metal kernels.
    // Redirect HOME to NSCachesDirectory so the cache lands somewhere writable.
#if TARGET_OS_IOS || TARGET_OS_XR
    NSArray<NSString *> *dirs =
        NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    if (NSString *cachesDir = dirs.firstObject) {
        setenv("HOME", cachesDir.fileSystemRepresentation, /*overwrite=*/1);
    }
#endif
    jit_init(1u << (uint32_t)JitBackend::Metal);
}

void DrJitContext::shutdown(bool light) {
    jit_shutdown(light ? 1 : 0);
}

void DrJitContext::eval() {
    jit_eval();
}

DrJitArray DrJitContext::linspace(float from, float to, std::size_t n) {
    if (n == 0) return DrJitArray{};
    if (n == 1) return full(from, 1);

    // counter i in [0, n-1], then x = from + i * (to - from) / (n - 1)
    uint32_t cnt  = jit_var_counter(kBackend, n);
    uint32_t one  = jit_var_f32(kBackend, 1.0f);
    uint32_t nVar = jit_var_f32(kBackend, float(n - 1));
    uint32_t cntF = jit_var_cast(cnt, VarType::Float32, 0);
    jit_var_dec_ref(cnt);
    jit_var_dec_ref(one);

    // t = cntF / (n-1)
    uint32_t dep2[2] = { cntF, nVar };
    uint32_t t = jit_var_op(JitOp::Div, dep2);
    jit_var_dec_ref(cntF);
    jit_var_dec_ref(nVar);

    // result = from + t * (to - from)
    float range = to - from;
    uint32_t fromVar  = jit_var_f32(kBackend, from);
    uint32_t rangeVar = jit_var_f32(kBackend, range);

    // result = fma(t, range, from)
    uint32_t dep3[3] = { t, rangeVar, fromVar };
    uint32_t result = jit_var_op(JitOp::Fma, dep3);
    jit_var_dec_ref(t);
    jit_var_dec_ref(fromVar);
    jit_var_dec_ref(rangeVar);

    return DrJitArray::fromIndex(result);
}

DrJitArray DrJitContext::full(float value, std::size_t n) {
    uint32_t lit = jit_var_f32(kBackend, value);
    // Broadcast to size n
    uint32_t result = jit_var_resize(lit, n);
    jit_var_dec_ref(lit);
    return DrJitArray::fromIndex(result);
}

DrJitArray DrJitContext::counter(std::size_t n) {
    uint32_t cnt  = jit_var_counter(kBackend, n);
    uint32_t cntF = jit_var_cast(cnt, VarType::Float32, 0);
    jit_var_dec_ref(cnt);
    return DrJitArray::fromIndex(cntF);
}

// fromHost removed — AllocType not in public C99 API.
// Use DrJitContext::full() + arithmetic to construct arrays from host data.
