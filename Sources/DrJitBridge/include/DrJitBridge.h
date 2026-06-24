// DrJitBridge.h
// ─────────────────────────────────────────────────────────────────────────────
// A template-free C++ API over drjit-core's C99 jit.h interface.
//
// This file is importable by Swift via C++ interoperability.  No Dr.Jit
// template types appear in the public interface; all JIT variable handles
// are hidden inside DrJitArray's Pimpl.
//
// Metal backend: on Apple platforms, drjit-core compiles expressions to MSL
// (Metal Shading Language) at runtime and evaluates them on the GPU.  No
// `com.apple.developer.cs.allow-jit` entitlement is required — Metal shader
// compilation is a standard visionOS feature.
//
// Usage (Swift, via C++ interop):
//
//   DrJitContext.initMetal()
//   let x   = DrJitContext.linspace(0.0, Float.pi, 256)
//   let y   = x.sin_()
//   let pts = y.evaluate()   // [Float], computed on GPU
//   DrJitContext.shutdown()
// ─────────────────────────────────────────────────────────────────────────────
#pragma once

#include <memory>
#include <vector>
#include <string>
#include <cstdint>

#if __has_include(<swift/bridging>)
#  include <swift/bridging>
#else
#  define SWIFT_RETURNS_INDEPENDENT_VALUE
#endif

// ─── DrJitArray ───────────────────────────────────────────────────────────────

/// An array of Float32 values whose computation is deferred to the Metal GPU.
///
/// Arithmetic operators build a lazy computation graph.  Call evaluate() to
/// compile the graph to an MSL kernel, execute it, and read back results.
///
/// Reference counting: the underlying JIT variable is ref-counted by
/// drjit-core; DrJitArray copies share the same variable handle (cheap).
class DrJitArray {
public:
    DrJitArray();
    DrJitArray(const DrJitArray& other);
    DrJitArray(DrJitArray&& other) noexcept;
    ~DrJitArray();
    DrJitArray& operator=(const DrJitArray& other);
    DrJitArray& operator=(DrJitArray&& other) noexcept;

    // ── Arithmetic ────────────────────────────────────────────────────────

    DrJitArray add(const DrJitArray& rhs) const;
    DrJitArray sub(const DrJitArray& rhs) const;
    DrJitArray mul(const DrJitArray& rhs) const;
    DrJitArray div(const DrJitArray& rhs) const;
    DrJitArray neg() const;
    DrJitArray abs_() const;
    DrJitArray sqrt_() const;
    DrJitArray rcp() const;   ///< Reciprocal (1/x, fast approximation)
    DrJitArray fma(const DrJitArray& b, const DrJitArray& c) const;  ///< this*b + c

    // ── Transcendentals (Metal / CUDA multi-function generator) ───────────
    // Available on Metal backend.  Internally use drjit's extra library.

    DrJitArray sin_()  const;
    DrJitArray cos_()  const;
    DrJitArray exp2_() const;  ///< 2^x
    DrJitArray log2_() const;  ///< log₂(x)

    // ── Min / max ─────────────────────────────────────────────────────────
    DrJitArray min_(const DrJitArray& rhs) const;
    DrJitArray max_(const DrJitArray& rhs) const;

    // ── Info ──────────────────────────────────────────────────────────────
    std::size_t size() const;
    bool        isEmpty() const;

    // ── Evaluation ────────────────────────────────────────────────────────

    /// Schedule this array for evaluation and flush the queue.
    /// Returns a host-side std::vector<float> with all computed values.
    std::vector<float> evaluate() const;

    /// Raw pointer to evaluated data (only valid after evaluate()).
    /// Use this for zero-copy handoff to RealityKit.
    const float* dataPtr() const SWIFT_RETURNS_INDEPENDENT_VALUE;
    std::size_t  dataCount() const;

    // ── Internal factory ──────────────────────────────────────────────────
    // Takes ownership of a drjit-core variable index (initial ref already held).
    // Called from DrJitBridge.mm; not usable from Swift (Pimpl is opaque).
    struct Pimpl;
    static DrJitArray fromIndex(uint32_t index);

private:
    explicit DrJitArray(std::shared_ptr<Pimpl> p);
    std::shared_ptr<Pimpl> d_;
};

// ─── DrJitContext ─────────────────────────────────────────────────────────────

/// Singleton-style context for the Dr.Jit Metal backend.
class DrJitContext {
public:
    /// Initialize the Metal JIT backend.  Call once before any DrJitArray use.
    static void initMetal();

    /// Shut down and release GPU resources.
    static void shutdown(bool light = false);

    // ── Array constructors ────────────────────────────────────────────────

    /// N evenly-spaced values in [from, to] (inclusive).
    static DrJitArray linspace(float from, float to, std::size_t n);

    /// Scalar constant broadcast to N lanes.
    static DrJitArray full(float value, std::size_t n);

    /// Lane index counter: [0, 1, 2, …, n-1] as Float32.
    static DrJitArray counter(std::size_t n);

    // ── Global evaluation ─────────────────────────────────────────────────

    /// Flush all pending JIT operations (equivalent to jit_eval()).
    static void eval();
};
