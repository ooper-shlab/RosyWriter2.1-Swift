//
//  CMTime+.swift
//  OOPUtils
//
//  Created by OOPer in cooperation with shlab.jp, on 2015/1/18.
//
//

import Foundation
import CoreMedia
extension CMTime: Comparable {}
public func < (time1: CMTime, time2: CMTime) -> Bool {
    return CMTimeCompare(time1, time2) < 0
}
public func > (time1: CMTime, time2: CMTime) -> Bool {
    return CMTimeCompare(time1, time2) > 0
}
public func <= (time1: CMTime, time2: CMTime) -> Bool {
    return CMTimeCompare(time1, time2) <= 0
}
public func >= (time1: CMTime, time2: CMTime) -> Bool {
    return CMTimeCompare(time1, time2) >= 0
}
public func == (time1: CMTime, time2: CMTime) -> Bool {
    return CMTimeCompare(time1, time2) == 0
}
//func != (time1: CMTime, time2: CMTime) -> Bool {
//    return CMTimeCompare(time1, time2) != 0
//}
