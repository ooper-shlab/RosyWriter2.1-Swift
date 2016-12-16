//
//  RosyWriterOpenGLRenderer.swift
//  RosyWriter
//
//  Translated by OOPer in cooperation with shlab.jp,  on 2014/12/06.
//
//
//
 /*
     File: RosyWriterOpenGLRenderer.h
     File: RosyWriterOpenGLRenderer.m
 Abstract: The RosyWriter OpenGL effect renderer
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
import OpenGLES
import CoreMedia

private let ATTRIB_VERTEX = 0
private let ATTRIB_TEXTUREPOSITON = 1
private let NUM_ATTRIBUTES = 2

@objc(RosyWriterOpenGLRenderer)
class RosyWriterOpenGLRenderer: NSObject, RosyWriterRenderer {
    private var _oglContext: EAGLContext!
    private var _textureCache: CVOpenGLESTextureCache?
    private var _renderTextureCache: CVOpenGLESTextureCache?
    private var _bufferPool: CVPixelBufferPool?
    private var _bufferPoolAuxAttributes: CFDictionary?
    private var _outputFormatDescription: CMFormatDescription?
    private var _program: GLuint = 0
    private var _frame: GLint = 0
    private var _offscreenBufferHandle: GLuint = 0
    
    //MARK: API
    
    override init() {
        _oglContext = EAGLContext(api: .openGLES2)
        if _oglContext == nil {
            fatalError("Problem with OpenGL context.")
        }
        super.init()
    }
    
    deinit {
        self.deleteBuffers()
    }
    
    //MARK: RosyWriterRenderer
    
    var operatesInPlace: Bool {
        return false
    }
    
    var inputPixelFormat: FourCharCode {
        return FourCharCode(kCVPixelFormatType_32BGRA)
    }
    
    func prepareForInputWithFormatDescription(_ inputFormatDescription: CMFormatDescription!, outputRetainedBufferCountHint: Int) {
        // The input and output dimensions are the same. This renderer doesn't do any scaling.
        let dimensions = CMVideoFormatDescriptionGetDimensions(inputFormatDescription)
        
        self.deleteBuffers()
        if !self.initializeBuffersWithOutputDimensions(dimensions, retainedBufferCountHint: outputRetainedBufferCountHint) {
            fatalError("Problem preparing renderer.")
        }
    }
    
    func reset() {
        self.deleteBuffers()
    }
    
    func copyRenderedPixelBuffer(_ pixelBuffer: CVPixelBuffer!) -> CVPixelBuffer! {
        struct Const {
            static let squareVertices: [GLfloat] = [
                -1.0, -1.0, // bottom left
                1.0, -1.0, // bottom right
                -1.0,  1.0, // top left
                1.0,  1.0, // top right
            ]
            static let textureVertices: [Float] = [
                0.0, 0.0, // bottom left
                1.0, 0.0, // bottom right
                0.0,  1.0, // top left
                1.0,  1.0, // top right
            ]
        }
        
        if _offscreenBufferHandle == 0 {
            fatalError("Unintialized buffer")
        }
        
        if pixelBuffer == nil {
            fatalError("NULL pixel buffer")
        }
        
        let srcDimensions = CMVideoDimensions(width: Int32(CVPixelBufferGetWidth(pixelBuffer)), height: Int32(CVPixelBufferGetHeight(pixelBuffer)))
        let dstDimensions = CMVideoFormatDescriptionGetDimensions(_outputFormatDescription!)
        if srcDimensions.width != dstDimensions.width || srcDimensions.height != dstDimensions.height {
            fatalError("Invalid pixel buffer dimensions")
        }
        
        if CVPixelBufferGetPixelFormatType(pixelBuffer) != OSType(kCVPixelFormatType_32BGRA) {
            fatalError("Invalid pixel buffer format")
        }
        
        let oldContext = EAGLContext.current()
        if oldContext !== _oglContext {
            if !EAGLContext.setCurrent(_oglContext) {
                fatalError("Problem with OpenGL context")
            }
        }
        
        var err: CVReturn = noErr
        var srcTexture: CVOpenGLESTexture? = nil
        var dstTexture: CVOpenGLESTexture? = nil
        var dstPixelBuffer: CVPixelBuffer? = nil
        bail: do {
            
            err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                _textureCache!,
                pixelBuffer,
                nil,
                GL_TEXTURE_2D.ui,
                GL_RGBA,
                srcDimensions.width,
                srcDimensions.height,
                GL_BGRA.ui,
                GL_UNSIGNED_BYTE.ui,
                0,
                &srcTexture)
            if srcTexture == nil || err != 0 {
                NSLog("Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err)
                break bail
            }
            
            err = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, _bufferPool!, _bufferPoolAuxAttributes, &dstPixelBuffer)
            if err == kCVReturnWouldExceedAllocationThreshold {
                // Flush the texture cache to potentially release the retained buffers and try again to create a pixel buffer
                CVOpenGLESTextureCacheFlush(_renderTextureCache!, 0)
                err = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, _bufferPool!, _bufferPoolAuxAttributes, &dstPixelBuffer)
            }
            if err != 0 {
                if err == kCVReturnWouldExceedAllocationThreshold {
                    NSLog("Pool is out of buffers, dropping frame")
                } else {
                    NSLog("Error at CVPixelBufferPoolCreatePixelBuffer %d", err)
                }
                break bail
            }
            
            err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                _renderTextureCache!,
                dstPixelBuffer!,
                nil,
                GL_TEXTURE_2D.ui,
                GL_RGBA,
                dstDimensions.width,
                dstDimensions.height,
                GL_BGRA.ui,
                GL_UNSIGNED_BYTE.ui,
                0,
                &dstTexture)
            if dstTexture == nil || err != 0 {
                NSLog("Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err)
                break bail
            }
            
            glBindFramebuffer(GL_FRAMEBUFFER.ui, _offscreenBufferHandle)
            glViewport(0, 0, srcDimensions.width, srcDimensions.height)
            glUseProgram(_program)
            
            
            // Set up our destination pixel buffer as the framebuffer's render target.
            glActiveTexture(GL_TEXTURE0.ui)
            glBindTexture(CVOpenGLESTextureGetTarget(dstTexture!), CVOpenGLESTextureGetName(dstTexture!))
            glTexParameteri(GL_TEXTURE_2D.ui, GL_TEXTURE_MIN_FILTER.ui, GL_LINEAR)
            glTexParameteri(GL_TEXTURE_2D.ui, GL_TEXTURE_MAG_FILTER.ui, GL_LINEAR)
            glTexParameteri(GL_TEXTURE_2D.ui, GL_TEXTURE_WRAP_S.ui, GL_CLAMP_TO_EDGE)
            glTexParameteri(GL_TEXTURE_2D.ui, GL_TEXTURE_WRAP_T.ui, GL_CLAMP_TO_EDGE)
            glFramebufferTexture2D(GL_FRAMEBUFFER.ui, GL_COLOR_ATTACHMENT0.ui, CVOpenGLESTextureGetTarget(dstTexture!), CVOpenGLESTextureGetName(dstTexture!), 0)
            
            
            // Render our source pixel buffer.
            glActiveTexture(GL_TEXTURE1.ui)
            glBindTexture(CVOpenGLESTextureGetTarget(srcTexture!), CVOpenGLESTextureGetName(srcTexture!))
            glUniform1i(_frame, 1)
            
            glTexParameteri(GL_TEXTURE_2D.ui, GL_TEXTURE_MIN_FILTER.ui, GL_LINEAR)
            glTexParameteri(GL_TEXTURE_2D.ui, GL_TEXTURE_MAG_FILTER.ui, GL_LINEAR)
            glTexParameteri(GL_TEXTURE_2D.ui, GL_TEXTURE_WRAP_S.ui, GL_CLAMP_TO_EDGE)
            glTexParameteri(GL_TEXTURE_2D.ui, GL_TEXTURE_WRAP_T.ui, GL_CLAMP_TO_EDGE)
            
            glVertexAttribPointer(GLuint(ATTRIB_VERTEX), 2, GL_FLOAT.ui, 0, 0, Const.squareVertices)
            glEnableVertexAttribArray(GLuint(ATTRIB_VERTEX))
            glVertexAttribPointer(GLuint(ATTRIB_TEXTUREPOSITON), 2, GL_FLOAT.ui, 0, 0, Const.textureVertices)
            glEnableVertexAttribArray(GLuint(ATTRIB_TEXTUREPOSITON))
            
            glDrawArrays(GL_TRIANGLE_STRIP.ui, 0, 4)
            
            glBindTexture(CVOpenGLESTextureGetTarget(srcTexture!), 0)
            glBindTexture(CVOpenGLESTextureGetTarget(dstTexture!), 0)
            
            // Make sure that outstanding GL commands which render to the destination pixel buffer have been submitted.
            // AVAssetWriter, AVSampleBufferDisplayLayer, and GL will block until the rendering is complete when sourcing from this pixel buffer.
            glFlush()
        } //bail:
        if oldContext !== _oglContext {
            EAGLContext.setCurrent(oldContext)
        }
        return dstPixelBuffer
    }
    
    var outputFormatDescription: CMFormatDescription? {
        return _outputFormatDescription
    }
    
    //MARK: Internal
    
    private func initializeBuffersWithOutputDimensions(_ outputDimensions: CMVideoDimensions, retainedBufferCountHint clientRetainedBufferCountHint: size_t) -> Bool {
        var success = true
        
        let oldContext = EAGLContext.current()
        if oldContext !== _oglContext {
            if !EAGLContext.setCurrent(_oglContext) {
                fatalError("Problem with OpenGL context")
            }
        }
        
        glDisable(GL_DEPTH_TEST.ui)
        
        glGenFramebuffers(1, &_offscreenBufferHandle)
        glBindFramebuffer(GL_FRAMEBUFFER.ui, _offscreenBufferHandle)
        
        bail: do { //breakable block
            var err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nil, _oglContext, nil, &_textureCache)
            if err != 0 {
                NSLog("Error at CVOpenGLESTextureCacheCreate %d", err)
                success = false
                break bail
            }
            
            err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nil, _oglContext, nil, &_renderTextureCache)
            if err != 0 {
                NSLog("Error at CVOpenGLESTextureCacheCreate %d", err)
                success = false
                break bail
            }
            
            // Load vertex and fragment shaders
            let attribLocation: [GLuint] = [
                ATTRIB_VERTEX.ui, ATTRIB_TEXTUREPOSITON.ui,
            ]
            let attribName: [String] = [
                "position", "texturecoordinate",
            ]
            var uniformLocations: [GLint] = []
            
            let vertSrc = RosyWriterOpenGLRenderer.readFile("myFilter.vsh")
            let fragSrc = RosyWriterOpenGLRenderer.readFile("myFilter.fsh")
            
            // shader program
            glue.createProgram(vertSrc, fragSrc,
                attribName, attribLocation,
                [], &uniformLocations,
                &_program)
            if _program == 0 {
                NSLog("Problem initializing the program.")
                success = false
                break bail
            }
            _frame = glue.getUniformLocation(_program, "videoframe")
            
            let maxRetainedBufferCount = clientRetainedBufferCountHint
            _bufferPool = createPixelBufferPool(outputDimensions.width, outputDimensions.height, FourCharCode(kCVPixelFormatType_32BGRA), Int32(maxRetainedBufferCount))
            if _bufferPool == nil {
                NSLog("Problem initializing a buffer pool.")
                success = false
                break bail
            }
            
            _bufferPoolAuxAttributes = createPixelBufferPoolAuxAttributes(maxRetainedBufferCount)
            preallocatePixelBuffersInPool(_bufferPool!, _bufferPoolAuxAttributes!)
            
            var outputFormatDescription: CMFormatDescription? = nil
            var testPixelBuffer: CVPixelBuffer? = nil
            CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, _bufferPool!, _bufferPoolAuxAttributes, &testPixelBuffer)
            if testPixelBuffer == nil {
                NSLog("Problem creating a pixel buffer.")
                success = false
                break bail
            }
            CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, testPixelBuffer!, &outputFormatDescription)
            _outputFormatDescription = outputFormatDescription
            
        } //bail:
        if !success {
            self.deleteBuffers()
        }
        if oldContext !== _oglContext {
            _ = EAGLContext.setCurrent(oldContext)
        }
        return success
    }
    
    private func deleteBuffers() {
        let oldContext = EAGLContext.current()
        if oldContext != _oglContext {
            if !EAGLContext.setCurrent(_oglContext) {
                fatalError("Problem with OpenGL context")
            }
        }
        if _offscreenBufferHandle != 0 {
            glDeleteFramebuffers(1, &_offscreenBufferHandle)
            _offscreenBufferHandle = 0
        }
        if _program != 0 {
            glDeleteProgram(_program)
            _program = 0
        }
        if _textureCache != nil {
            _textureCache = nil
        }
        if _renderTextureCache != nil {
            _renderTextureCache = nil
        }
        if _bufferPool != nil {
            _bufferPool = nil
        }
        if _bufferPoolAuxAttributes != nil {
            _bufferPoolAuxAttributes = nil
        }
        if _outputFormatDescription != nil {
            _outputFormatDescription = nil
        }
        if oldContext !== _oglContext {
            _ = EAGLContext.setCurrent(oldContext)
        }
    }
    
    private class func readFile(_ name: String) -> String {
        
        let path = Bundle.main.path(forResource: name, ofType: nil)!
        let source = try! String(contentsOfFile: path, encoding: .utf8)
        return source
    }
    
}
private func createPixelBufferPool(_ width: Int32, _ height: Int32, _ pixelFormat: FourCharCode, _ maxBufferCount: Int32) -> CVPixelBufferPool? {
    var outputPool: CVPixelBufferPool? = nil
    
    let sourcePixelBufferOptions: NSDictionary = [kCVPixelBufferPixelFormatTypeKey: pixelFormat,
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
        kCVPixelFormatOpenGLESCompatibility: true,
        kCVPixelBufferIOSurfacePropertiesKey: NSDictionary()]
    
    let pixelBufferPoolOptions: NSDictionary = [kCVPixelBufferPoolMinimumBufferCountKey: maxBufferCount]
    
    CVPixelBufferPoolCreate(kCFAllocatorDefault, pixelBufferPoolOptions, sourcePixelBufferOptions, &outputPool)
    
    return outputPool
}

private func createPixelBufferPoolAuxAttributes(_ maxBufferCount: size_t) -> NSDictionary {
    // CVPixelBufferPoolCreatePixelBufferWithAuxAttributes() will return kCVReturnWouldExceedAllocationThreshold if we have already vended the max number of buffers
    return [kCVPixelBufferPoolAllocationThresholdKey: maxBufferCount]
}

private func preallocatePixelBuffersInPool(_ pool: CVPixelBufferPool, _ auxAttributes: NSDictionary) {
    // Preallocate buffers in the pool, since this is for real-time display/capture
    let pixelBuffers = NSMutableArray()
    while true {
        var pixelBuffer: CVPixelBuffer? = nil
        let err = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, auxAttributes, &pixelBuffer)
        
        if err == kCVReturnWouldExceedAllocationThreshold {
            break
        }
        assert(err == noErr)
        
        pixelBuffers.add(pixelBuffer!)
    }
}
