//
//  MovieRecorder.swift
//  RosyWriter
//
//  Translated by OOPer in cooperation with shlab.jp, on 2015/1/17.
//
//
//
/*
 Copyright (C) 2016 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample’s licensing information

 Abstract:
 Real-time movie recorder which is totally non-blocking
 */


import UIKit

import CoreMedia

@objc(MovieRecorderDelegate)
protocol MovieRecorderDelegate: NSObjectProtocol {
    func movieRecorderDidFinishPreparing(_ recorder: MovieRecorder)
    func movieRecorder(_ recorder: MovieRecorder, didFailWithError error: Error)
    func movieRecorderDidFinishRecording(_ recorder: MovieRecorder)
}


import AVFoundation

//-DLOG_STATUS_TRANSITIONS
//Build Settings>Swift Compiler - Custom Flags>Other Swift Flags

private enum MovieRecorderStatus: Int {
    case idle = 0
    case preparingToRecord
    case recording
    // waiting for inflight buffers to be appended
    case finishingRecordingPart1
    // calling finish writing on the asset writer
    case finishingRecordingPart2
    // terminal state
    case finished
    // terminal state
    case failed
}   // internal state machine

#if LOG_STATUS_TRANSITIONS
    extension MovieRecorderStatus: CustomStringConvertible {
        var description: String {
            switch self {
            case .idle:
                return "Idle"
            case .preparingToRecord:
                return "PreparingToRecord"
            case .recording:
                return "Recording"
            case .finishingRecordingPart1:
                return "FinishingRecordingPart1"
            case .finishingRecordingPart2:
                return "FinishingRecordingPart2"
            case .finished:
                return "Finished"
            case .failed:
                return "Failed"
            }
        }
    }
#endif


@objc(MovieRecorder)
class MovieRecorder: NSObject {
    private var _status: MovieRecorderStatus = .idle
    
    private var _writingQueue: DispatchQueue
    
    private var _URL: URL
    
    private var _assetWriter: AVAssetWriter?
    private var _haveStartedSession: Bool = false
    
    private var _audioTrackSourceFormatDescription: CMFormatDescription?
    private var _audioTrackSettings: [String: Any] = [:]
    private var _audioInput: AVAssetWriterInput?
    
    private var _videoTrackSourceFormatDescription: CMFormatDescription?
    private var _videoTrackTransform: CGAffineTransform
    private var _videoTrackSettings: [String: Any] = [:]
    private var _videoInput: AVAssetWriterInput?
    
    private weak var _delegate: MovieRecorderDelegate?
    private var _delegateCallbackQueue: DispatchQueue
    
    //MARK: -
    //MARK: API
    
    // delegate is weak referenced
    init(url: URL, delegate: MovieRecorderDelegate, callbackQueue queue: DispatchQueue) {
        
        _writingQueue = DispatchQueue(label: "com.apple.sample.movierecorder.writing", attributes: [])
        _videoTrackTransform = CGAffineTransform.identity
        _URL = url
        _delegate = delegate
        _delegateCallbackQueue = queue
        super.init()
    }
    
    // Only one audio and video track each are allowed.
    
    // see AVVideoSettings.h for settings keys/values
    func addVideoTrackWithSourceFormatDescription(_ formatDescription: CMFormatDescription, transform: CGAffineTransform, settings videoSettings: [String : Any]) {
        
        synchronized(self) {
            if _status != .idle {
                fatalError("Cannot add tracks while not idle")
            }
            
            if _videoTrackSourceFormatDescription != nil {
                fatalError("Cannot add more than one video track")
            }
            
            _videoTrackSourceFormatDescription = formatDescription
            _videoTrackTransform = transform
            _videoTrackSettings = videoSettings
        }
    }
    
