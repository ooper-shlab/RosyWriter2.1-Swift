//
//  NSDictionaryConvertible.swift
//  OOPUtils
//
//  Created by OOPer in cooperation with shlab.jp, on 2015/1/12.
//
//

import Foundation

//FourCharCode
extension UInt32 {
    public var n: NSNumber {
        return NSNumber(unsignedInt: self)
    }
}

extension Int32 {
    public var n: NSNumber {
        return NSNumber(int: self)
    }
}

extension CFString {
    public var ns: NSString {
        return self as NSString
    }
}