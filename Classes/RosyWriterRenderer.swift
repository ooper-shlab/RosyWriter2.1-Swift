//
//  RosyWriterRenderer.swift
//  RosyWriter
//
//  Translated by OOPer in cooperation with shlab.jp,  on 2015/1/13.
//
//
//
 /*
 Copyright (C) 2016 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample’s licensing information

 Abstract:
 A generic protocol for renderer objects used by RosyWriterCapturePipeline
 */

import Foundation
import CoreMedia
import CoreVideo

@objc(RosyWriterRenderer)
protocol RosyWriterRenderer: NSObjectProtocol {
    
    /* Format/Processing Requirements */
    // When YES the input pixel buffer is written to by the renderer instead of writing the result to a new pixel buffer.
    var operatesInPlace: Bool {get}
    var inputPixelFormat: FourCharCode {get}
    
    /* Resource Lifecycle */
    // Prepare and destroy expensive resources inside these callbacks.
    // The outputRetainedBufferCountHint tells out of place renderers how many of their output buffers will be held onto by the downstream pipeline at one time.
    // This can be used by the renderer to size and preallocate their pools.
    func prepareForInputWithFormatDescription(_ inputFormatDescription: CMFormatDescription!, outputRetainedBufferCountHint: Int)
    func reset()
    
    /* Rendering */
    // Renderers which operate in place should return the input pixel buffer with a +1 retain count.
    // Renderers which operate out of place should create a pixel buffer to return from a pool they own.
    // When rendering to a pixel buffer with the GPU it is not necessary to block until rendering has completed before returning.
    // It is sufficient to call glFlush() to ensure that the commands have been flushed to the GPU.
    func copyRenderedPixelBuffer(_ pixelBuffer: CVPixelBuffer!) -> CVPixelBuffer!
    
    // This property must be implemented if operatesInPlace is NO and the output pixel buffers have a different format description than the input.
    // If implemented a non-NULL value must be returned once the renderer has been prepared (can be NULL after being reset).
    @objc optional var outputFormatDescription: CMFormatDescription? {get}
    
}
