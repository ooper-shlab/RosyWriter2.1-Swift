//
//  empty_struct.swift
//  OOPUtils
//
//  Created by OOPer in cooperation with shlab.jp, on 2015/1/18.
//
//

import Foundation
func empty_struct<T>() -> T {
    var ptr = UnsafeMutablePointer<T>.alloc(1)
    bzero(UnsafeMutablePointer(ptr), size_t(sizeof(T)))
    let result = ptr.memory
    ptr.dealloc(1)
    return result
}
