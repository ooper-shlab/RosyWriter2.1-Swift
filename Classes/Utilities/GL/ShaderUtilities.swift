//
//  File.swift
//  RosyWriter
//
//  Translated by OOPer in cooperation with shlab.jp, on 2015/1/12.
//
//
//
/*
 Copyright (C) 2016 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample’s licensing information

 Abstract:
 Shader compiler and linker utilities
 */


import UIKit
import OpenGLES

private func printf(_ format: String, args: [CVarArg]) {
    print(String(format: format, arguments: args), terminator: "")
}
private func printf(_ format: String, args: CVarArg...) {
    printf(format, args: args)
}
func LogInfo(_ format: String, args: CVarArg...) {
    printf(format, args: args)
}
func LogError(_ format: String, args: CVarArg...) {
    printf(format, args: args)
}

public struct glue {
    /* Compile a shader from the provided source(s) */
    @discardableResult
    public static func compileShader(_ target: GLenum, _ count: GLsizei, _ sources: UnsafePointer<UnsafePointer<GLchar>?>, _ shader: inout GLuint) -> GLint
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
                LogInfo("%s", args: OpaquePointer(sources[i]!))
            }
        }
        
        return status
    }
    
    
    /* Link a program with all currently attached shaders */
    public static func linkProgram(_ program: GLuint) -> GLint {
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
    public static func validateProgram(_ program: GLuint) -> GLint {
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
    public static func getUniformLocation(_ program: GLuint, _ uniformName: String) -> GLint {
        
        let loc = glGetUniformLocation(program, uniformName)
        
        return loc
    }
    
    
    /* Convenience wrapper that compiles, links, enumerates uniforms and attribs */
    @discardableResult
    public static func createProgram(_ _vertSource: UnsafePointer<GLchar>?,
        _ _fragSource: UnsafePointer<GLchar>?,
        _ attribNames: [String],
        _ attribLocations: [GLuint],
        _ uniformNames: [String],
        _ uniformLocations: inout [GLint],
        _ program: inout GLuint) -> GLint
    {
        var vertShader: GLuint = 0, fragShader: GLuint = 0, prog: GLuint = 0, status: GLint = 1
        
        // Create shader program
        prog = glCreateProgram()
        
        // Create and compile vertex shader
        var vertSource = _vertSource
        status *= compileShader(GL_VERTEX_SHADER.ui, 1, &vertSource, &vertShader)
        
        // Create and compile fragment shader
        var fragSource = _fragSource
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
