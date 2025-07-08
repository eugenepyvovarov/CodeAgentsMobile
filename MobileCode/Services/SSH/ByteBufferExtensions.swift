//
//  ByteBufferExtensions.swift
//  CodeAgentsMobile
//
//  Purpose: Extensions on NIO's ByteBuffer for SSH parsing
//  Adapted from Citadel's approach for clean binary parsing
//

import Foundation
import NIO

extension ByteBuffer {
    /// Write an SSH string (length-prefixed UTF-8 string)
    mutating func writeSSHString(_ string: String) {
        let data = string.data(using: .utf8) ?? Data()
        writeInteger(UInt32(data.count), endianness: .big)
        writeBytes(data)
    }
    
    /// Write an SSH buffer (length-prefixed buffer)
    @discardableResult
    mutating func writeSSHBuffer(_ buffer: inout ByteBuffer) -> Int {
        let lengthBytes = writeInteger(UInt32(buffer.readableBytes), endianness: .big)
        let dataBytes = writeBuffer(&buffer)
        return lengthBytes + dataBytes
    }
    
    /// Write data with composite SSH string format
    @discardableResult
    mutating func writeCompositeSSHString(_ closure: (inout ByteBuffer) throws -> Int) rethrows -> Int {
        let oldWriterIndex = writerIndex
        moveWriterIndex(forwardBy: 4) // Reserve space for length
        
        let bytesWritten = try closure(&self)
        
        // Write the length at the reserved position
        setInteger(UInt32(bytesWritten), at: oldWriterIndex, endianness: .big)
        
        return 4 + bytesWritten
    }
    
    /// Read an SSH string (length-prefixed UTF-8 string)
    mutating func readSSHString() -> String? {
        guard let length = readInteger(endianness: .big, as: UInt32.self),
              let data = readData(length: Int(length)),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }
    
    /// Read an SSH buffer (length-prefixed buffer)
    mutating func readSSHBuffer() -> ByteBuffer? {
        guard let length = readInteger(endianness: .big, as: UInt32.self),
              let slice = readSlice(length: Int(length)) else {
            return nil
        }
        return slice
    }
    
    /// Read data of specified length
    mutating func readData(length: Int) -> Data? {
        guard let bytes = readBytes(length: length) else {
            return nil
        }
        return Data(bytes)
    }
    
    /// Write data
    @discardableResult
    mutating func writeData(_ data: Data) -> Int {
        writeBytes(data)
    }
}

// Protocol for types that can be read from and written to ByteBuffer
protocol ByteBufferConvertible {
    static func read(consuming buffer: inout ByteBuffer) throws -> Self
    func write(to buffer: inout ByteBuffer) -> Int
}