//
//  File.swift
//  RosyWriter
//
//  Translated by OOPer in cooperation with shlab.jp, on 2015/1/12.
//
//
//
/*
     File: ShaderUtilities.h
     File: ShaderUtilities.c
 Abstract: Shader compiler and linker utilities
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

private func printf(format: String, args: [CVarArgType]) {
    print(String(format: format, arguments: args), appendNewline: false)
}
private func printf(format: String, args: CVarArgType...) {
    printf(format, args: args)
}
func LogInfo(format: String, args: CVarArgType...) {
    printf(format, args: args)
}
func LogError(format: String, args: CVarArgType...) {
    printf(format, args: args)
}

public struct glue {
    /* Compile a shader from the provided source(s) */
    public static func compileShader(target: GLenum, _ count: GLsizei, _ sources: UnsafePointer<UnsafePointer<GLchar>>, inout _ shader: GLuint) -> GLint
    {
        var status: GLint = 0
        
        shader = glCreateShader(target)
        glShaderSource(shader, count, sources, nil)
        glCompileShader(shader)
        
        #if DEBUG
            var logLength: GLint = 0
            glGetShaderiv(shader, GL_INFO_LOG_LENGTH.ui, &logLength)
            if logLength > 0 {
            var log = UnsafeMutablePointer<GLchar>.alloc(logLength.l)
            glGetShaderInfoLog(shader, logLength, &logLength, log)
            log.dealloc(logLength.l)
            }
        #endif
        
        glGetShaderiv(shader, GL_COMPILE_STATUS.ui, &status)
        if status == 0 {
            
            LogError("Failed to compile shader:\n")
            for i in 0..<count.l {
                LogInfo("%s", args: COpaquePointer(sources[i]))
            }
        }
        
        return status
    }
    
    
    /* Link a program with all currently attached shaders */
    public static func linkProgram(program: GLuint) -> GLint {
        var status: GLint = 0
        
        glLinkProgram(program)
        
        #if DEBUG
            var logLength: GLint = 0
            glGetProgramiv(program, GL_INFO_LOG_LENGTH.ui, &logLength)
            if logLength > 0 {
            var log = UnsafeMutablePointer<GLchar>.alloc(logLength.l)
            glGetProgramInfoLog(program, logLength, &logLength, log)
            LogInfo("Program link log:\n%s", COpaquePointer(log))
            log.dealloc(logLength.l)
            }
        #endif
        
        glGetProgramiv(program, GL_LINK_STATUS.ui, &status)
        if status == 0 {
            LogError("Failed to link program %d", args: program)
        }
        
        return status
    }
    
    
    /* Validate a program (for i.e. inconsistent samplers) */
    public static func validateProgram(program: GLuint) -> GLint {
        var status: GLint = 0
        
        glValidateProgram(program)
        
        #if DEBUG
            var logLength: GLint = 0
            glGetProgramiv(program, GL_INFO_LOG_LENGTH.ui, &logLength)
            if logLength > 0 {
            var log = UnsafeMutablePointer<GLchar>.alloc(logLength.l)
            glGetProgramInfoLog(program, logLength, &logLength, log)
            LogInfo("Program validate log:\n%s", COpaquePointer(log))
            log.dealloc(logLength.l)
            }
        #endif
        
        glGetProgramiv(program, GL_VALIDATE_STATUS.ui, &status)
        if status == 0 {
            LogError("Failed to validate program %d", args: program)
        }
        
        return status
    }
    
    
    /* Return named uniform location after linking */
    public static func getUniformLocation(program: GLuint, _ uniformName: String) -> GLint {
        
        let loc = glGetUniformLocation(program, uniformName)
        
        return loc
    }
    
    
    /* Convenience wrapper that compiles, links, enumerates uniforms and attribs */
    public static func createProgram(var vertSource: UnsafePointer<GLchar>,
        var _ fragSource: UnsafePointer<GLchar>,
        _ attribNames: [String],
        _ attribLocations: [GLuint],
        _ uniformNames: [String],
        inout _ uniformLocations: [GLint],
        inout _ program: GLuint) -> GLint
    {
        var vertShader: GLuint = 0, fragShader: GLuint = 0, prog: GLuint = 0, status: GLint = 1
        
        // Create shader program
        prog = glCreateProgram()
        
        // Create and compile vertex shader
        status *= compileShader(GL_VERTEX_SHADER.ui, 1, &vertSource, &vertShader)
        
        // Create and compile fragment shader
        status *= compileShader(GL_FRAGMENT_SHADER.ui, 1, &fragSource, &fragShader)
        
        // Attach vertex shader to program
        glAttachShader(prog, vertShader)
        
        // Attach fragment shader to program
        glAttachShader(prog, fragShader)
        
        // Bind attribute locations
        // This needs to be done prior to linking
        for i in 0..<attribNames.count {
            if !attribNames[i].isEmpty {
                glBindAttribLocation(prog, attribLocations[i], attribNames[i])
            }
        }
        
        // Link program
        status *= linkProgram(prog)
        
        // Get locations of uniforms
        if status != 0 {
            for i in 0..<uniformNames.count {
                if !uniformNames[i].isEmpty {
                    uniformLocations[i] = getUniformLocation(prog, uniformNames[i])
                }
            }
            program = prog
        }
        
        // Release vertex and fragment shaders
        if vertShader != 0 {
            glDeleteShader(vertShader)
        }
        if fragShader != 0 {
            glDeleteShader(fragShader)
        }
        
        return status
    }
}