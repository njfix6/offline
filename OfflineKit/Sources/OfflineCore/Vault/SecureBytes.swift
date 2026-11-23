import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A fixed-size byte buffer for key material.
///
/// The bytes live in memory this class allocates itself, so they are never
/// copied by Swift's value semantics. The buffer is locked into RAM (so it is
/// not written to swap) and is overwritten with zeros by `wipe()` and on
/// deallocation.
public final class SecureBytes: @unchecked Sendable {
    public let count: Int

    private let pointer: UnsafeMutableRawPointer
    private let lock = NSLock()
    private var wiped = false

    public init(count: Int) {
        precondition(count > 0)
        self.count = count
        pointer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: count)
        // Best effort: failing to lock the page is not fatal.
        _ = mlock(pointer, count)
    }

    /// Copies `bytes` into a new secure buffer. The caller still owns (and
    /// should wipe) the source.
    public convenience init(copying bytes: UnsafeRawBufferPointer) {
        self.init(count: bytes.count)
        if let base = bytes.baseAddress {
            pointer.copyMemory(from: base, byteCount: bytes.count)
        }
    }

    /// A new buffer filled from the system's cryptographic random generator.
    public static func random(count: Int) -> SecureBytes {
        let result = SecureBytes(count: count)
        var generator = SystemRandomNumberGenerator()
        let buffer = UnsafeMutableRawBufferPointer(start: result.pointer, count: count)
        for index in 0..<count {
            buffer[index] = UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        return result
    }

    deinit {
        wipe()
        pointer.deallocate()
    }

    public var isWiped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wiped
    }

    /// Gives temporary read access to the bytes. Throws `VaultError.locked`
    /// once the buffer has been wiped.
    public func withBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !wiped else { throw VaultError.locked }
        return try body(UnsafeRawBufferPointer(start: pointer, count: count))
    }

    /// Overwrites the bytes with zeros. Safe to call more than once.
    public func wipe() {
        lock.lock()
        defer { lock.unlock() }
        guard !wiped else { return }
        secureZero(pointer, count)
        _ = munlock(pointer, count)
        wiped = true
    }
}

/// Zeroes memory in a way the optimizer is not allowed to remove.
public func secureZero(_ pointer: UnsafeMutableRawPointer, _ count: Int) {
    guard count > 0 else { return }
    #if canImport(Darwin)
    _ = memset_s(pointer, count, 0, count)
    #else
    explicit_bzero(pointer, count)
    #endif
}

extension Array where Element == UInt8 {
    /// Zeroes the array's storage in place.
    public mutating func secureWipe() {
        withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress {
                secureZero(base, buffer.count)
            }
        }
    }
}
