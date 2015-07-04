//
//  FourCharCode+StringLiteralConvertible.swift
//  OOPUtils
//
//  Created by OOPer in cooperation with shlab.jp, on 2014/12/14.
//
//
/*
Copyright (c) 2015, OOPer(NAGATA, Atsuyuki)
All rights reserved.

Use of any parts(functions, classes or any other program language components)
of this file is permitted with no restrictions, unless you
redistribute or use this file in its entirety without modification.
In this case, providing any sort of warranties or not is the user's responsibility.

Redistribution and use in source and/or binary forms, without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
this list of conditions and the following disclaimer in the documentation
and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

import Foundation
extension FourCharCode: StringLiteralConvertible {
    public init(stringLiteral: StringLiteralType) {
        if stringLiteral.utf16.count != 4 {
            fatalError("FourCharCode length must be 4!")
        }
        var code: FourCharCode = 0
        for char in stringLiteral.utf16 {
            if char > 0xFF {
                fatalError("FourCharCode must contain only ASCII characters!")
            }
            code = (code << 8) + FourCharCode(char)
        }
        self = code
    }
    
    public init(extendedGraphemeClusterLiteral value: String) {
        fatalError("FourCharCode must contain 4 ASCII characters!")
    }
    
    public init(unicodeScalarLiteral value: String) {
        fatalError("FourCharCode must contain 4 ASCII characters!")
    }

    public init(fromString: String) {
        self.init(stringLiteral: fromString)
    }
    
    public func toString() -> String {
        let bytes: [CChar] = [
            CChar((self >> 24) & 0xFF),
            CChar((self >> 16) & 0xFF),
            CChar((self >> 8) & 0xFF),
            CChar(self & 0xFF),
            0
        ]
        return String.fromCString(bytes)!
    }
}
