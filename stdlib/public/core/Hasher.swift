//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
//
// Defines the Hasher struct, representing Swift's standard hash function.
//
//===----------------------------------------------------------------------===//

import SwiftShims

internal protocol _HasherCore {
  init(seed: (UInt64, UInt64))
  mutating func compress(_ value: UInt64)
  mutating func finalize(tailAndByteCount: UInt64) -> UInt64
}

@inline(__always)
internal func _loadPartialUnalignedUInt64LE(
  _ p: UnsafeRawPointer,
  byteCount: Int
) -> UInt64 {
  var result: UInt64 = 0
  switch byteCount {
  case 7:
    result |= UInt64(p.load(fromByteOffset: 6, as: UInt8.self)) &<< 48
    fallthrough
  case 6:
    result |= UInt64(p.load(fromByteOffset: 5, as: UInt8.self)) &<< 40
    fallthrough
  case 5:
    result |= UInt64(p.load(fromByteOffset: 4, as: UInt8.self)) &<< 32
    fallthrough
  case 4:
    result |= UInt64(p.load(fromByteOffset: 3, as: UInt8.self)) &<< 24
    fallthrough
  case 3:
    result |= UInt64(p.load(fromByteOffset: 2, as: UInt8.self)) &<< 16
    fallthrough
  case 2:
    result |= UInt64(p.load(fromByteOffset: 1, as: UInt8.self)) &<< 8
    fallthrough
  case 1:
    result |= UInt64(p.load(fromByteOffset: 0, as: UInt8.self))
    fallthrough
  case 0:
    return result
  default:
    _sanityCheckFailure()
  }
}

/// This is a buffer for segmenting arbitrary data into 8-byte chunks.  Buffer
/// storage is represented by a single 64-bit value in the format used by the
/// finalization step of SipHash. (The least significant 56 bits hold the
/// trailing bytes, while the most significant 8 bits hold the count of bytes
/// appended so far, modulo 256. The count of bytes currently stored in the
/// buffer is in the lower three bits of the byte count.)
internal struct _HasherTailBuffer {
  // msb                                                             lsb
  // +---------+-------+-------+-------+-------+-------+-------+-------+
  // |byteCount|                 tail (<= 56 bits)                     |
  // +---------+-------+-------+-------+-------+-------+-------+-------+
  internal var value: UInt64

  @inline(__always)
  internal init() {
    self.value = 0
  }

  @inline(__always)
  internal init(tail: UInt64, byteCount: UInt64) {
    // byteCount can be any value, but we only keep the lower 8 bits.  (The
    // lower three bits specify the count of bytes stored in this buffer.)
    _sanityCheck(tail & ~(1 << ((byteCount & 7) << 3) - 1) == 0)
    self.value = (byteCount &<< 56 | tail)
  }

  internal var tail: UInt64 {
    @inline(__always)
    get { return value & ~(0xFF &<< 56) }
  }

  internal var byteCount: UInt64 {
    @inline(__always)
    get { return value &>> 56 }
  }

  internal var isFinalized: Bool {
    @inline(__always)
    get { return value == 1 }
  }

  @inline(__always)
  internal mutating func finalize() {
    // A byteCount of 0 with a nonzero tail never occurs during normal use.
    value = 1
  }

  @inline(__always)
  internal mutating func append(_ bytes: UInt64) -> UInt64 {
    let c = byteCount & 7
    if c == 0 {
      value = value &+ (8 &<< 56)
      return bytes
    }
    let shift = c &<< 3
    let chunk = tail | (bytes &<< shift)
    value = (((value &>> 56) &+ 8) &<< 56) | (bytes &>> (64 - shift))
    return chunk
  }

  @inline(__always)
  internal
  mutating func append(_ bytes: UInt64, count: UInt64) -> UInt64? {
    _sanityCheck(count >= 0 && count < 8)
    _sanityCheck(bytes & ~((1 &<< (count &<< 3)) &- 1) == 0)
    let c = byteCount & 7
    let shift = c &<< 3
    if c + count < 8 {
      value = (value | (bytes &<< shift)) &+ (count &<< 56)
      return nil
    }
    let chunk = tail | (bytes &<< shift)
    value = ((value &>> 56) &+ count) &<< 56
    if c + count > 8 {
      value |= bytes &>> (64 - shift)
    }
    return chunk
  }
}

internal struct _BufferingHasher<Core: _HasherCore> {
  private var _buffer: _HasherTailBuffer
  private var _core: Core

  @inline(__always)
  internal init(seed: (UInt64, UInt64)) {
    self._buffer = _HasherTailBuffer()
    self._core = Core(seed: seed)
  }

  @inline(__always)
  internal mutating func combine(_ value: UInt) {
#if arch(i386) || arch(arm)
    combine(UInt32(truncatingIfNeeded: value))
#else
    combine(UInt64(truncatingIfNeeded: value))
#endif
  }

  @inline(__always)
  internal mutating func combine(_ value: UInt64) {
    precondition(!_buffer.isFinalized)
    _core.compress(_buffer.append(value))
  }

  @inline(__always)
  internal mutating func combine(_ value: UInt32) {
    precondition(!_buffer.isFinalized)
    let value = UInt64(truncatingIfNeeded: value)
    if let chunk = _buffer.append(value, count: 4) {
      _core.compress(chunk)
    }
  }

