//
//  OpenGLPixelBufferView.swift
//  RosyWriter
//
//  Translated by OOPer in cooperation with shlab.jp, on 2015/1/17.
//
//
//
/*
     File: OpenGLPixelBufferView.h
     File: OpenGLPixelBufferView.m
 Abstract: The OpenGL ES view
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
import CoreVideo

let kPassThruVertex =
"attribute vec4 position;\n" +
    "attribute mediump vec4 texturecoordinate;\n" +
    "varying mediump vec2 coordinate;\n" +
    "\n" +
    "void main()\n" +
    "{\n" +
    "\tgl_Position = position;\n" +
    "\tcoordinate = texturecoordinate.xy;\n" +
"}"

let kPassThruFragment =
"varying highp vec2 coordinate;\n" +
    "uniform sampler2D videoframe;\n" +
    "\n" +
    "void main()\n" +
    "{\n" +
    "\tgl_FragColor = texture2D(videoframe, coordinate);\n" +
"}\n"

private let ATTRIB_VERTEX: GLuint = 0
private let ATTRIB_TEXTUREPOSITON: GLuint = 1

@objc(OpenGLPixelBufferView)
class OpenGLPixelBufferView: UIView {
    private var _oglContext: EAGLContext!
    private var _textureCache: CVOpenGLESTextureCache?
    private var _width: GLint = 0
    private var _height: GLint = 0
    private var _frameBufferHandle: GLuint = 0
    private var _colorBufferHandle: GLuint = 0
    private var _program: GLuint = 0
    private var _frame: GLint = 0
    
    override class func layerClass() -> AnyClass {
        return CAEAGLLayer.self
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        // On iOS8 and later we use the native scale of the screen as our content scale factor.
        // This allows us to render to the exact pixel resolution of the screen which avoids additional scaling and GPU rendering work.
        // For example the iPhone 6 Plus appears to UIKit as a 736 x 414 pt screen with a 3x scale factor (2208 x 1242 virtual pixels).
        // But the native pixel dimensions are actually 1920 x 1080.
        // Since we are streaming 1080p buffers from the camera we can render to the iPhone 6 Plus screen at 1:1 with no additional scaling if we set everything up correctly.
        // Using the native scale of the screen also allows us to render at full quality when using the display zoom feature on iPhone 6/6 Plus.
        
        // Only try to compile this code if we are using the 8.0 or later SDK.
        if #available(iOS 8.0, *) {
            self.contentScaleFactor = UIScreen.mainScreen().nativeScale
        } else {
            self.contentScaleFactor = UIScreen.mainScreen().scale
        }
        
        // Initialize OpenGL ES 2
        let eaglLayer = self.layer as! CAEAGLLayer
        eaglLayer.opaque = true
        eaglLayer.drawableProperties = [kEAGLDrawablePropertyRetainedBacking: false,
            kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8]
        
        _oglContext = EAGLContext(API: .OpenGLES2)
        if _oglContext == nil {
            fatalError("Problem with OpenGL context.")
        }
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
    
    func initializeBuffers() -> Bool {
        var success = true
        
        glDisable(GL_DEPTH_TEST.ui)
        
        glGenFramebuffers(1, &_frameBufferHandle)
        glBindFramebuffer(GL_FRAMEBUFFER.ui, _frameBufferHandle)
        
        glGenRenderbuffers(1, &_colorBufferHandle)
        glBindRenderbuffer(GL_RENDERBUFFER.ui, _colorBufferHandle)
        
        _oglContext.renderbufferStorage(GL_RENDERBUFFER.l, fromDrawable: self.layer as! CAEAGLLayer)
        
        glGetRenderbufferParameteriv(GL_RENDERBUFFER.ui, GL_RENDERBUFFER_WIDTH.ui, &_width)
        glGetRenderbufferParameteriv(GL_RENDERBUFFER.ui, GL_RENDERBUFFER_HEIGHT.ui, &_height)
        
        bail: repeat {
            glFramebufferRenderbuffer(GL_FRAMEBUFFER.ui, GL_COLOR_ATTACHMENT0.ui, GL_RENDERBUFFER.ui, _colorBufferHandle)
            if glCheckFramebufferStatus(GL_FRAMEBUFFER.ui) != GL_FRAMEBUFFER_COMPLETE.ui {
                NSLog("Failure with framebuffer generation")
                success = false
                break bail
            }
            
            //  Create a new CVOpenGLESTexture cache
            let err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nil, _oglContext as CVEAGLContext, nil, &_textureCache)
            if err != 0 {
                NSLog("Error at CVOpenGLESTextureCacheCreate %d", err)
                success = false
                break bail
            }
            
            // attributes
            let attribLocation: [GLuint] = [
                ATTRIB_VERTEX, ATTRIB_TEXTUREPOSITON,
            ]
            let attribName: [String] = [
                "position", "texturecoordinate",
            ]
            
            var uniformLocations: [GLint] = []
            glue.createProgram(kPassThruVertex, kPassThruFragment,
                attribName, attribLocation,
                [], &uniformLocations,
                &_program)
            
            if _program == 0 {
                NSLog("Error creating the program")
                success = false
                break bail
            }
            
            _frame = glue.getUniformLocation(_program, "videoframe")
            
        } while false
        if !success {
            self.reset()
        }
        return success
    }
    
    func reset() {
        let oldContext = EAGLContext.currentContext()
        if oldContext !== _oglContext {
            if !EAGLContext.setCurrentContext(_oglContext) {
                fatalError("Problem with OpenGL context")
            }
        }
        if _frameBufferHandle != 0 {
            glDeleteFramebuffers(1, &_frameBufferHandle)
            _frameBufferHandle = 0
        }
        if _colorBufferHandle != 0 {
            glDeleteRenderbuffers(1, &_colorBufferHandle)
            _colorBufferHandle = 0
        }
        if _program != 0 {
            glDeleteProgram(_program)
            _program = 0
        }
        if _textureCache != nil {
            _textureCache = nil
        }
        if oldContext !== _oglContext {
            EAGLContext.setCurrentContext(oldContext)
        }
    }
    
    deinit {
        self.reset()
    }
    
    func displayPixelBuffer(pixelBuffer: CVPixelBuffer) {
        let squareVertices: [GLfloat] = [
            -1.0, -1.0, // bottom left
            1.0, -1.0, // bottom right
            -1.0,  1.0, // top left
            1.0,  1.0, // top right
        ]
        
        let oldContext = EAGLContext.currentContext()
        if oldContext !== _oglContext {
            if !EAGLContext.setCurrentContext(_oglContext) {
                fatalError("Problem with OpenGL context")
            }
        }
        
        if _frameBufferHandle == 0 {
            let success = self.initializeBuffers()
            if !success {
                NSLog("Problem initializing OpenGL buffers.")
                return
            }
        }
        
        // Create a CVOpenGLESTexture from a CVPixelBufferRef
        let frameWidth = CVPixelBufferGetWidth(pixelBuffer)
        let frameHeight = CVPixelBufferGetHeight(pixelBuffer)
        var texture: CVOpenGLESTexture? = nil
        let err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
            _textureCache!,
            pixelBuffer,
            nil,
            GL_TEXTURE_2D.ui,
            GL_RGBA,
            frameWidth.i,
            frameHeight.i,
            GL_BGRA.ui,
            GL_UNSIGNED_BYTE.ui,
            0,
            &texture)
        
        
        if texture == nil || err != 0 {
            NSLog("CVOpenGLESTextureCacheCreateTextureFromImage failed (error: %d)", err)
            return
        }
        
        // Set the view port to the entire view
        glBindFramebuffer(GL_FRAMEBUFFER.ui, _frameBufferHandle)
        glViewport(0, 0, _width, _height)
        
        glUseProgram(_program)
        glActiveTexture(GL_TEXTURE0.ui)
        glBindTexture(CVOpenGLESTextureGetTarget(texture!), CVOpenGLESTextureGetName(texture!))
        glUniform1i(_frame, 0)
        
        // Set texture parameters
        glTexParameteri(GL_TEXTURE_2D.ui, GL_TEXTURE_MIN_FILTER.ui, GL_LINEAR)
        glTexParameteri(GL_TEXTURE_2D.ui, GL_TEXTURE_MAG_FILTER.ui, GL_LINEAR)
        glTexParameteri(GL_TEXTURE_2D.ui, GL_TEXTURE_WRAP_S.ui, GL_CLAMP_TO_EDGE)
        glTexParameteri(GL_TEXTURE_2D.ui, GL_TEXTURE_WRAP_T.ui, GL_CLAMP_TO_EDGE)
        
        glVertexAttribPointer(ATTRIB_VERTEX, 2, GL_FLOAT.ui, 0, 0, squareVertices)
        glEnableVertexAttribArray(ATTRIB_VERTEX)
        
        // Preserve aspect ratio; fill layer bounds
        var textureSamplingSize = CGSize()
        let cropScaleAmount = CGSizeMake(self.bounds.size.width / frameWidth.g, self.bounds.size.height / frameHeight.g)
        if cropScaleAmount.height > cropScaleAmount.width {
            textureSamplingSize.width = self.bounds.size.width / (frameWidth.g * cropScaleAmount.height)
            textureSamplingSize.height = 1.0
        } else {
            textureSamplingSize.width = 1.0
            textureSamplingSize.height = self.bounds.size.height / (frameHeight.g * cropScaleAmount.width)
        }
        
        // Perform a vertical flip by swapping the top left and the bottom left coordinate.
        // CVPixelBuffers have a top left origin and OpenGL has a bottom left origin.
        let passThroughTextureVertices: [GLfloat] = [
            (1.0 - textureSamplingSize.width.f) / 2.0, (1.0 + textureSamplingSize.height.f) / 2.0, // top left
            (1.0 + textureSamplingSize.width.f) / 2.0, (1.0 + textureSamplingSize.height.f) / 2.0, // top right
            (1.0 - textureSamplingSize.width.f) / 2.0, (1.0 - textureSamplingSize.height.f) / 2.0, // bottom left
            (1.0 + textureSamplingSize.width.f) / 2.0, (1.0 - textureSamplingSize.height.f) / 2.0, // bottom right
        ]
        
        glVertexAttribPointer(ATTRIB_TEXTUREPOSITON, 2, GL_FLOAT.ui, 0, 0, passThroughTextureVertices)
        glEnableVertexAttribArray(ATTRIB_TEXTUREPOSITON)
        
        glDrawArrays(GL_TRIANGLE_STRIP.ui, 0, 4)
        
        glBindRenderbuffer(GL_RENDERBUFFER.ui, _colorBufferHandle)
        _oglContext.presentRenderbuffer(GL_RENDERBUFFER.l)
        
        glBindTexture(CVOpenGLESTextureGetTarget(texture!), 0)
        glBindTexture(GL_TEXTURE_2D.ui, 0)
        
        if oldContext !== _oglContext {
            EAGLContext.setCurrentContext(oldContext)
        }
    }
    
    func flushPixelBufferCache() {
        if _textureCache != nil {
            CVOpenGLESTextureCacheFlush(_textureCache!, 0)
        }
    }
    
}