    // see AVAudioSettings.h for settings keys/values
    func addAudioTrackWithSourceFormatDescription(_ formatDescription: CMFormatDescription, settings audioSettings: [String : Any]) {
        
        synchronized(self) {
            if _status != .idle {
                fatalError("Cannot add tracks while not idle")
            }
            
            if _audioTrackSourceFormatDescription != nil {
                fatalError("Cannot add more than one audio track")
            }
            
            _audioTrackSourceFormatDescription = formatDescription
            _audioTrackSettings = audioSettings
        }
    }
    
    // Asynchronous, might take several hundred milliseconds. When finished the delegate's recorderDidFinishPreparing: or recorder:didFailWithError: method will be called.
    func prepareToRecord() {
        synchronized(self) {
            if _status != .idle {
                fatalError("Already prepared, cannot prepare again")
            }
            
            self.transitionToStatus(.preparingToRecord, error: nil)
        }
        
        DispatchQueue.global(qos: .background).async {
        //DispatchQueue.global(priority: DispatchQueue.GlobalQueuePriority.low).async {
            
            autoreleasepool {
                var error: Error? = nil
                do {
                    // AVAssetWriter will not write over an existing file.
                    try FileManager.default.removeItem(at: self._URL)
                } catch _ {
                }
                
                do {
                    self._assetWriter = try AVAssetWriter(outputURL: self._URL, fileType: AVFileType.mov)
                
                    // Create and add inputs
                    if self._videoTrackSourceFormatDescription != nil {
                        try self.setupAssetWriterVideoInputWithSourceFormatDescription(self._videoTrackSourceFormatDescription, transform: self._videoTrackTransform, settings: self._videoTrackSettings)
                    }
                
                    if self._audioTrackSourceFormatDescription != nil {
                        try self.setupAssetWriterAudioInputWithSourceFormatDescription(self._audioTrackSourceFormatDescription, settings: self._audioTrackSettings)
                    }
                
                    let success = self._assetWriter?.startWriting() ?? false
                    if !success {
                        error = self._assetWriter?.error
                    }
                } catch let error1 {
                    error = error1
                }
                
                synchronized(self) {
                    if let error = error {
                        self.transitionToStatus(.failed, error: error)
                    } else {
                        self.transitionToStatus(.recording, error: nil)
                    }
                }
            }
        }
    }
    
