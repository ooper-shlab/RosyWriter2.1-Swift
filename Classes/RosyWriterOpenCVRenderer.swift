//
//  RosyWriterOpenCVRenderer.swift
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
 The RosyWriter OpenCV based effect renderer
 */

import UIKit
import CoreMedia
import CoreVideo

// To use the RosyWriterOpenCVRenderer, import this header in RosyWriterCapturePipeline.m
// and intialize _renderer to a RosyWriterOpenCVRenderer.
let CV_CN_SHIFT: Int32 = 3
let CV_DEPTH_MAX = Int32(1 << CV_CN_SHIFT)
let CV_8U: Int32 = 0
let CV_MAT_DEPTH_MASK = (CV_DEPTH_MAX - 1)
func CV_MAT_DEPTH(_ flags: Int32) -> Int32 {
    return ((flags) & CV_MAT_DEPTH_MASK)
}
func CV_MAKETYPE(depth: Int32, cn: Int32) -> Int32 {
    return (CV_MAT_DEPTH(depth) + (((cn)-1) << CV_CN_SHIFT))
}
let CV_8UC4 = CV_MAKETYPE(depth: CV_8U,cn: 4)
typealias CV_8UC4_BGRA = (b: UInt8, g: UInt8, r: UInt8, a: UInt8)

struct MyCvMat<T> {
    var type: Int32 = 0
    var step: Int32 = 0
    
    /* for internal use only */ //->not used in Swift version
    var refcount: UnsafeMutablePointer<Int32>? = nil
    var hdr_refcount: Int32 = 0
    
    var data: UnsafeMutableRawPointer
    
    var rows: Int32 = 0
    var cols: Int32 = 0
}

extension MyCvMat {
    init(_ rows: Int32, _ cols: Int32, _ type:Int32, _ data: UnsafeMutableRawPointer)
    {
        self.type = 0
        self.step = MemoryLayout<T>.size.i * cols
        self.data = data
        self.rows = rows
        self.cols = cols
    }
    
    func ELEM_PTR_FAST(_ row: Int, _ col: Int, _ pix_size: Int) -> UnsafeMutablePointer<T> {
        return self.data.advanced(by: self.step.l*row + pix_size*col).assumingMemoryBound(to: T.self)
    }
    subscript(row: Int, col: Int) -> T {
        get {
            return self.ELEM_PTR_FAST(row, col, MemoryLayout<T>.size).pointee
        }
        set {
            self.ELEM_PTR_FAST(row, col, MemoryLayout<T>.size).pointee = newValue
        }
    }
}

// To build OpenCV into the project:
//	- Download opencv2.framework for iOS
//	- Insert framework into project's Frameworks group
//	- Make sure framework is included under the target's Build Phases -> Link Binary With Libraries.
//-> Not needed in Swift version.
// Original Objective-C++ version only utilizes cv::Mat for wrapping the CVPixelBuffer's pixel data,
// which cannot be imported to Swift. So we created a compatible struct in Swift.
// Thus, this example uses no OpenCV features and you need not link opencv2.framework .

@objc(RosyWriterOpenCVRenderer)
class RosyWriterOpenCVRenderer: NSObject, RosyWriterRenderer {
    
    //MARK: RosyWriterRenderer
    
    let operatesInPlace: Bool = true
    
    let inputPixelFormat: FourCharCode = kCVPixelFormatType_32BGRA
    
    func prepareForInputWithFormatDescription(_ inputFormatDescription: CMFormatDescription!, outputRetainedBufferCountHint: Int) {
        // nothing to do, we are stateless
    }
    
    func reset() {
        // nothing to do, we are stateless
    }
    
    func copyRenderedPixelBuffer(_ pixelBuffer: CVPixelBuffer!) -> CVPixelBuffer! {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let extendedWidth = stride / MemoryLayout<UInt32>.size; // each pixel is 4 bytes/32 bits
        
        // Since the OpenCV Mat is wrapping the CVPixelBuffer's pixel data, we must do all of our modifications while its base address is locked.
        // If we want to operate on the buffer later, we'll have to do an expensive deep copy of the pixel data, using memcpy or Mat::clone().
        
        // Use extendedWidth instead of width to account for possible row extensions (sometimes used for memory alignment).
        // We only need to work on columms from [0, width - 1] regardless.
        
        var bgraImage = MyCvMat<CV_8UC4_BGRA>(height.i, extendedWidth.i, CV_8UC4, base!)
        assert(bgraImage.data == base)
        
        for y in 0 ..< height {
            for x in 0 ..< width {
                bgraImage[y, x].g = 0
            }
        }
        
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        
        return pixelBuffer
    }
    
}
