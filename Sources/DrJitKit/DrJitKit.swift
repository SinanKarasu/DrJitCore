// DrJitKit.swift
// ─────────────────────────────────────────────────────────────────────────────
// Idiomatic Swift API over DrJitBridge.
//
// Wraps DrJitArray and DrJitContext in Swift value types with operator
// overloading, so expression evaluation reads naturally:
//
//   JITContext.initMetal()
//   let x = JITContext.linspace(0, .pi, count: 512)
//   let y = (x * JITContext.full(2, count: 512)).sin()
//   let points = y.evaluate()   // [Float]
//
// The computation is lazy: arithmetic builds a graph that drjit-core
// compiles to an MSL Metal kernel and executes on evaluate().
// ─────────────────────────────────────────────────────────────────────────────

import DrJitBridge
import Foundation

// ─── JITArray ─────────────────────────────────────────────────────────────────

/// A deferred-computation array of Float32 values evaluated on the Metal GPU.
public struct JITArray: @unchecked Sendable {
    internal let native: DrJitArray

    internal init(_ native: DrJitArray) {
        self.native = native
    }

    // ── Info ──────────────────────────────────────────────────────────────

    public var count: Int     { Int(native.size()) }
    public var isEmpty: Bool  { native.isEmpty() }

    // ── Evaluation ────────────────────────────────────────────────────────

    /// Compile the computation graph, run on GPU, return host-side results.
    public func evaluate() -> [Float] {
        let vec = native.evaluate()
        // Convert std::vector<float> to [Float]
        return (0..<Int(vec.size())).map { vec[$0] }
    }

    // ── Arithmetic operators ───────────────────────────────────────────────

    public static func + (lhs: JITArray, rhs: JITArray) -> JITArray {
        JITArray(lhs.native.add(rhs.native))
    }
    public static func - (lhs: JITArray, rhs: JITArray) -> JITArray {
        JITArray(lhs.native.sub(rhs.native))
    }
    public static func * (lhs: JITArray, rhs: JITArray) -> JITArray {
        JITArray(lhs.native.mul(rhs.native))
    }
    public static func / (lhs: JITArray, rhs: JITArray) -> JITArray {
        JITArray(lhs.native.div(rhs.native))
    }
    public static prefix func - (x: JITArray) -> JITArray {
        JITArray(x.native.neg())
    }

    // Scalar convenience overloads
    public static func + (lhs: JITArray, rhs: Float) -> JITArray { lhs + JITContext.full(rhs, count: lhs.count) }
    public static func - (lhs: JITArray, rhs: Float) -> JITArray { lhs - JITContext.full(rhs, count: lhs.count) }
    public static func * (lhs: JITArray, rhs: Float) -> JITArray { lhs * JITContext.full(rhs, count: lhs.count) }
    public static func / (lhs: JITArray, rhs: Float) -> JITArray { lhs / JITContext.full(rhs, count: lhs.count) }
    public static func + (lhs: Float, rhs: JITArray) -> JITArray { JITContext.full(lhs, count: rhs.count) + rhs }
    public static func * (lhs: Float, rhs: JITArray) -> JITArray { JITContext.full(lhs, count: rhs.count) * rhs }

    // ── Math functions ────────────────────────────────────────────────────

    public func sin()  -> JITArray { JITArray(native.sin_()) }
    public func cos()  -> JITArray { JITArray(native.cos_()) }
    public func sqrt() -> JITArray { JITArray(native.sqrt_()) }
    public func abs()  -> JITArray { JITArray(native.abs_()) }
    public func rcp()  -> JITArray { JITArray(native.rcp()) }
    public func exp2() -> JITArray { JITArray(native.exp2_()) }
    public func log2() -> JITArray { JITArray(native.log2_()) }

    public func fma(_ b: JITArray, _ c: JITArray) -> JITArray {
        JITArray(native.fma(b.native, c.native))
    }

    public func min(_ other: JITArray) -> JITArray { JITArray(native.min_(other.native)) }
    public func max(_ other: JITArray) -> JITArray { JITArray(native.max_(other.native)) }
}

// ─── JITContext ───────────────────────────────────────────────────────────────

/// Lifecycle and factory methods for the Metal JIT backend.
public enum JITContext {

    /// Initialize the Metal backend.  Call once at app startup.
    public static func initMetal() {
        DrJitContext.initMetal()
    }

    /// Shut down the Metal backend and release GPU resources.
    public static func shutdown(light: Bool = false) {
        DrJitContext.shutdown(light)
    }

    // ── Array constructors ────────────────────────────────────────────────

    /// `count` evenly-spaced values in [from, to] (inclusive).
    public static func linspace(_ from: Float, _ to: Float, count: Int) -> JITArray {
        JITArray(DrJitContext.linspace(from, to, count))
    }

    /// Scalar constant broadcast to `count` lanes.
    public static func full(_ value: Float, count: Int) -> JITArray {
        JITArray(DrJitContext.full(value, count))
    }

    /// Lane indices [0, 1, 2, …, count-1] as Float32.
    public static func counter(count: Int) -> JITArray {
        JITArray(DrJitContext.counter(count))
    }

    /// Flush all pending JIT work.
    public static func eval() {
        DrJitContext.eval()
    }
}

// ─── Global math functions ────────────────────────────────────────────────────

public func sin(_ x: JITArray)  -> JITArray { x.sin() }
public func cos(_ x: JITArray)  -> JITArray { x.cos() }
public func sqrt(_ x: JITArray) -> JITArray { x.sqrt() }
public func abs(_ x: JITArray)  -> JITArray { x.abs() }
public func exp2(_ x: JITArray) -> JITArray { x.exp2() }
public func log2(_ x: JITArray) -> JITArray { x.log2() }
public func fma(_ a: JITArray, _ b: JITArray, _ c: JITArray) -> JITArray { a.fma(b, c) }