    func appendVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        self.appendSampleBuffer(sampleBuffer, ofMediaType: AVMediaType.video)
    }
    
    func appendVideoPixelBuffer(_ pixelBuffer: CVPixelBuffer, withPresentationTime presentationTime: CMTime) {
        var sampleBuffer: CMSampleBuffer? = nil
        
        var timingInfo: CMSampleTimingInfo = CMSampleTimingInfo()
        timingInfo.duration = .invalid
        timingInfo.decodeTimeStamp = .invalid
        timingInfo.presentationTimeStamp = presentationTime
        
        let err = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: _videoTrackSourceFormatDescription!, sampleTiming: &timingInfo, sampleBufferOut: &sampleBuffer)
        if sampleBuffer != nil {
            self.appendSampleBuffer(sampleBuffer!, ofMediaType: AVMediaType.video)
        } else {
            let exceptionReason = "sample buffer create failed (\(err))"
            fatalError(exceptionReason)
        }
    }
    
    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        self.appendSampleBuffer(sampleBuffer, ofMediaType: AVMediaType.audio)
    }
    
    // Asynchronous, might take several hundred milliseconds. When finished the delegate's recorderDidFinishRecording: or recorder:didFailWithError: method will be called.
    func finishRecording() {
        synchronized(self) {
            var shouldFinishRecording = false
            switch _status {
            case .idle,
            .preparingToRecord,
            .finishingRecordingPart1,
            .finishingRecordingPart2,
            .finished:
                fatalError("Not recording")
            case .failed:
                // From the client's perspective the movie recorder can asynchronously transition to an error state as the result of an append.
                // Because of this we are lenient when finishRecording is called and we are in an error state.
                NSLog("Recording has failed, nothing to do")
            case .recording:
                shouldFinishRecording = true
            }
            
            if shouldFinishRecording {
                self.transitionToStatus(.finishingRecordingPart1, error: nil)
            } else {
                return
            }
        }
        
        _writingQueue.async {
            
            autoreleasepool {
                synchronized(self) {
                    // We may have transitioned to an error state as we appended inflight buffers. In that case there is nothing to do now.
                    if self._status != .finishingRecordingPart1 {
                        return
                    }
                    
                    // It is not safe to call -[AVAssetWriter finishWriting*] concurrently with -[AVAssetWriterInput appendSampleBuffer:]
                    // We transition to MovieRecorderStatusFinishingRecordingPart2 while on _writingQueue, which guarantees that no more buffers will be appended.
                    self.transitionToStatus(.finishingRecordingPart2, error: nil)
                }
                
                self._assetWriter?.finishWriting {
                    synchronized(self) {
                        if let error = self._assetWriter?.error {
                            self.transitionToStatus(.failed, error: error)
                        } else {
                            self.transitionToStatus(.finished, error: nil)
                        }
                    }
                }
            }
        }
    }
    
    //MARK: -
    //MARK: Internal
    
    private func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer, ofMediaType mediaType: AVMediaType) {
        
        synchronized(self) {
            if _status.rawValue < MovieRecorderStatus.recording.rawValue {
                fatalError("Not ready to record yet")
            }
        }
        
        _writingQueue.async {
            
            autoreleasepool {
                synchronized(self) {
                    // From the client's perspective the movie recorder can asynchronously transition to an error state as the result of an append.
                    // Because of this we are lenient when samples are appended and we are no longer recording.
                    // Instead of throwing an exception we just release the sample buffers and return.
                    if self._status.rawValue > MovieRecorderStatus.finishingRecordingPart1.rawValue {
                        return
                    }
                }
                
                if !self._haveStartedSession {
                    self._assetWriter?.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                    self._haveStartedSession = true
                }
                
                let input = (mediaType == AVMediaType.video) ? self._videoInput : self._audioInput
                
                if input?.isReadyForMoreMediaData ?? false {
                    let success = input!.append(sampleBuffer)
                    if !success {
                        let error = self._assetWriter?.error
                        synchronized(self) {
                            self.transitionToStatus(.failed, error: error as NSError?)
                        }
                    }
                } else {
                    NSLog("\(mediaType) input not ready for more media data, dropping buffer")
                }
            }
        }
    }
    
    // call under @synchonized( self )
    private func transitionToStatus(_ newStatus: MovieRecorderStatus, error: Error?) {
        var shouldNotifyDelegate = false
        
        #if LOG_STATUS_TRANSITIONS
            NSLog("MovieRecorder state transition: %@->%@", _status.description, newStatus.description)
        #endif
        
        if newStatus != _status {
            // terminal states
            if newStatus == .finished || newStatus == .failed {
                shouldNotifyDelegate = true
                // make sure there are no more sample buffers in flight before we tear down the asset writer and inputs
                
                _writingQueue.async{
                    self.teardownAssetWriterAndInputs()
                    if newStatus == .failed {
                        do {
                            try FileManager.default.removeItem(at: self._URL)
                        } catch _ {
                        }
                    }
                }
                
                #if LOG_STATUS_TRANSITIONS
                    if error != nil {
                        NSLog("MovieRecorder error: %@, code: %i", error!, Int32(error!.code))
                    }
                #endif
            } else if newStatus == .recording {
                shouldNotifyDelegate = true
            }
            
            _status = newStatus
        }
        
        if shouldNotifyDelegate {
            _delegateCallbackQueue.async {
                
                autoreleasepool {
                    switch newStatus {
                    case .recording:
                        self._delegate?.movieRecorderDidFinishPreparing(self)
                    case .finished:
                        self._delegate?.movieRecorderDidFinishRecording(self)
                    case .failed:
                        self._delegate?.movieRecorder(self, didFailWithError: error!)
                    default:
                        fatalError("Unexpected recording status (\(newStatus)) for delegate callback")
                    }
                }
            }
        }
    }
    
    
    private func setupAssetWriterAudioInputWithSourceFormatDescription(_ audioFormatDescription: CMFormatDescription?, settings _audioSettings: [String : Any]?) throws {
        var audioSettings = _audioSettings
        if audioSettings == nil {
            NSLog("No audio settings provided, using default settings")
            audioSettings = [AVFormatIDKey : kAudioFormatMPEG4AAC.ul as AnyObject]
        }
        
        if _assetWriter?.canApply(outputSettings: audioSettings!, forMediaType: AVMediaType.audio) ?? false {
            _audioInput = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: audioSettings, sourceFormatHint: audioFormatDescription)
            _audioInput!.expectsMediaDataInRealTime = true
            
            if _assetWriter?.canAdd(_audioInput!) ?? false {
                _assetWriter!.add(_audioInput!)
            } else {
                throw type(of: self).cannotSetupInputError()
            }
        } else {
            throw type(of: self).cannotSetupInputError()
        }
    }
    
    private func setupAssetWriterVideoInputWithSourceFormatDescription(_ videoFormatDescription: CMFormatDescription?, transform: CGAffineTransform, settings _videoSettings: [String: Any]) throws {
        var videoSettings = _videoSettings
        if videoSettings.isEmpty {
            var bitsPerPixel: Float
            let dimensions = CMVideoFormatDescriptionGetDimensions(videoFormatDescription!)
            let numPixels = dimensions.width * dimensions.height
            var bitsPerSecond: Int
            
            NSLog("No video settings provided, using default settings")
            
            // Assume that lower-than-SD resolutions are intended for streaming, and use a lower bitrate
            if numPixels < 640 * 480 {
                bitsPerPixel = 4.05; // This bitrate approximately matches the quality produced by AVCaptureSessionPresetMedium or Low.
            } else {
                bitsPerPixel = 10.1; // This bitrate approximately matches the quality produced by AVCaptureSessionPresetHigh.
            }
            
            bitsPerSecond = Int(numPixels.f * bitsPerPixel)
            
            let compressionProperties: NSDictionary = [AVVideoAverageBitRateKey : bitsPerSecond,
                AVVideoExpectedSourceFrameRateKey : 30,
                AVVideoMaxKeyFrameIntervalKey : 30]
            
            videoSettings = [AVVideoCodecKey : AVVideoCodecH264,
                AVVideoWidthKey : dimensions.width,
                AVVideoHeightKey : dimensions.height,
                AVVideoCompressionPropertiesKey : compressionProperties]
        }
        
        if _assetWriter?.canApply(outputSettings: videoSettings, forMediaType: AVMediaType.video) ?? false {
            _videoInput = AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: videoSettings, sourceFormatHint: videoFormatDescription)
            _videoInput!.expectsMediaDataInRealTime = true
            _videoInput!.transform = transform
            
            if _assetWriter?.canAdd(_videoInput!) ?? false {
                _assetWriter!.add(_videoInput!)
            } else {
                throw type(of: self).cannotSetupInputError()
            }
        } else {
            throw type(of: self).cannotSetupInputError()
        }
    }
    
    private class func cannotSetupInputError() -> NSError {
        let localizedDescription = NSLocalizedString("Recording cannot be started", comment: "")
        let localizedFailureReason = NSLocalizedString("Cannot setup asset writer input.", comment: "")
        let errorDict: [String: Any] = [NSLocalizedDescriptionKey : localizedDescription,
            NSLocalizedFailureReasonErrorKey: localizedFailureReason]
        return NSError(domain: "com.apple.dts.samplecode", code: 0, userInfo: errorDict)
    }
    
    private func teardownAssetWriterAndInputs() {
        _videoInput = nil
        _audioInput = nil
        _assetWriter = nil
    }
    
}
