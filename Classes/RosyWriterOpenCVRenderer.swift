//
//  RosyWriterOpenCVRenderer.swift
//  RosyWriter
//
//  Translated by OOPer in cooperation with shlab.jp,  on 2015/1/12.
//
//
//
/*
     File: RosyWriterOpenCVRenderer.h
     File: RosyWriterOpenCVRenderer.mm
 Abstract: The RosyWriter OpenCV based effect renderer
  Version: 2.1

 Disclaimer: IMPORTANT:  This Apple software is supplied to you by Apple
 Inc. ("Apple") in consideration of your agreement to the following
 terms, and your use, installation, modification or redistribution of
 this Apple software constitutes acceptance of these terms.  If you do
 not agree with these terms, please do not use, install, modify or
 redistribute this Apple software.

 In consideration of your agreement to abide by the following terms, and
 subject to these terms, Apple grants you a personal, non-exclusive
 license, under Apple's copyrights in this original Apple software (the
 "Apple Software"), to use, reproduce, modify and redistribute the Apple
 Software, with or without modifications, in source and/or binary forms;
 provided that if you redistribute the Apple Software in its entirety and
 without modifications, you must retain this notice and the following
 text and disclaimers in all such redistributions of the Apple Software.
 Neither the name, trademarks, service marks or logos of Apple Inc. may
 be used to endorse or promote products derived from the Apple Software
 without specific prior written permission from Apple.  Except as
 expressly stated in this notice, no other rights or licenses, express or
 implied, are granted by Apple herein, including but not limited to any
 patent rights that may be infringed by your derivative works or by other
 works in which the Apple Software may be incorporated.

 The Apple Software is provided by Apple on an "AS IS" basis.  APPLE
 MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
 THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS
 FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND
 OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS.

 IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL
 OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION,
 MODIFICATION AND/OR DISTRIBUTION OF THE APPLE SOFTWARE, HOWEVER CAUSED
 AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE),
 STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE
 POSSIBILITY OF SUCH DAMAGE.

 Copyright (C) 2014 Apple Inc. All Rights Reserved.

 */

import UIKit
import CoreMedia
import CoreVideo

// To use the RosyWriterOpenCVRenderer, import this header in RosyWriterCapturePipeline.m
// and intialize _renderer to a RosyWriterOpenCVRenderer.
let CV_CN_SHIFT: Int32 = 3
let CV_DEPTH_MAX = (1 << CV_CN_SHIFT)
let CV_8U: Int32 = 0
let CV_MAT_DEPTH_MASK = (CV_DEPTH_MAX - 1)
func CV_MAT_DEPTH(flags: Int32) -> Int32 {
    return ((flags) & CV_MAT_DEPTH_MASK)
}
func CV_MAKETYPE(depth: Int32, cn: Int32) -> Int32 {
    return (CV_MAT_DEPTH(depth) + (((cn)-1) << CV_CN_SHIFT))
}
let CV_8UC4 = CV_MAKETYPE(CV_8U,4)
typealias CV_8UC4_BGRA = (b: UInt8, g: UInt8, r: UInt8, a: UInt8)

struct MyCvMat<T> {
    var type: Int32 = 0
    var step: Int32 = 0
    
    /* for internal use only */ //->not used in Swift version
    var refcount: UnsafeMutablePointer<Int32> = nil
    var hdr_refcount: Int32 = 0
    
    var data: UnsafeMutablePointer<Void> = nil
    
    var rows: Int32 = 0
    var cols: Int32 = 0
}
extension MyCvMat {
    init(_ rows: Int32, _ cols: Int32, _ type:Int32, _ data: UnsafeMutablePointer<Void>)
    {
        self.type = 0
        self.step = sizeof(T).i * cols
        self.data = data
        self.rows = rows
        self.cols = cols
    }
    
    func ELEM_PTR_FAST(row: Int, _ col: Int, _ pix_size: Int) -> UnsafeMutablePointer<T> {
        return UnsafeMutablePointer(self.data.advancedBy(self.step.l*row + pix_size*col))
    }
    subscript(row: Int, col: Int) -> T {
        get {
            return self.ELEM_PTR_FAST(row, col, sizeof(T)).memory
        }
        set {
            self.ELEM_PTR_FAST(row, col, sizeof(T)).memory = newValue
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
    
    let inputPixelFormat: FourCharCode = kCVPixelFormatType_32BGRA.ui
    
    func prepareForInputWithFormatDescription(inputFormatDescription: CMFormatDescription!, outputRetainedBufferCountHint: Int) {
        // nothing to do, we are stateless
    }
    
    func reset() {
        // nothing to do, we are stateless
    }
    
    func copyRenderedPixelBuffer(pixelBuffer: CVPixelBuffer!) -> CVPixelBuffer! {
        CVPixelBufferLockBaseAddress(pixelBuffer, 0)
        
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let extendedWidth = stride / sizeof(UInt32); // each pixel is 4 bytes/32 bits
        
        // Since the OpenCV Mat is wrapping the CVPixelBuffer's pixel data, we must do all of our modifications while its base address is locked.
        // If we want to operate on the buffer later, we'll have to do an expensive deep copy of the pixel data, using memcpy or Mat::clone().
        
        // Use extendedWidth instead of width to account for possible row extensions (sometimes used for memory alignment).
        // We only need to work on columms from [0, width - 1] regardless.
        
        var bgraImage = MyCvMat<CV_8UC4_BGRA>(height.i, extendedWidth.i, CV_8UC4, base)
        assert(bgraImage.data == base)
        
        for y in 0 ..< height {
            for x in 0 ..< width {
                bgraImage[y, x].g = 0
            }
        }
        
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0)
        
        return pixelBuffer
    }
    
}