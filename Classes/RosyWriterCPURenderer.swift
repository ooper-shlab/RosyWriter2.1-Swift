//
//  RosyWriterCPURenderer.swift
//  RosyWriter
//
//  Translated by OOPer in cooperation with shlab.jp,  on 2015/1/12.
//
//
//
/*
 Copyright (C) 2016 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample’s licensing information

 Abstract:
 The RosyWriter CPU-based effect renderer
 */


import UIKit
import CoreMedia
import CoreVideo

@objc(RosyWriterCPURenderer)
class RosyWriterCPURenderer: NSObject, RosyWriterRenderer {
    
    //MARK: RosyWriterRenderer
    
    var operatesInPlace: Bool {
        return true
    }
    
    var inputPixelFormat: FourCharCode {
        return kCVPixelFormatType_32BGRA
    }
    
    func prepareForInputWithFormatDescription(_ inputFormatDescription: CMFormatDescription!, outputRetainedBufferCountHint: Int) {
        // nothing to do, we are stateless
    }
    
    func reset() {
        // nothing to do, we are stateless
    }
    
    func copyRenderedPixelBuffer(_ pixelBuffer: CVPixelBuffer!) -> CVPixelBuffer! {
        let kBytesPerPixel = 4
        
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        
        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        
        for row in 0..<bufferHeight {
            var pixel = baseAddress.advanced(by: Int(row * bytesPerRow))
            for _ in 0..<bufferWidth {
                pixel[1] = 0 // De-green (second pixel in BGRA is green)
                pixel += kBytesPerPixel
            }
        }
        
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        
        return pixelBuffer
    }
    
}