  @inline(__always)
  internal mutating func combine(_ value: UInt16) {
    precondition(!_buffer.isFinalized)
    let value = UInt64(truncatingIfNeeded: value)
    if let chunk = _buffer.append(value, count: 2) {
      _core.compress(chunk)
    }
  }

  @inline(__always)
  internal mutating func combine(_ value: UInt8) {
    precondition(!_buffer.isFinalized)
    let value = UInt64(truncatingIfNeeded: value)
    if let chunk = _buffer.append(value, count: 1) {
      _core.compress(chunk)
    }
  }

  @inline(__always)
  internal mutating func combine(bytes: UInt64, count: Int) {
    precondition(!_buffer.isFinalized)
    _sanityCheck(count <= 8)
    let count = UInt64(truncatingIfNeeded: count)
    if let chunk = _buffer.append(bytes, count: count) {
      _core.compress(chunk)
    }
  }

  @inline(__always)
  internal mutating func combine(bytes: UnsafeRawBufferPointer) {
    precondition(!_buffer.isFinalized)
    var remaining = bytes.count
    guard remaining > 0 else { return }
    var data = bytes.baseAddress!

    // Load first unaligned partial word of data
    do {
      let start = UInt(bitPattern: data)
      let end = _roundUp(start, toAlignment: MemoryLayout<UInt64>.alignment)
      let c = min(remaining, Int(end - start))
      if c > 0 {
        let chunk = _loadPartialUnalignedUInt64LE(data, byteCount: c)
        combine(bytes: chunk, count: c)
        data += c
        remaining -= c
      }
    }
    _sanityCheck(
      remaining == 0 ||
      Int(bitPattern: data) & (MemoryLayout<UInt64>.alignment - 1) == 0)

    // Load as many aligned words as there are in the input buffer
    while remaining >= MemoryLayout<UInt64>.size {
      combine(UInt64(littleEndian: data.load(as: UInt64.self)))
      data += MemoryLayout<UInt64>.size
      remaining -= MemoryLayout<UInt64>.size
    }

    // Load last partial word of data
    _sanityCheck(remaining >= 0 && remaining < 8)
    if remaining > 0 {
      let chunk = _loadPartialUnalignedUInt64LE(data, byteCount: remaining)
      combine(bytes: chunk, count: remaining)
    }
  }

  @inline(__always)
  internal mutating func finalize() -> UInt64 {
    precondition(!_buffer.isFinalized)
    let hash = _core.finalize(tailAndByteCount: _buffer.value)
    _buffer.finalize()
    return hash
  }
}

@_fixed_layout // FIXME: Should be resilient (rdar://problem/38549901)
public struct _Hasher {
  internal typealias Core = _BufferingHasher<_SipHash13Core>

  internal var _core: Core

  @effects(releasenone)
  public init() {
    self._core = Core(seed: _Hasher._seed)
  }

  @usableFromInline
  @effects(releasenone)
  internal init(_seed seed: (UInt64, UInt64)) {
    self._core = Core(seed: seed)
  }

  /// Indicates whether we're running in an environment where hashing needs to
  /// be deterministic. If this is true, the hash seed is not random, and hash
  /// tables do not apply per-instance perturbation that is not repeatable.
  /// This is not recommended for production use, but it is useful in certain
  /// test environments where randomization may lead to unwanted nondeterminism
  /// of test results.
  public // SPI
  static var _isDeterministic: Bool {
    @inlinable
    @inline(__always)
    get {
      return _swift_stdlib_Hashing_parameters.deterministic;
    }
  }

  /// The 128-bit hash seed used to initialize the hasher state. Initialized
  /// once during process startup.
  public // SPI
  static var _seed: (UInt64, UInt64) {
    @inlinable
    @inline(__always)
    get {
      // The seed itself is defined in C++ code so that it is initialized during
      // static construction.  Almost every Swift program uses hash tables, so
      // initializing the seed during the startup seems to be the right
      // trade-off.
      return (
        _swift_stdlib_Hashing_parameters.seed0,
        _swift_stdlib_Hashing_parameters.seed1)
    }
  }

  @inlinable
  @inline(__always)
  public mutating func combine<H: Hashable>(_ value: H) {
    value._hash(into: &self)
  }

  //FIXME: Convert to @usableFromInline internal once integers hash correctly.
  @effects(releasenone)
  public mutating func _combine(_ value: UInt) {
    _core.combine(value)
  }

  //FIXME: Convert to @usableFromInline internal once integers hash correctly.
  @effects(releasenone)
  public mutating func _combine(_ value: UInt64) {
    _core.combine(value)
  }

  //FIXME: Convert to @usableFromInline internal once integers hash correctly.
  @effects(releasenone)
  public mutating func _combine(_ value: UInt32) {
    _core.combine(value)
  }

  //FIXME: Convert to @usableFromInline internal once integers hash correctly.
  @effects(releasenone)
  public mutating func _combine(_ value: UInt16) {
    _core.combine(value)
  }

  //FIXME: Convert to @usableFromInline internal once integers hash correctly.
  @effects(releasenone)
  public mutating func _combine(_ value: UInt8) {
    _core.combine(value)
  }

  @effects(releasenone)
  public mutating func _combine(bytes value: UInt64, count: Int) {
    _core.combine(bytes: value, count: count)
  }

  @effects(releasenone)
  public mutating func combine(bytes: UnsafeRawBufferPointer) {
    _core.combine(bytes: bytes)
  }

  @effects(releasenone)
  public mutating func finalize() -> Int {
    return Int(truncatingIfNeeded: _core.finalize())
  }
}
