//
//  ObjC.swift
//  OOPUtils
//
//  Created by OOPer in cooperation with shlab.jp, on 2015/1/17.
//
//

import Foundation
func synchronized(object: AnyObject, block: () -> Void) {
    objc_sync_enter(object)
    block()
    objc_sync_exit(object)
}
func synchronized<T>(object: AnyObject, block: () -> T) -> T {
    objc_sync_enter(object)
    let result: T = block()
    objc_sync_exit(object)
    return result
}
